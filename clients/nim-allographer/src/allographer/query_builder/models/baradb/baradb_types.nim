import std/asyncdispatch
import std/deques
import std/json
import std/tables
import ../../log
import ../../libs/baradb/baradb_client


type Baradb* = object


const DEFAULT_CONN_MAX_LIFETIME_SECONDS* = 300
const DEFAULT_CONN_MAX_IDLE_SECONDS* = 300


type Connection* = ref object
  client*: BaraClient
  isBusy*: bool
  createdAt*: int64
  lastUsedAt*: int64


type BaradbPreparedEntry* = ref object
  sql*: string
  nArgs*: int
  refCount*: int
  lastUsedAt*: int64


type Connections* = ref object
  conns*: seq[Connection]
  timeout*: int
  maxConnectionLifetime*: int
  maxConnectionIdleTime*: int
  database*: string
  user*: string
  password*: string
  host*: string
  port*: int
  waiters*: Deque[Future[void]]
  columnTypeCache*: Table[string, seq[seq[string]]]
  preparedCache*: Table[string, BaradbPreparedEntry]


type BaradbConnections* = ref object
  log*: LogSetting
  pools*: Connections
  isInTransaction*: bool
  transactionConn*: int


type BaradbPreparedContext* = ref object
  owner*: BaradbConnections
  connI*: int


type BaradbPreparedStatement* = ref object
  owner*: BaradbConnections
  entry*: BaradbPreparedEntry
  sql*: string
  nArgs*: int
  isClosed*: bool


type BaradbQuery* = ref object
  log*: LogSetting
  pools*: Connections
  query*: JsonNode
  queryString*: string
  placeHolder*: JsonNode
  isInTransaction*: bool
  transactionConn*: int


type RawBaradbQuery* = ref object
  log*: LogSetting
  pools*: Connections
  query*: JsonNode
  queryString*: string
  placeHolder*: JsonNode
  isInTransaction*: bool
  transactionConn*: int


proc `$`*(self: BaradbConnections | BaradbQuery | RawBaradbQuery): string =
  return "Baradb"


proc isConnected*(self: BaradbConnections | BaradbQuery | RawBaradbQuery): bool =
  return self.pools.conns.len > 0
