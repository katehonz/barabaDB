## BaraDB Database Registry — manages per-database LSMTree instances
import std/tables
import std/os
import std/strutils
import std/locks
import std/algorithm
import logging
import config
import ../storage/lsm

type
  ContextRef* = ref RootObj

  ContextFactory* = proc(db: LSMTree, reg: DatabaseRegistry): ContextRef {.closure.}

  DatabaseInfo* = ref object
    name*: string
    db*: LSMTree
    ctx*: ContextRef
    activeConnections*: int

  DatabaseRegistry* = ref object
    config*: BaraConfig
    databases: Table[string, DatabaseInfo]
    lock*: Lock
    defaultDbName*: string
    dataRoot*: string
    ctxFactory*: ContextFactory

const reservedDbNames* = ["system", "information_schema", "pg_catalog"]

proc isValidDbName*(name: string): bool =
  if name.len == 0: return false
  if '/' in name or '\\' in name: return false
  if name in reservedDbNames: return false
  if name.startsWith("_"): return false
  if name == ".." or name == ".": return false
  true

proc newDatabaseRegistry*(config: BaraConfig, defaultDbName = "default"): DatabaseRegistry =
  new(result)
  result.config = config
  result.databases = initTable[string, DatabaseInfo]()
  result.defaultDbName = defaultDbName
  result.dataRoot = config.dataDir / "databases"
  initLock(result.lock)

  # Create root directory
  if not dirExists(result.dataRoot):
    createDir(result.dataRoot)

proc setContextFactory*(reg: DatabaseRegistry, factory: ContextFactory) =
  reg.ctxFactory = factory

proc loadExistingDatabases*(reg: DatabaseRegistry) =
  if reg.ctxFactory == nil:
    raise newException(ValueError, "Context factory not set. Call setContextFactory first.")

  # Scan for existing databases
  for kind, path in walkDir(reg.dataRoot):
    if kind == pcDir:
      let dbName = path.splitPath().tail
      if dbName.len > 0 and isValidDbName(dbName):
        let dbDir = reg.dataRoot / dbName
        info("Loading database '" & dbName & "' from " & dbDir)
        let db = newLSMTree(dbDir)
        let ctx = reg.ctxFactory(db, reg)
        reg.databases[dbName] = DatabaseInfo(
          name: dbName, db: db, ctx: ctx, activeConnections: 0
        )

proc setDatabase*(reg: DatabaseRegistry, name: string, db: LSMTree, ctx: ContextRef) =
  acquire(reg.lock)
  defer: release(reg.lock)
  reg.databases[name] = DatabaseInfo(
    name: name, db: db, ctx: ctx, activeConnections: 0)

proc ensureDefaultDatabase*(reg: DatabaseRegistry) =
  if reg.ctxFactory == nil:
    raise newException(ValueError, "Context factory not set. Call setContextFactory first.")

  let defaultDbName = reg.defaultDbName
  if defaultDbName notin reg.databases:
    let dbDir = reg.dataRoot / defaultDbName
    info("Creating default database at " & dbDir)
    let db = newLSMTree(dbDir)
    let ctx = reg.ctxFactory(db, reg)
    reg.databases[defaultDbName] = DatabaseInfo(
      name: defaultDbName, db: db, ctx: ctx, activeConnections: 0
    )

proc getOrCreateDatabase*(reg: DatabaseRegistry, name: string): DatabaseInfo =
  if not isValidDbName(name):
    raise newException(ValueError, "Invalid database name: " & name)

  if reg.ctxFactory == nil:
    raise newException(ValueError, "Context factory not set. Call setContextFactory first.")

  acquire(reg.lock)
  defer: release(reg.lock)

  if name in reg.databases:
    return reg.databases[name]

  # Create new database
  let dbDir = reg.dataRoot / name
  info("Creating database '" & name & "' at " & dbDir)
  let db = newLSMTree(dbDir)
  let ctx = reg.ctxFactory(db, reg)
  let info = DatabaseInfo(name: name, db: db, ctx: ctx, activeConnections: 0)
  reg.databases[name] = info
  info

proc getConnectionCount*(reg: DatabaseRegistry, name: string): int =
  acquire(reg.lock)
  defer: release(reg.lock)
  if name in reg.databases:
    return reg.databases[name].activeConnections
  return 0

proc incrementConnections*(reg: DatabaseRegistry, name: string) =
  acquire(reg.lock)
  defer: release(reg.lock)
  if name in reg.databases:
    inc reg.databases[name].activeConnections

proc decrementConnections*(reg: DatabaseRegistry, name: string) =
  acquire(reg.lock)
  defer: release(reg.lock)
  if name in reg.databases and reg.databases[name].activeConnections > 0:
    dec reg.databases[name].activeConnections

proc dropDatabase*(reg: DatabaseRegistry, name: string): bool =
  if not isValidDbName(name):
    return false

  acquire(reg.lock)
  defer: release(reg.lock)

  if name notin reg.databases:
    return false

  if name == reg.defaultDbName:
    raise newException(ValueError, "Cannot drop the default database")

  let info = reg.databases[name]
  if info.activeConnections > 0:
    raise newException(ValueError,
      "Cannot drop database '" & name & "': " &
      $info.activeConnections & " active connections")

  # Close LSMTree
  info.db.close()

  # Remove data directory
  let dbDir = reg.dataRoot / name
  if dirExists(dbDir):
    removeDir(dbDir)

  reg.databases.del(name)
  true

proc listDatabases*(reg: DatabaseRegistry): seq[string] =
  acquire(reg.lock)
  defer: release(reg.lock)
  result = @[]
  for name in reg.databases.keys:
    result.add(name)
  result.sort()

proc databaseExists*(reg: DatabaseRegistry, name: string): bool =
  acquire(reg.lock)
  defer: release(reg.lock)
  name in reg.databases

proc getDatabaseInfo*(reg: DatabaseRegistry, name: string): DatabaseInfo =
  acquire(reg.lock)
  defer: release(reg.lock)
  if name in reg.databases:
    return reg.databases[name]
  return nil

proc closeAll*(reg: DatabaseRegistry) =
  acquire(reg.lock)
  defer: release(reg.lock)
  for name, info in reg.databases.pairs:
    try:
      info.db.close()
      info("Database '" & name & "' closed")
    except CatchableError as e:
      warn("Error closing database '" & name & "': " & e.msg)
  reg.databases.clear()
