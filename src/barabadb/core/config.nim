import std/os
import std/strutils

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
  # Docker / Environment overrides
  let envAddress = getEnv("BARADB_ADDRESS", "")
  if envAddress.len > 0:
    result.address = envAddress
  let envPort = getEnv("BARADB_PORT", "")
  if envPort.len > 0:
    try:
      result.port = parseInt(envPort)
    except ValueError:
      discard
  let envDataDir = getEnv("BARADB_DATA_DIR", "")
  if envDataDir.len > 0:
    result.dataDir = envDataDir
