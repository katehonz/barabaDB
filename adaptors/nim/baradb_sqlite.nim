## BaraDB adapter mimicking db_sqlite API for NimForum

import std/strutils, std/tables, std/sequtils, std/parseutils
import ../../clients/nim/src/baradb/client as baradb_client

type
  DbError* = object of CatchableError
  SqlQuery* = distinct string
  DbConn* = distinct pointer

proc sql*(query: string): SqlQuery =
  SqlQuery(query)

proc dbError*(msg: string) {.noreturn.} =
  var e: ref DbError
  new(e)
  e.msg = msg
  raise e

proc dbQuote*(s: string): string =
  result = "'"
  for c in items(s):
    if c == '\'': add(result, "''")
    else: add(result, c)
  add(result, '\'')

proc dbFormat*(formatstr: SqlQuery, args: varargs[string]): string =
  var res = ""
  var a = 0
  for c in items(string(formatstr)):
    if c == '?':
      if a == args.len:
        dbError("""The number of \"?\" given exceeds the number of parameters present in the query.""")
      add(res, dbQuote(args[a]))
      inc(a)
    else:
      add(res, c)
  res

proc toClient(db: DbConn): SyncClient =
  cast[SyncClient](db)

proc open*(connection, user, password, database: string): DbConn =
  var config = defaultConfig()
  if connection.contains(':'):
    let parts = connection.split(':')
    config.host = parts[0]
    config.port = parseInt(parts[1])
  elif connection.len > 0 and not connection.endsWith(".db"):
    config.host = connection
  config.database = database
  config.username = user
  config.password = password
  var client = newSyncClient(config)
  client.connect()
  GC_ref(client)
  return cast[DbConn](client)

proc close*(db: DbConn) =
  let client = toClient(db)
  baradb_client.close(client)
  GC_unref(client)

proc exec*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]) =
  let client = toClient(db)
  let q = dbFormat(query, args)
  discard client.query(q)

proc tryExec*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): bool =
  try:
    let client = toClient(db)
    let q = dbFormat(query, args)
    discard client.query(q)
    return true
  except:
    return false

proc getRow*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): seq[string] =
  let client = toClient(db)
  let q = dbFormat(query, args)
  let qr = client.query(q)
  if qr.rows.len > 0:
    return qr.rows[0]
  else:
    return newSeq[string](qr.columns.len)

proc getAllRows*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): seq[seq[string]] =
  let client = toClient(db)
  let q = dbFormat(query, args)
  let qr = client.query(q)
  return qr.rows

proc getValue*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): string =
  let row = getRow(db, query, args)
  if row.len > 0: return row[0]
  return ""

iterator fastRows*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): seq[string] =
  let client = toClient(db)
  let q = dbFormat(query, args)
  let qr = client.query(q)
  for row in qr.rows:
    yield row

iterator rows*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): seq[string] =
  for r in fastRows(db, query, args): yield r

proc insertID*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): int64 =
  let client = toClient(db)
  let q = dbFormat(query, args)
  discard client.query(q)
  let sqlStr = string(query).strip().toLower()
  var tableName = ""
  if sqlStr.startsWith("insert into "):
    let rest = sqlStr[12..^1]
    let spacePos = rest.find(' ')
    if spacePos > 0:
      tableName = rest[0..<spacePos]
  if tableName.len > 0:
    let idQr = client.query("SELECT max(id) FROM " & tableName)
    if idQr.rows.len > 0 and idQr.rows[0].len > 0:
      try:
        return parseInt(idQr.rows[0][0]).int64
      except:
        discard
  return -1

proc tryInsertID*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): int64 =
  try:
    return insertID(db, query, args)
  except:
    return -1

proc nextId*(db: DbConn, tableName: string): int64 =
  let client = toClient(db)
  let qr = client.query("SELECT max(id) FROM " & tableName)
  if qr.rows.len > 0 and qr.rows[0].len > 0:
    try:
      let current = parseInt(qr.rows[0][0])
      return current.int64 + 1
    except:
      return 1
  return 1

proc execAffectedRows*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): int64 =
  let client = toClient(db)
  let q = dbFormat(query, args)
  let qr = client.query(q)
  return qr.affectedRows.int64
