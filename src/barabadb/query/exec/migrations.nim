## Migration storage helpers — lock acquisition, applied/record keys, checksums.
##
## Extracted from `executor.nim` (Task 4 of the executor split).
## Internal module: imported by executor.nim but NOT re-exported.
import std/strutils
import std/times
import std/algorithm
import checksums/sha2
import ../../storage/lsm
import types
import context

# ----------------------------------------------------------------------
# Migration Helpers
# ----------------------------------------------------------------------

proc migrationLockKey(): string = "_schema:migrations:_lock"

proc acquireMigrationLock*(ctx: ExecutionContext): bool =
  let lockKey = migrationLockKey()
  let (locked, lockVal) = ctx.db.get(lockKey)
  if locked:
    # Check for stale lock (older than 1 hour)
    let lockTime = try: parseInt(cast[string](lockVal)) except CatchableError: 0
    if lockTime > 0 and (epochTime().int64 - lockTime) > 3600:
      # Stale lock — force release
      ctx.db.delete(lockKey)
    else:
      return false
  ctx.db.put(lockKey, cast[seq[byte]]($epochTime().int64))
  return true

proc releaseMigrationLock*(ctx: ExecutionContext) =
  ctx.db.delete(migrationLockKey())

proc migrationAppliedKey*(name: string): string = "_schema:migrations:applied:" & name

proc migrationRecordKey(name: string): string = "_schema:migrations:record:" & name

proc isMigrationApplied*(ctx: ExecutionContext, name: string): bool =
  let (applied, _) = ctx.db.get(migrationAppliedKey(name))
  return applied

proc getMigrationRecord*(ctx: ExecutionContext, name: string): MigrationRecord =
  let (found, val) = ctx.db.get(migrationRecordKey(name))
  if found:
    let parts = cast[string](val).split("|")
    if parts.len >= 5:
      return MigrationRecord(
        name: parts[0],
        checksum: parts[1],
        appliedAt: parseInt(parts[2]),
        appliedBy: parts[3],
        durationMs: parseInt(parts[4]),
        rolledBack: if parts.len >= 6: parts[5] == "true" else: false
      )
  return MigrationRecord(name: name)

proc setMigrationRecord*(ctx: ExecutionContext, rec: MigrationRecord) =
  let val = rec.name & "|" & rec.checksum & "|" & $rec.appliedAt & "|" &
            rec.appliedBy & "|" & $rec.durationMs & "|" & (if rec.rolledBack: "true" else: "false")
  ctx.db.put(migrationRecordKey(rec.name), cast[seq[byte]](val))

proc computeChecksum*(body: string): string =
  let h = secureHash(Sha_256, body)
  return $h

proc listMigrations*(ctx: ExecutionContext): seq[string] =
  result = @[]
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if entry.key.startsWith("_schema:migration:") and not entry.key.contains(":applied:") and
       not entry.key.contains(":record:") and not entry.key.contains(":_lock"):
      let name = entry.key["_schema:migration:".len..^1]
      result.add(name)
  sort(result)

proc getMigrationBody*(ctx: ExecutionContext, name: string): (bool, string, string) =
  let migKey = "_schema:migration:" & name
  let (found, val) = ctx.db.get(migKey)
  if found:
    let ddl = cast[string](val)
    let parts = ddl.split("|DOWN|", 1)
    if parts.len == 2:
      return (true, parts[0], parts[1])
    else:
      return (true, ddl, "")
  return (false, "", "")
