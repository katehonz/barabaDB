## Foreign-key enforcement — referential checks and cascade actions.
##
## Extracted from `executor.nim` (Task 10 of the executor split).
import std/strutils
import std/tables
import ../../storage/lsm
import types
import values
import scan
import dml

# ----------------------------------------------------------------------
# Foreign Key Enforcement
# ----------------------------------------------------------------------

proc findReferencingRows*(ctx: ExecutionContext, childTable: string, fkCol: string, fkValue: string): seq[Row] =
  result = @[]
  for row in execScan(ctx, childTable):
    if fkCol in row and valueToString(row[fkCol]) == fkValue:
      result.add(row)

proc enforceFkOnDelete*(ctx: ExecutionContext, parentTable: string, parentCol: string, parentVal: string): (bool, string) =
  for childTblName, childTbl in ctx.tables:
    for col in childTbl.columns:
      if col.fkTable == parentTable and col.fkColumn == parentCol:
        let action = if col.fkOnDelete.len > 0: col.fkOnDelete else: "RESTRICT"
        let refs = findReferencingRows(ctx, childTblName, col.name, parentVal)
        if refs.len > 0:
          case action
          of "CASCADE":
            for refRow in refs:
              if "$key" in refRow:
                var dummy: seq[(string, seq[byte])] = @[]
                discard execDelete(ctx, childTblName, valueToString(refRow["$key"]), dummy)
          of "SET NULL":
            for refRow in refs:
              if "$key" in refRow:
                var sets = initTable[string, string]()
                sets[col.name] = "\\N"
                var dummy: seq[(string, seq[byte])] = @[]
                discard execUpdateRow(ctx, childTblName, valueToString(refRow["$key"]), sets, dummy)
          of "RESTRICT", "NO ACTION":
            return (false, "FOREIGN KEY violation: row is referenced by " & childTblName & "." & col.name)
  return (true, "")

proc enforceFkOnUpdate*(ctx: ExecutionContext, parentTable: string, parentCol: string, oldVal: string, newVal: string): (bool, string) =
  for childTblName, childTbl in ctx.tables:
    for col in childTbl.columns:
      if col.fkTable == parentTable and col.fkColumn == parentCol:
        let action = if col.fkOnUpdate.len > 0: col.fkOnUpdate else: "RESTRICT"
        let refs = findReferencingRows(ctx, childTblName, col.name, oldVal)
        if refs.len > 0:
          case action
          of "CASCADE":
            for refRow in refs:
              if "$key" in refRow:
                var sets = initTable[string, string]()
                sets[col.name] = newVal
                var dummy: seq[(string, seq[byte])] = @[]
                discard execUpdateRow(ctx, childTblName, valueToString(refRow["$key"]), sets, dummy)
          of "SET NULL":
            for refRow in refs:
              if "$key" in refRow:
                var sets = initTable[string, string]()
                sets[col.name] = "\\N"
                var dummy: seq[(string, seq[byte])] = @[]
                discard execUpdateRow(ctx, childTblName, valueToString(refRow["$key"]), sets, dummy)
          of "RESTRICT", "NO ACTION":
            return (false, "FOREIGN KEY violation: row is referenced by " & childTblName & "." & col.name)
  return (true, "")

proc enforceFkOnChildUpdate*(ctx: ExecutionContext, childTable: string, fkCol: string, newVal: string): (bool, string) =
  let tbl = ctx.getTableDef(childTable)
  var parentTable = ""
  var parentCol = ""
  for col in tbl.columns:
    if col.name == fkCol:
      parentTable = col.fkTable
      parentCol = col.fkColumn
      break
  if parentTable.len == 0 or parentCol.len == 0:
    return (true, "")
  if isNull(newVal):
    return (true, "")
  let fkKey = parentTable & "." & parentCol & "=" & newVal
  let (fkExists, _) = ctx.db.get(fkKey)
  if fkExists:
    return (true, "")
  var found = false
  let prefix = parentTable & "."
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if entry.key.startsWith(prefix):
      let rest = entry.key[prefix.len..^1]
      if rest.startsWith(parentCol & "=") and rest[parentCol.len+1..^1] == newVal:
        found = true
        break
  if not found:
    return (false, "FOREIGN KEY violation: '" & newVal & "' not found in " & parentTable & "." & parentCol)
  return (true, "")
