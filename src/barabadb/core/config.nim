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

  CompactionStrategy* = enum
    csSizeTiered = "size_tiered"
    csLeveled = "leveled"

proc defaultConfig*(): BaraConfig =
  BaraConfig(
    address: "127.0.0.1",
    port: 5432,
    dataDir: "./data",
    maxConnections: 1000,
    walEnabled: true,
    compactionStrategy: csLeveled,
    tlsEnabled: false,
    certFile: "",
    keyFile: "",
  )

proc loadConfig*(): BaraConfig =
  result = defaultConfig()
