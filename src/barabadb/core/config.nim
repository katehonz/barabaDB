import std/os
import std/strutils
import std/json

type
  BaraConfig* = object
    address*: string
    port*: int
    dataDir*: string
    maxConnections*: int
    walEnabled*: bool
    compactionStrategy*: CompactionStrategy
    tlsEnabled*: bool
    certFile*: string
    keyFile*: string
    idleTimeoutMs*: int
    queryTimeoutMs*: int
    slowQueryThresholdMs*: int
    slowQueryLogPath*: string
    logLevel*: string
    logFile*: string
    logFormat*: string
    memtableSizeMb*: int
    cacheSizeMb*: int
    walSyncIntervalMs*: int
    compactionIntervalMs*: int
    bloomBitsPerKey*: int
    authEnabled*: bool
    jwtSecret*: string
    rateLimitGlobal*: int
    rateLimitPerClient*: int
    raftEnabled*: bool
    raftPort*: int
    raftPeers*: seq[string]
    raftNodeId*: string

  CompactionStrategy* = enum
    csSizeTiered = "size_tiered"
    csLeveled = "leveled"

proc defaultConfig*(): BaraConfig =
  BaraConfig(
    address: "127.0.0.1",
    port: 9472,
    dataDir: "./data",
    maxConnections: 1000,
    walEnabled: true,
    compactionStrategy: csLeveled,
    tlsEnabled: false,
    certFile: "",
    keyFile: "",
    idleTimeoutMs: 300_000,
    queryTimeoutMs: 30_000,
    slowQueryThresholdMs: 1_000,
    slowQueryLogPath: "",
    logLevel: "info",
    logFile: "",
    logFormat: "json",
    memtableSizeMb: 64,
    cacheSizeMb: 256,
    walSyncIntervalMs: 0,
    compactionIntervalMs: 60_000,
    bloomBitsPerKey: 10,
    authEnabled: false,
    jwtSecret: "",
    rateLimitGlobal: 10_000,
    rateLimitPerClient: 1_000,
    raftEnabled: false,
    raftPort: 9473,
    raftPeers: @[],
    raftNodeId: "",
  )

# ----------------------------------------------------------------------
# JSON Config File
# ----------------------------------------------------------------------

proc loadConfigFromJson*(path: string, cfg: var BaraConfig) =
  if not fileExists(path):
    return
  let content = readFile(path)
  if content.len == 0:
    return
  try:
    let j = parseJson(content)
    if j.hasKey("server"):
      let s = j["server"]
      if s.hasKey("address"): cfg.address = s["address"].getStr()
      if s.hasKey("port"): cfg.port = s["port"].getInt()
      if s.hasKey("max_connections"): cfg.maxConnections = s["max_connections"].getInt()
    if j.hasKey("storage"):
      let s = j["storage"]
      if s.hasKey("data_dir"): cfg.dataDir = s["data_dir"].getStr()
      if s.hasKey("memtable_size_mb"): cfg.memtableSizeMb = s["memtable_size_mb"].getInt()
      if s.hasKey("cache_size_mb"): cfg.cacheSizeMb = s["cache_size_mb"].getInt()
      if s.hasKey("wal_sync_interval_ms"): cfg.walSyncIntervalMs = s["wal_sync_interval_ms"].getInt()
      if s.hasKey("compaction_interval_ms"): cfg.compactionIntervalMs = s["compaction_interval_ms"].getInt()
      if s.hasKey("bloom_bits_per_key"): cfg.bloomBitsPerKey = s["bloom_bits_per_key"].getInt()
    if j.hasKey("tls"):
      let s = j["tls"]
      if s.hasKey("enabled"): cfg.tlsEnabled = s["enabled"].getBool()
      if s.hasKey("cert_file"): cfg.certFile = s["cert_file"].getStr()
      if s.hasKey("key_file"): cfg.keyFile = s["key_file"].getStr()
    if j.hasKey("auth"):
      let s = j["auth"]
      if s.hasKey("enabled"): cfg.authEnabled = s["enabled"].getBool()
      if s.hasKey("jwt_secret"): cfg.jwtSecret = s["jwt_secret"].getStr()
      if s.hasKey("rate_limit_global"): cfg.rateLimitGlobal = s["rate_limit_global"].getInt()
      if s.hasKey("rate_limit_per_client"): cfg.rateLimitPerClient = s["rate_limit_per_client"].getInt()
    if j.hasKey("logging"):
      let s = j["logging"]
      if s.hasKey("level"): cfg.logLevel = s["level"].getStr()
      if s.hasKey("file"): cfg.logFile = s["file"].getStr()
      if s.hasKey("format"): cfg.logFormat = s["format"].getStr()
    if j.hasKey("performance"):
      let s = j["performance"]
      if s.hasKey("idle_timeout_ms"): cfg.idleTimeoutMs = s["idle_timeout_ms"].getInt()
      if s.hasKey("query_timeout_ms"): cfg.queryTimeoutMs = s["query_timeout_ms"].getInt()
      if s.hasKey("slow_query_threshold_ms"): cfg.slowQueryThresholdMs = s["slow_query_threshold_ms"].getInt()
      if s.hasKey("slow_query_log_path"): cfg.slowQueryLogPath = s["slow_query_log_path"].getStr()
  except JsonParsingError:
    discard
  except KeyError:
    discard

# ----------------------------------------------------------------------
# Environment Variables
# ----------------------------------------------------------------------

proc parseEnvInt(val: string, defaultVal: int): int =
  if val.len == 0: return defaultVal
  try: parseInt(val) except ValueError: defaultVal

proc parseEnvBool(val: string, defaultVal: bool): bool =
  if val.len == 0: return defaultVal
  let v = val.toLowerAscii()
  return v == "true" or v == "1" or v == "yes"

proc loadConfigFromEnv*(cfg: var BaraConfig) =
  cfg.address = getEnv("BARADB_ADDRESS", cfg.address)
  cfg.port = parseEnvInt(getEnv("BARADB_PORT", ""), cfg.port)
  cfg.dataDir = getEnv("BARADB_DATA_DIR", cfg.dataDir)
  cfg.maxConnections = parseEnvInt(getEnv("BARADB_MAX_CONNECTIONS", ""), cfg.maxConnections)
  cfg.tlsEnabled = parseEnvBool(getEnv("BARADB_TLS_ENABLED", ""), cfg.tlsEnabled)
  cfg.certFile = getEnv("BARADB_CERT_FILE", cfg.certFile)
  cfg.keyFile = getEnv("BARADB_KEY_FILE", cfg.keyFile)
  cfg.idleTimeoutMs = parseEnvInt(getEnv("BARADB_IDLE_TIMEOUT_MS", ""), cfg.idleTimeoutMs)
  cfg.queryTimeoutMs = parseEnvInt(getEnv("BARADB_QUERY_TIMEOUT_MS", ""), cfg.queryTimeoutMs)
  cfg.slowQueryThresholdMs = parseEnvInt(getEnv("BARADB_SLOW_QUERY_THRESHOLD_MS", ""), cfg.slowQueryThresholdMs)
  cfg.slowQueryLogPath = getEnv("BARADB_SLOW_QUERY_LOG_PATH", cfg.slowQueryLogPath)
  cfg.logLevel = getEnv("BARADB_LOG_LEVEL", cfg.logLevel)
  cfg.logFile = getEnv("BARADB_LOG_FILE", cfg.logFile)
  cfg.logFormat = getEnv("BARADB_LOG_FORMAT", cfg.logFormat)
  cfg.memtableSizeMb = parseEnvInt(getEnv("BARADB_MEMTABLE_SIZE_MB", ""), cfg.memtableSizeMb)
  cfg.cacheSizeMb = parseEnvInt(getEnv("BARADB_CACHE_SIZE_MB", ""), cfg.cacheSizeMb)
  cfg.walSyncIntervalMs = parseEnvInt(getEnv("BARADB_WAL_SYNC_INTERVAL_MS", ""), cfg.walSyncIntervalMs)
  cfg.compactionIntervalMs = parseEnvInt(getEnv("BARADB_COMPACTION_INTERVAL_MS", ""), cfg.compactionIntervalMs)
  cfg.bloomBitsPerKey = parseEnvInt(getEnv("BARADB_BLOOM_BITS_PER_KEY", ""), cfg.bloomBitsPerKey)
  cfg.authEnabled = parseEnvBool(getEnv("BARADB_AUTH_ENABLED", ""), cfg.authEnabled)
  cfg.jwtSecret = getEnv("BARADB_JWT_SECRET", cfg.jwtSecret)
  cfg.rateLimitGlobal = parseEnvInt(getEnv("BARADB_RATE_LIMIT_GLOBAL", ""), cfg.rateLimitGlobal)
  cfg.rateLimitPerClient = parseEnvInt(getEnv("BARADB_RATE_LIMIT_PER_CLIENT", ""), cfg.rateLimitPerClient)
  cfg.raftEnabled = parseEnvBool(getEnv("BARADB_RAFT_ENABLED", ""), cfg.raftEnabled)
  cfg.raftPort = parseEnvInt(getEnv("BARADB_RAFT_PORT", ""), cfg.raftPort)
  let peersEnv = getEnv("BARADB_RAFT_PEERS", "")
  if peersEnv.len > 0:
    cfg.raftPeers = peersEnv.split(",")
  cfg.raftNodeId = getEnv("BARADB_RAFT_NODE_ID", cfg.raftNodeId)

# ----------------------------------------------------------------------
# Master Loader
# ----------------------------------------------------------------------

proc loadConfig*(): BaraConfig =
  result = defaultConfig()
  # 1. Try JSON config file
  if fileExists("baradb.json"):
    loadConfigFromJson("baradb.json", result)
  # 2. Environment overrides (highest priority)
  loadConfigFromEnv(result)

proc getEffectiveJwtSecret*(cfg: BaraConfig): string =
  if cfg.jwtSecret.len > 0:
    return cfg.jwtSecret
  return "baradb-default-secret-change-in-production!"
