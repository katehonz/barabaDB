import std/asyncdispatch
import std/deques
import std/json
import std/monotimes
import std/options
import std/strformat
import std/strutils
import std/sequtils
import std/tables
import std/times
import ../../error
import ../../libs/baradb/baradb_client
import ../../log
import ../database_types
import ./query/baradb_builder
import ./baradb_types


# ================================================================================
# connection pool
# ================================================================================

proc removePoolWaiter(pools: Connections, w: Future[void]) =
  var kept = initDeque[Future[void]]()
  while pools.waiters.len > 0:
    let x = pools.waiters.popFirst()
    if x != w:
      kept.addLast(x)
  pools.waiters = move(kept)

proc wakeOnePoolWaiter(pools: Connections) =
  while pools.waiters.len > 0:
    let w = pools.waiters.popFirst()
    if w.finished:
      continue
    w.complete()
    break

proc poolRemainingMs(deadline: MonoTime): int =
  let left = (deadline - getMonoTime()).inMilliseconds
  if left <= 0:
    return 0
  if left > int64(high(int)):
    return high(int)
  result = int(left)
  if result < 1:
    result = 1

proc nowUnix(): int64 =
  getTime().toUnix()

proc hasConnExpired(self: Connections, conn: Connection): bool =
  let now = nowUnix()
  if self.maxConnectionLifetime > 0 and now - conn.createdAt >= self.maxConnectionLifetime.int64:
    return true
  if self.maxConnectionIdleTime > 0 and now - conn.lastUsedAt >= self.maxConnectionIdleTime.int64:
    return true
  return false

proc openBaradbConn(self: Connections): BaraClient =
  let config = ClientConfig(
    host: self.host,
    port: self.port,
    database: self.database,
    username: self.user,
    password: self.password,
    timeoutMs: self.timeout * 1000,
    maxRetries: 3,
  )
  let client = newClient(config)
  waitFor client.connect()
  return client

proc refreshConn(self: Connections, connI: int): bool =
  if connI < 0 or connI >= self.conns.len:
    return false
  let client = openBaradbConn(self)
  let oldConn = self.conns[connI].client
  if not oldConn.isNil:
    oldConn.close()
  self.conns[connI].client = client
  self.conns[connI].createdAt = nowUnix()
  self.conns[connI].lastUsedAt = self.conns[connI].createdAt
  return true

proc getFreeConn(self: BaradbConnections | BaradbQuery | RawBaradbQuery): Future[int] {.async.} =
  let deadline = getMonoTime() + initDuration(seconds = self.pools.timeout)
  while true:
    for i in 0 ..< self.pools.conns.len:
      if not self.pools.conns[i].isBusy:
        self.pools.conns[i].isBusy = true
        if self.pools.hasConnExpired(self.pools.conns[i]):
          try:
            discard self.pools.refreshConn(i)
          except CatchableError:
            discard
        when defined(check_pool):
          echo "=== getFreeConn ", i
        return i
    if getMonoTime() >= deadline:
      return errorConnectionNum
    let w = newFuture[void]("getFreeConn.poolWait")
    self.pools.waiters.addLast(w)
    var ms = poolRemainingMs(deadline)
    if ms < 1:
      ms = 1
    let ok = await withTimeout(w, ms)
    if not ok:
      removePoolWaiter(self.pools, w)
      return errorConnectionNum


proc returnConn(self: BaradbConnections | BaradbQuery | RawBaradbQuery, i: int) {.async.} =
  if i != errorConnectionNum:
    self.pools.conns[i].isBusy = false
    self.pools.conns[i].lastUsedAt = nowUnix()
    wakeOnePoolWaiter(self.pools)


proc raisePoolTimeout(self: BaradbConnections | BaradbQuery | RawBaradbQuery) {.noreturn.} =
  raise newException(DbError, "Timed out while waiting for a free Baradb connection")


# ================================================================================
# SQL formatting helpers
# ================================================================================

proc escapeSqlValue(val: JsonNode): string =
  case val.kind
  of JNull:
    return "NULL"
  of JBool:
    return if val.getBool: "TRUE" else: "FALSE"
  of JInt:
    return $val.getInt
  of JFloat:
    return $val.getFloat
  of JString:
    let s = val.getStr
    return "'" & s.replace("'", "''") & "'"
  else:
    return "'" & val.pretty.replace("'", "''") & "'"


proc formatSql*(sql: string, args: seq[JsonNode]): string =
  result = sql
  for arg in args:
    let pos = result.find("?")
    if pos < 0:
      break
    result = result[0..<pos] & escapeSqlValue(arg) & result[pos+1..^1]


proc formatSql*(sql: string, args: JsonNode): string =
  var arr: seq[JsonNode]
  for arg in args.items:
    arr.add(arg["value"])
  return formatSql(sql, arr)


# ================================================================================
# toJson
# ================================================================================

proc toJson*(resultSet: QueryResult): seq[JsonNode] =
  var response_table = newSeq[JsonNode](resultSet.rowCount)
  for r in 0 ..< resultSet.rowCount:
    var response_row = newJObject()
    for c in 0 ..< resultSet.columns.len:
      let key = resultSet.columns[c]
      let val = resultSet.rows[r][c]
      if val.len == 0:
        response_row[key] = newJNull()
      elif val == "NULL" or val == "null":
        response_row[key] = newJNull()
      elif val == "t" or val == "true" or val == "f" or val == "false":
        response_row[key] = newJBool(val == "t" or val == "true")
      else:
        try:
          response_row[key] = newJInt(val.parseInt)
        except ValueError:
          try:
            response_row[key] = newJFloat(val.parseFloat)
          except ValueError:
            response_row[key] = newJString(val)
    response_table[r] = response_row
  return response_table


# ================================================================================
# private exec
# ================================================================================

proc getAllRows(self: BaradbQuery, queryString: string): Future[seq[JsonNode]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  let sql = formatSql(queryString, self.placeHolder)
  let qr = await self.pools.conns[connI].client.query(sql)

  if qr.rowCount == 0:
    self.log.echoErrorMsg(queryString)
    return newSeq[JsonNode](0)
  return toJson(qr)


proc getAllRowsPlain(self: BaradbQuery, queryString: string, args: JsonNode): Future[seq[seq[string]]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  let sql = formatSql(queryString, args)
  let qr = await self.pools.conns[connI].client.query(sql)
  return qr.rows


proc getRow(self: BaradbQuery, queryString: string): Future[Option[JsonNode]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  let sql = formatSql(queryString, self.placeHolder)
  let qr = await self.pools.conns[connI].client.query(sql)

  if qr.rowCount == 0:
    self.log.echoErrorMsg(queryString)
    return none(JsonNode)
  return toJson(qr)[0].some()


proc getRowPlain(self: BaradbQuery, queryString: string, args: JsonNode): Future[seq[string]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  let sql = formatSql(queryString, args)
  let qr = await self.pools.conns[connI].client.query(sql)
  return qr.rows[0]


proc getAllRows(self: RawBaradbQuery, queryString: string): Future[seq[JsonNode]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  var arr: seq[JsonNode]
  for arg in self.placeHolder.items:
    arr.add(arg)
  let sql = formatSql(queryString, arr)
  let qr = await self.pools.conns[connI].client.query(sql)

  if qr.rowCount == 0:
    self.log.echoErrorMsg(queryString)
    return newSeq[JsonNode](0)
  return toJson(qr)


proc getAllRowsPlain(self: RawBaradbQuery, queryString: string, args: JsonNode): Future[seq[seq[string]]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  var arr: seq[JsonNode]
  for arg in args.items:
    arr.add(arg)
  let sql = formatSql(queryString, arr)
  let qr = await self.pools.conns[connI].client.query(sql)
  return qr.rows


proc getRow(self: RawBaradbQuery, queryString: string): Future[Option[JsonNode]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  var arr: seq[JsonNode]
  for arg in self.placeHolder.items:
    arr.add(arg)
  let sql = formatSql(queryString, arr)
  let qr = await self.pools.conns[connI].client.query(sql)

  if qr.rowCount == 0:
    self.log.echoErrorMsg(queryString)
    return none(JsonNode)
  return toJson(qr)[0].some()


proc getRowPlain(self: RawBaradbQuery, queryString: string, args: JsonNode): Future[seq[string]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  var arr: seq[JsonNode]
  for arg in args.items:
    arr.add(arg)
  let sql = formatSql(queryString, arr)
  let qr = await self.pools.conns[connI].client.query(sql)
  return qr.rows[0]


proc exec(self: BaradbQuery, queryString: string) {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  let sql = formatSql(queryString, self.placeHolder)
  discard await self.pools.conns[connI].client.exec(sql)


proc exec(self: RawBaradbQuery, queryString: string, args: JsonNode) {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  var arr: seq[JsonNode]
  for arg in args.items:
    arr.add(arg)
  let sql = formatSql(queryString, arr)
  discard await self.pools.conns[connI].client.exec(sql)


proc insertId(self: BaradbQuery, queryString: string, key: string): Future[string] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  let sql = formatSql(queryString, self.placeHolder) & &" RETURNING `{key}`"
  let qr = await self.pools.conns[connI].client.query(sql)
  if qr.rowCount > 0 and qr.rows[0].len > 0:
    return qr.rows[0][0]
  return ""


proc getColumns(self: BaradbQuery, queryString: string, args = newJArray()): Future[seq[string]] {.async.} =
  var connI = self.transactionConn
  if not self.isInTransaction:
    connI = getFreeConn(self).await
  defer:
    if not self.isInTransaction:
      self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)

  var arr: seq[JsonNode]
  for arg in args.items:
    arr.add(arg["value"])
  let sql = formatSql(queryString, arr)
  let qr = await self.pools.conns[connI].client.query(sql)
  if qr.rowCount > 0:
    return qr.rows[0]
  return @[]


proc transactionStart(self: BaradbConnections) {.async.} =
  let connI = getFreeConn(self).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  self.isInTransaction = true
  self.transactionConn = connI
  discard await self.pools.conns[connI].client.exec("BEGIN")


proc transactionEnd(self: BaradbConnections, query: string) {.async.} =
  defer:
    self.returnConn(self.transactionConn).await
    self.transactionConn = 0
    self.isInTransaction = false

  discard await self.pools.conns[self.transactionConn].client.exec(query)


# ================================================================================
# public exec
# ================================================================================

# ==================== return json ====================
proc get*(self: BaradbQuery): Future[seq[JsonNode]] {.async.} =
  let sql = self.selectBuilder()
  try:
    self.log.logger(sql)
    return await self.getAllRows(sql)
  except CatchableError:
    self.log.echoErrorMsg(sql)
    self.log.echoErrorMsg(getCurrentExceptionMsg())
    raise getCurrentException()


proc first*(self: BaradbQuery): Future[Option[JsonNode]] {.async.} =
  let sql = self.selectFirstBuilder()
  try:
    self.log.logger(sql)
    return await self.getRow(sql)
  except CatchableError:
    self.log.echoErrorMsg(sql)
    self.log.echoErrorMsg(getCurrentExceptionMsg())
    raise getCurrentException()


proc find*(self: BaradbQuery, id: string, key = "id"): Future[Option[JsonNode]] {.async.} =
  self.placeHolder.add(%*{"key": key, "value": id})
  let sql = self.selectFindBuilder(key)
  try:
    self.log.logger(sql)
    return await self.getRow(sql)
  except CatchableError:
    self.log.echoErrorMsg(sql)
    self.log.echoErrorMsg(getCurrentExceptionMsg())
    raise getCurrentException()


proc find*(self: BaradbQuery, id: int, key = "id"): Future[Option[JsonNode]] {.async.} =
  return await self.find($id, key)


# ==================== return string ====================
proc getPlain*(self: BaradbQuery): Future[seq[seq[string]]] {.async.} =
  let sql = self.selectBuilder()
  try:
    self.log.logger(sql)
    return await self.getAllRowsPlain(sql, self.placeHolder)
  except CatchableError:
    self.log.echoErrorMsg(sql)
    self.log.echoErrorMsg(getCurrentExceptionMsg())
    raise getCurrentException()


proc firstPlain*(self: BaradbQuery): Future[seq[string]] {.async.} =
  let sql = self.selectFirstBuilder()
  try:
    self.log.logger(sql)
    return await self.getRowPlain(sql, self.placeHolder)
  except CatchableError:
    self.log.echoErrorMsg(sql)
    self.log.echoErrorMsg(getCurrentExceptionMsg())
    raise getCurrentException()


proc findPlain*(self: BaradbQuery, id: string, key = "id"): Future[seq[string]] {.async.} =
  self.placeHolder.add(%*{"key": key, "value": id})
  let sql = self.selectFindBuilder(key)
  try:
    self.log.logger(sql)
    return await self.getRowPlain(sql, self.placeHolder)
  except CatchableError:
    self.log.echoErrorMsg(sql)
    self.log.echoErrorMsg(getCurrentExceptionMsg())
    raise getCurrentException()


proc findPlain*(self: BaradbQuery, id: int, key = "id"): Future[seq[string]] {.async.} =
  return await self.findPlain($id, key)


# ==================== insert JsonNode ====================
proc insert*(self: BaradbQuery, items: JsonNode) {.async.} =
  let sql = self.insertValueBuilder(items)
  self.log.logger(sql)
  await self.exec(sql)


proc insert*(self: BaradbQuery, items: seq[JsonNode]) {.async.} =
  let sql = self.insertValuesBuilder(items)
  self.log.logger(sql)
  await self.exec(sql)


proc insertId*(self: BaradbQuery, items: JsonNode, key = "id"): Future[string] {.async.} =
  let sql = self.insertValueBuilder(items)
  self.log.logger(sql)
  return await self.insertId(sql, key)


proc insertId*(self: BaradbQuery, items: seq[JsonNode], key = "id"): Future[seq[string]] {.async.} =
  result = newSeq[string](items.len)
  for i, item in items:
    let sql = self.insertValueBuilder(item)
    self.log.logger(sql)
    result[i] = await self.insertId(sql, key)
    self.placeHolder = newJArray()


# ==================== insert Object ====================
proc insert*[T](self: BaradbQuery, items: T) {.async.} =
  let sql = self.insertValueBuilder(%items)
  self.log.logger(sql)
  await self.exec(sql)


proc insert*[T](self: BaradbQuery, items: seq[T]) {.async.} =
  let items = items.mapIt(%it)
  let sql = self.insertValuesBuilder(items)
  self.log.logger(sql)
  await self.exec(sql)


proc insertId*[T](self: BaradbQuery, items: T, key = "id"): Future[string] {.async.} =
  let sql = self.insertValueBuilder(%items)
  self.log.logger(sql)
  return await self.insertId(sql, key)


proc insertId*[T](self: BaradbQuery, items: seq[T], key = "id"): Future[seq[string]] {.async.} =
  result = newSeq[string](items.len)
  for i, item in items:
    let sql = self.insertValueBuilder(%item)
    self.log.logger(sql)
    result[i] = await self.insertId(sql, key)
    self.placeHolder = newJArray()


# ==================== update ====================
proc update*(self: BaradbQuery, items: JsonNode) {.async.} =
  let sql = self.updateBuilder(items)
  self.log.logger(sql)
  await self.exec(sql)


proc update*[T](self: BaradbQuery, items: T) {.async.} =
  let sql = self.updateBuilder(%items)
  self.log.logger(sql)
  await self.exec(sql)


proc delete*(self: BaradbQuery) {.async.} =
  let sql = self.deleteBuilder()
  self.log.logger(sql)
  await self.exec(sql)


proc delete*(self: BaradbQuery, id: int, key = "id") {.async.} =
  let sql = self.deleteByIdBuilder(id, key)
  self.log.logger(sql)
  self.placeHolder.add(%*{"key": key, "value": id})
  await self.exec(sql)


proc columns*(self: BaradbQuery): Future[seq[string]] {.async.} =
  let sql = self.columnBuilder()
  self.log.logger(sql)
  return await self.getColumns(sql, self.placeHolder)


proc count*(self: BaradbQuery): Future[int] {.async.} =
  let sql = self.countBuilder()
  self.log.logger(sql)
  let response = await self.getRow(sql)
  if response.isSome:
    return response.get["aggregate"].getStr().parseInt()
  else:
    return 0


proc min*(self: BaradbQuery, column: string): Future[Option[string]] {.async.} =
  let sql = self.minBuilder(column)
  self.log.logger(sql)
  let response = await self.getRow(sql)
  if response.isSome:
    case response.get["aggregate"].kind
    of JInt:
      return some($(response.get["aggregate"].getInt))
    of JFloat:
      return some($(response.get["aggregate"].getFloat))
    else:
      return some(response.get["aggregate"].getStr)
  else:
    return none(string)


proc max*(self: BaradbQuery, column: string): Future[Option[string]] {.async.} =
  let sql = self.maxBuilder(column)
  self.log.logger(sql)
  let response = await self.getRow(sql)
  if response.isSome:
    case response.get["aggregate"].kind
    of JInt:
      return some($(response.get["aggregate"].getInt))
    of JFloat:
      return some($(response.get["aggregate"].getFloat))
    else:
      return some(response.get["aggregate"].getStr)
  else:
    return none(string)


proc avg*(self: BaradbQuery, column: string): Future[Option[float]] {.async.} =
  let sql = self.avgBuilder(column)
  self.log.logger(sql)
  let response = await self.getRow(sql)
  if response.isSome:
    return response.get["aggregate"].getStr().parseFloat.some
  else:
    return none(float)


proc sum*(self: BaradbQuery, column: string): Future[Option[float]] {.async.} =
  let sql = self.sumBuilder(column)
  self.log.logger(sql)
  let response = await self.getRow(sql)
  if response.isSome:
    return response.get["aggregate"].getStr.parseFloat.some
  else:
    return none(float)


proc begin*(self: BaradbConnections) {.async.} =
  self.log.logger("BEGIN")
  await self.transactionStart()


proc rollback*(self: BaradbConnections) {.async.} =
  self.log.logger("ROLLBACK")
  await self.transactionEnd("ROLLBACK")


proc commit*(self: BaradbConnections) {.async.} =
  self.log.logger("COMMIT")
  await self.transactionEnd("COMMIT")


# raw queries
proc get*(self: RawBaradbQuery): Future[seq[JsonNode]] {.async.} =
  self.log.logger(self.queryString)
  return await self.getAllRows(self.queryString)


proc getPlain*(self: RawBaradbQuery): Future[seq[seq[string]]] {.async.} =
  self.log.logger(self.queryString)
  return await self.getAllRowsPlain(self.queryString, self.placeHolder)


proc exec*(self: RawBaradbQuery) {.async.} =
  self.log.logger(self.queryString)
  await self.exec(self.queryString, self.placeHolder)


proc first*(self: RawBaradbQuery): Future[Option[JsonNode]] {.async.} =
  self.log.logger(self.queryString)
  return await self.getRow(self.queryString)


proc firstPlain*(self: RawBaradbQuery): Future[seq[string]] {.async.} =
  self.log.logger(self.queryString)
  return await self.getRowPlain(self.queryString, self.placeHolder)


# ================================================================================
# Pagination (cursor-based and offset-based)
# ================================================================================

type
  PaginateResult* = object
    rows*: seq[JsonNode]
    total*: int
    page*: int
    perPage*: int
    hasMore*: bool

proc paginate*(self: BaradbQuery, page: int = 1, perPage: int = 20): Future[PaginateResult] {.async.} =
  ## Offset-based pagination. Returns rows for the given page plus metadata.
  let total = await self.count()
  let offset = (page - 1) * perPage
  self.limit(perPage)
  self.offset(offset)
  let rows = await self.get()
  let qr = PaginateResult(
    rows: rows,
    total: total,
    page: page,
    perPage: perPage,
    hasMore: offset + perPage < total
  )
  return qr

proc fastPaginate*(self: BaradbQuery, cursorColumn: string, perPage: int = 20,
                    afterId: string = ""): Future[PaginateResult] {.async.} =
  ## Cursor-based pagination (keyset). More efficient than offset for large tables.
  ## Requires a unique, ordered column (usually the primary key).
  let total = await self.count()
  self.limit(perPage)
  self.orderBy(cursorColumn, Asc)
  if afterId.len > 0:
    self.where(cursorColumn, ">", afterId)
  let rows = await self.get()
  var hasMore = rows.len == perPage
  let qr = PaginateResult(
    rows: rows,
    total: total,
    page: 0,  # cursor-based has no page number
    perPage: perPage,
    hasMore: hasMore
  )
  return qr

# ================================================================================
# Migration API (BaraQL native — server handles checksums, locks, rollback)
# ================================================================================

proc createMigration*(self: BaradbConnections, name: string, upBody: string,
                      downBody: string = ""): Future[QueryResult] {.async.} =
  ## Register a migration on the server. The server computes checksums, stores
  ## the UP/DOWN bodies, and manages the migration lifecycle.
  var connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  return await self.pools.conns[connI].client.createMigration(name, upBody, downBody)

proc applyMigration*(self: BaradbConnections, name: string): Future[QueryResult] {.async.} =
  var connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  return await self.pools.conns[connI].client.applyMigration(name)

proc migrateUp*(self: BaradbConnections, count: int = 0): Future[QueryResult] {.async.} =
  var connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  return await self.pools.conns[connI].client.migrateUp(count)

proc migrateDown*(self: BaradbConnections, count: int = 1): Future[QueryResult] {.async.} =
  var connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  return await self.pools.conns[connI].client.migrateDown(count)

proc migrationStatus*(self: BaradbConnections): Future[seq[JsonNode]] {.async.} =
  var connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  let qr = await self.pools.conns[connI].client.migrationStatus()
  return toJson(qr)

proc migrationDryRun*(self: BaradbConnections, name: string): Future[QueryResult] {.async.} =
  var connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  return await self.pools.conns[connI].client.migrationDryRun(name)

proc isMigrationApplied*(self: BaradbConnections, name: string): Future[bool] {.async.} =
  let status = await self.migrationStatus()
  for row in status:
    if row["name"].getStr() == name and row["status"].getStr() == "applied":
      return true
  return false

# ================================================================================
# Prepared Statements (server-side parameterized queries via mkQueryParams)
# ================================================================================

proc sendPrepared(client: BaraClient, sql: string, params: seq[WireValue]): Future[QueryResult] {.async.} =
  if not client.connected:
    raise newException(IOError, "Not connected")
  let msg = makeQueryParamsMessage(client.nextId(), sql, params)
  let msgStr = toString(msg)
  await client.socket.send(msgStr)
  return await client.readQueryResponse()

proc prepare*(self: BaradbConnections, sql: string, nArgs: int = 0): Future[BaradbPreparedStatement] {.async.} =
  ## Create a server-side prepared statement. Subsequent calls reuse the cached entry.
  let entryKey = sql & ":" & $nArgs
  if entryKey in self.pools.preparedCache:
    let entry = self.pools.preparedCache[entryKey]
    inc entry.refCount
    entry.lastUsedAt = nowUnix()
    return BaradbPreparedStatement(owner: self, entry: entry, sql: sql,
                                    nArgs: nArgs, isClosed: false)
  let entry = BaradbPreparedEntry(sql: sql, nArgs: nArgs, refCount: 1,
                                   lastUsedAt: nowUnix())
  self.pools.preparedCache[entryKey] = entry
  return BaradbPreparedStatement(owner: self, entry: entry, sql: sql,
                                  nArgs: nArgs, isClosed: false)

proc ensureStmt*(self: BaradbConnections, sql: string, nArgs: int): BaradbPreparedEntry =
  let entryKey = sql & ":" & $nArgs
  if entryKey in self.pools.preparedCache:
    let entry = self.pools.preparedCache[entryKey]
    entry.lastUsedAt = nowUnix()
    return entry
  let entry = BaradbPreparedEntry(sql: sql, nArgs: nArgs, refCount: 0,
                                   lastUsedAt: nowUnix())
  self.pools.preparedCache[entryKey] = entry
  return entry

proc preparedGet*(stmt: BaradbPreparedStatement, args: seq[WireValue]): Future[seq[JsonNode]] {.async.} =
  if stmt.isClosed:
    raise newException(IOError, "Prepared statement is closed")
  var connI = getFreeConn(stmt.owner).await
  defer: stmt.owner.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(stmt.owner)
  let qr = await sendPrepared(stmt.owner.pools.conns[connI].client, stmt.sql, args)
  return toJson(qr)

proc preparedExec*(stmt: BaradbPreparedStatement, args: seq[WireValue]): Future[int] {.async.} =
  if stmt.isClosed:
    raise newException(IOError, "Prepared statement is closed")
  var connI = getFreeConn(stmt.owner).await
  defer: stmt.owner.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(stmt.owner)
  let qr = await sendPrepared(stmt.owner.pools.conns[connI].client, stmt.sql, args)
  return qr.affectedRows

proc flushStmt*(stmt: BaradbPreparedStatement) =
  stmt.isClosed = true
  dec stmt.entry.refCount

proc clearStmtCache*(self: BaradbConnections) =
  self.pools.preparedCache.clear()

proc withConn*(self: BaradbConnections, callback: proc(connI: int): Future[void] {.gcsafe.}): Future[void] {.async.} =
  let connI = getFreeConn(self).await
  defer: self.returnConn(connI).await
  if connI == errorConnectionNum:
    raisePoolTimeout(self)
  await callback(connI)

# seeder templates
template seeder*(rdb: BaradbConnections, tableName: string, body: untyped): untyped =
  block:
    if waitFor rdb.table(tableName).count() == 0:
      body


template seeder*(rdb: BaradbConnections, tableName, column: string, body: untyped): untyped =
  block:
    if waitFor rdb.select(column).table(tableName).count() == 0:
      body
