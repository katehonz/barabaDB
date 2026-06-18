## Async connection pool for BaraDB.
import std/asyncdispatch
import std/deques
import std/monotimes
import std/times
import ./client
import ./errors

type
  PoolConnection = ref object
    client: BaraClient
    inUse: bool
    createdAt: int64
    lastUsedAt: int64

  PoolConfig* = object
    minConnections*: int
    maxConnections*: int
    maxIdleTimeMs*: int
    maxLifetimeMs*: int

  BaraPool* = ref object
    clientConfig: ClientConfig
    poolConfig: PoolConfig
    connections: seq[PoolConnection]
    waiters: Deque[Future[void]]
    lock: AsyncLock

proc defaultPoolConfig*(): PoolConfig =
  PoolConfig(
    minConnections: 2,
    maxConnections: 10,
    maxIdleTimeMs: 300_000,
    maxLifetimeMs: 3_600_000,
  )

proc nowUnix(): int64 = getTime().toUnix()

proc newBaraPool*(clientConfig: ClientConfig,
                  minConnections = 2,
                  maxConnections = 10,
                  poolConfig = defaultPoolConfig()): BaraPool =
  result = BaraPool(
    clientConfig: clientConfig,
    poolConfig: poolConfig,
    connections: @[],
    waiters: initDeque[Future[void]](),
    lock: initAsyncLock(),
  )
  result.poolConfig.minConnections = minConnections
  result.poolConfig.maxConnections = maxConnections

proc isExpired(cfg: PoolConfig, conn: PoolConnection): bool =
  let now = nowUnix()
  if cfg.maxLifetimeMs > 0 and (now - conn.createdAt) * 1000 >= cfg.maxLifetimeMs:
    return true
  if cfg.maxIdleTimeMs > 0 and conn.lastUsedAt > 0 and (now - conn.lastUsedAt) * 1000 >= cfg.maxIdleTimeMs:
    return true
  return false

proc openConnection(pool: BaraPool): Future[BaraClient] {.async.} =
  let client = newClient(pool.clientConfig)
  try:
    await client.connect()
  except BaraError:
    raise
  except CatchableError as e:
    raise newException(BaraIoError, "Failed to open connection: " & e.msg)
  return client

proc closeConnection(conn: PoolConnection) =
  if not conn.client.isNil:
    conn.client.close()

proc wakeOneWaiter(pool: BaraPool) =
  while pool.waiters.len > 0:
    let w = pool.waiters.popFirst()
    if not w.finished:
      w.complete()
      break

proc acquireConnection(pool: BaraPool): Future[BaraClient] {.async.} =
  let deadline = getMonoTime() + initDuration(milliseconds = pool.clientConfig.timeoutMs)
  while true:
    await pool.lock.acquire()
    # Reuse idle, non-expired connection
    var i = 0
    while i < pool.connections.len:
      let conn = pool.connections[i]
      if not conn.inUse:
        if pool.poolConfig.isExpired(conn):
          pool.connections.del(i)
          pool.lock.release()
          closeConnection(conn)
          await pool.lock.acquire()
          continue
        conn.inUse = true
        conn.lastUsedAt = nowUnix()
        pool.lock.release()
        return conn.client
      inc i
    # Create new if under max
    if pool.connections.len < pool.poolConfig.maxConnections:
      pool.lock.release()
      let client = await pool.openConnection()
      await pool.lock.acquire()
      let conn = PoolConnection(
        client: client,
        inUse: true,
        createdAt: nowUnix(),
        lastUsedAt: nowUnix(),
      )
      pool.connections.add(conn)
      pool.lock.release()
      return client
    pool.lock.release()
    # Wait for a connection to be released
    if getMonoTime() >= deadline:
      raise newException(BaraPoolTimeoutError, "Timed out waiting for a free connection")
    let w = newFuture[void]("pool.wait")
    await pool.lock.acquire()
    pool.waiters.addLast(w)
    pool.lock.release()
    let ok = await withTimeout(w, pool.clientConfig.timeoutMs)
    if not ok:
      await pool.lock.acquire()
      var kept = initDeque[Future[void]]()
      while pool.waiters.len > 0:
        let x = pool.waiters.popFirst()
        if x != w:
          kept.addLast(x)
      pool.waiters = move(kept)
      pool.lock.release()
      raise newException(BaraPoolTimeoutError, "Timed out waiting for a free connection")

proc releaseConnection(pool: BaraPool, client: BaraClient) {.async.} =
  await pool.lock.acquire()
  for conn in pool.connections:
    if conn.client == client:
      conn.inUse = false
      conn.lastUsedAt = nowUnix()
      break
  pool.lock.release()
  wakeOneWaiter(pool)

template withClient*(pool: BaraPool, body: untyped): untyped =
  let c = await pool.acquireConnection()
  try:
    body
  finally:
    await pool.releaseConnection(c)

proc stats*(pool: BaraPool): Future[(int, int, int)] {.async.} =
  await pool.lock.acquire()
  let total = pool.connections.len
  var inUse = 0
  for c in pool.connections:
    if c.inUse:
      inc inUse
  pool.lock.release()
  return (total, total - inUse, inUse)
