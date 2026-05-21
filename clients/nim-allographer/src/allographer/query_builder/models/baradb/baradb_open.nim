import std/asyncdispatch
import std/deques
import std/json
import std/tables
import std/times
import ../../libs/baradb/baradb_client
import ../../libs/database_url
import ../../log
import ./baradb_types


proc dbOpen*(_: type Baradb, database: string, user: string, password: string,
              host: string, port: int, maxConnections = 1, timeout = 30,
              shouldDisplayLog = false, shouldOutputLogFile = false, logDir = "",
              maxConnectionLifetime = DEFAULT_CONN_MAX_LIFETIME_SECONDS,
              maxConnectionIdleTime = DEFAULT_CONN_MAX_IDLE_SECONDS): BaradbConnections =
  var conns = newSeq[Connection](maxConnections)
  for i in 0..<maxConnections:
    let config = ClientConfig(
      host: host,
      port: port,
      database: database,
      username: user,
      password: password,
      timeoutMs: timeout * 1000,
      maxRetries: 3,
    )
    let client = newClient(config)
    waitFor client.connect()
    conns[i] = Connection(
      client: client,
      isBusy: false,
      createdAt: getTime().toUnix(),
      lastUsedAt: getTime().toUnix(),
    )
  let pools = Connections(
    conns: conns,
    timeout: timeout,
    maxConnectionLifetime: maxConnectionLifetime,
    maxConnectionIdleTime: maxConnectionIdleTime,
    database: database,
    user: user,
    password: password,
    host: host,
    port: port,
    waiters: initDeque[Future[void]](),
    columnTypeCache: initTable[string, seq[seq[string]]](),
    preparedCache: initTable[string, BaradbPreparedEntry](),
  )
  result = BaradbConnections(
    pools: pools,
    log: LogSetting(shouldDisplayLog: shouldDisplayLog, shouldOutputLogFile: shouldOutputLogFile, logDir: logDir)
  )

proc dbOpen*(_: type Baradb, databaseUrl: DatabaseUrl,
              maxConnections = 1, timeout = 30,
              shouldDisplayLog = false, shouldOutputLogFile = false, logDir = "",
              maxConnectionLifetime = DEFAULT_CONN_MAX_LIFETIME_SECONDS,
              maxConnectionIdleTime = DEFAULT_CONN_MAX_IDLE_SECONDS): BaradbConnections =
  ## Open a BaraDB connection using a URL: baradb://user:pass@host:port/database
  let parsed = parseDatabaseUrl(databaseUrl)
  requireDatabaseUrlScheme(parsed, ["baradb"], "BaraDB")
  let database = parsed.path.stripLeadingSlash()
  let host = if parsed.hostname.len > 0: parsed.hostname else: "127.0.0.1"
  let port = if parsed.hasPort: parsed.port else: 9472
  return Baradb.dbOpen(database, parsed.username, parsed.password, host, port,
                        maxConnections, timeout, shouldDisplayLog, shouldOutputLogFile,
                        logDir, maxConnectionLifetime, maxConnectionIdleTime)
