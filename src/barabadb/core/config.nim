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
  )

proc loadConfig*(): BaraConfig =
  result = defaultConfig()
