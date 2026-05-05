## Connection Pool — load-balanced connection pool
import std/deques
import std/locks
import std/monotimes

type
  PoolConnection* = ref object
    id*: int
    host*: string
    port*: int
    inUse*: bool
    lastUsed*: int64
    created*: int64
    database*: string
    transactionOpen*: bool

  PoolConfig* = object
    minConnections*: int
    maxConnections*: int
    maxIdleTime*: int64  # nanoseconds
    maxLifetime*: int64   # nanoseconds
    healthCheckInterval*: int64
    connectTimeout*: int64

  ConnectionPool* = ref object
    config: PoolConfig
    lock: Lock
    connections: Deque[PoolConnection]
    inUseCount: int
    totalCreated: int
    nextId: int
    host: string
    port: int
    database: string

proc defaultPoolConfig*(): PoolConfig =
  PoolConfig(
    minConnections: 2,
    maxConnections: 20,
    maxIdleTime: 300_000_000_000,  # 5 min
    maxLifetime: 3600_000_000_000,  # 1 hour
    healthCheckInterval: 30_000_000_000,
    connectTimeout: 10_000_000_000,
  )

proc newConnectionPool*(host: string, port: int, database: string = "default",
                        config: PoolConfig = defaultPoolConfig()): ConnectionPool =
  new(result)
  initLock(result.lock)
  result.config = config
  result.connections = initDeque[PoolConnection]()
  result.inUseCount = 0
  result.totalCreated = 0
  result.nextId = 1
  result.host = host
  result.port = port
  result.database = database

proc acquire*(pool: ConnectionPool): PoolConnection =
  acquire(pool.lock)

  # Try to reuse an idle connection
  var idx = 0
  while idx < pool.connections.len:
    let conn = pool.connections[idx]
    if not conn.inUse:
      let age = getMonoTime().ticks() - conn.lastUsed
      if age < pool.config.maxIdleTime:
        conn.inUse = true
        inc pool.inUseCount
        release(pool.lock)
        return conn
    inc idx

  # Create a new connection if under max
  if pool.totalCreated < pool.config.maxConnections:
    inc pool.totalCreated
    let conn = PoolConnection(
      id: pool.nextId,
      host: pool.host,
      port: pool.port,
      database: pool.database,
      inUse: true,
      lastUsed: getMonoTime().ticks(),
      created: getMonoTime().ticks(),
    )
    inc pool.nextId
    inc pool.inUseCount
    pool.connections.addFirst(conn)
    release(pool.lock)
    return conn

  release(pool.lock)
  return nil

proc release*(pool: ConnectionPool, conn: PoolConnection) =
  acquire(pool.lock)
  if conn.inUse:
    conn.inUse = false
    conn.lastUsed = getMonoTime().ticks()
    conn.transactionOpen = false
    dec pool.inUseCount
  release(pool.lock)

proc evict*(pool: ConnectionPool) =
  acquire(pool.lock)
  let now = getMonoTime().ticks()
  var newDeque = initDeque[PoolConnection]()
  for conn in pool.connections.items:
    if not conn.inUse:
      let idleTime = now - conn.lastUsed
      let lifetime = now - conn.created
      if idleTime > pool.config.maxIdleTime or lifetime > pool.config.maxLifetime:
        dec pool.totalCreated
        continue
    newDeque.addLast(conn)
  pool.connections = newDeque

  # Trim excess connections above min
  var idleCount = 0
  for conn in pool.connections:
    if not conn.inUse:
      inc idleCount

  if idleCount > pool.config.minConnections:
    let targetTotal = pool.totalCreated - (idleCount - pool.config.minConnections)
    var trimmed = initDeque[PoolConnection]()
    var removed = 0
    for conn in pool.connections:
      if not conn.inUse and pool.totalCreated - removed > targetTotal:
        inc removed
        dec pool.totalCreated
        continue
      trimmed.addLast(conn)
    pool.connections = trimmed
  release(pool.lock)

proc stats*(pool: ConnectionPool): (int, int, int) =
  acquire(pool.lock)
  let total = pool.connections.len
  let idle = total - pool.inUseCount
  let inUse = pool.inUseCount
  release(pool.lock)
  return (total, idle, inUse)

proc totalConnections*(pool: ConnectionPool): int =
  acquire(pool.lock)
  result = pool.totalCreated
  release(pool.lock)

proc inUseCount*(pool: ConnectionPool): int =
  acquire(pool.lock)
  result = pool.inUseCount
  release(pool.lock)
