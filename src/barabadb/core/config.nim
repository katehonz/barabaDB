type
  BaraConfig* = object
    address*: string
    port*: int
    dataDir*: string
    maxConnections*: int
    walEnabled*: bool
    compactionStrategy*: CompactionStrategy

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
  )

proc loadConfig*(): BaraConfig =
  result = defaultConfig()
