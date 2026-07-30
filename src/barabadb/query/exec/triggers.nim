## Trigger firing and constraint validation (validateType, fireTriggers,
## validateConstraints, applyDefaultValues) — extracted from `executor.nim`
## (Task 11 of the executor split).
##
## fireTriggers executes trigger action statements via the query dispatcher,
## which lives in executor.nim (private executeQueryImpl). executor.nim
## imports this module, so the back-edge goes through the proc-var hook
## below (Nim forbids circular imports). executor.nim wires it at module
## scope.
import std/strutils
import std/tables
import std/json
import ../lexer as qlex
import ../parser as qpar
import ../ast
import ../../core/types
import ../../storage/lsm
import ../../storage/btree
import types
import values
import helpers
import lower
import eval

## Wired by executor.nim at module load. fireTriggers executes trigger
## action statements via the dispatcher; the hook breaks the module cycle.
var executeQueryHook*: proc(ctx: ExecutionContext, astNode: Node): ExecResult

proc requireExecuteQueryHook(): proc(ctx: ExecutionContext, astNode: Node): ExecResult =
  if executeQueryHook == nil:
    raise newException(ValueError, "executeQueryHook not wired (import barabadb/query/executor)")
  executeQueryHook

# ----------------------------------------------------------------------
# Constraint Validation
# ----------------------------------------------------------------------

proc validateType*(colType: string, value: string): (bool, string) =
  if isNull(value): return (true, "")
  let t = colType.toUpper()
  if t == "INTEGER" or t == "INT" or t == "BIGINT" or t == "SMALLINT" or t == "SERIAL":
    try: discard parseInt(value)
    except CatchableError: return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "FLOAT" or t == "REAL" or t == "DOUBLE" or t == "DOUBLE PRECISION" or t == "NUMERIC":
    try: discard parseFloat(value)
    except CatchableError: return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "BOOLEAN" or t == "BOOL":
    let lv = value.toLower()
    if lv notin ["true", "false", "1", "0", "t", "f", "yes", "no"]:
      return (false, "Type mismatch: expected BOOLEAN but got '" & value & "'")
  elif t == "TIMESTAMP" or t == "DATE":
    if value.len < 8:  # minimal date check
      return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "JSON" or t == "JSONB":
    try:
      discard parseJson(value)
    except CatchableError:
      return (false, "Type mismatch: expected JSON but got '" & value & "'")
  elif t.startsWith("VECTOR"):
    let vec = parseVectorString(value)
    if vec.len == 0 and value.strip().len > 0:
      return (false, "Type mismatch: expected VECTOR but got '" & value & "'")
    var expectedDim = 0
    let dimStart = t.find('(')
    let dimEnd = t.find(')')
    if dimStart >= 0 and dimEnd > dimStart:
      try:
        expectedDim = parseInt(t[dimStart+1..<dimEnd])
      except CatchableError:
        expectedDim = 0
    if expectedDim > 0 and vec.len != expectedDim:
      return (false, "Vector dimension mismatch: expected " & $expectedDim & " but got " & $vec.len)
  return (true, "")

proc fireTriggers*(ctx: ExecutionContext, tableName: string, timing: string, event: string, row: Row) =
  let tbl = ctx.getTableDef(tableName)
  for trig in tbl.triggers:
    if trig.timing == timing and trig.event == event:
      if trig.action != nil:
        let tokens = qlex.tokenize(trig.action.strVal)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          discard requireExecuteQueryHook()(ctx, astNode)

proc validateConstraints*(ctx: ExecutionContext, tableName: string,
    fields: seq[string], values: seq[seq[string]], skipPkCheck: bool = false): (bool, string) =
  let tbl = ctx.getTableDef(tableName)

  for rowIdx, rowVals in values:
    for col in tbl.columns:
      let val = getValue(rowVals, fields, col.name)

      # NOT NULL check
      if col.isNotNull and isNull(val):
        return (false, "NOT NULL constraint violated for column '" & col.name & "'")

      # Type enforcement
      if col.colType.len > 0 and not isNull(val):
        let (typeOk, typeErr) = validateType(col.colType, val)
        if not typeOk:
          return (false, typeErr)

      # FK check — uses LSM get which searches memtable + SSTables
      if col.fkTable.len > 0 and col.fkColumn.len > 0 and not isNull(val):
        let fkKey = col.fkTable & "." & col.fkColumn & "=" & val
        let (fkExists, _) = ctx.db.get(fkKey)
        if not fkExists:
          return (false, "FOREIGN KEY violation: '" & val & "' not found in " & col.fkTable & "." & col.fkColumn)

    # PK uniqueness (skip during UPDATE — PK shouldn't change)
    if not skipPkCheck and tbl.pkColumns.len > 0:
      var pkVals: seq[string] = @[]
      var pkParts: seq[string] = @[]
      for pkCol in tbl.pkColumns:
        let pkVal = getValue(rowVals, fields, pkCol)
        pkVals.add(pkVal)
        pkParts.add(pkCol & "=" & escapeRowVal(pkVal))
      let pkStr = pkVals.join("|")
      # Check with composite PK format (as stored by execInsert)
      let pkKey = tableName & "." & pkParts.join(":")
      let (exists, _) = ctx.db.get(pkKey)
      if exists:
        return (false, "UNIQUE constraint violated: duplicate key '" & pkStr & "'")

    # UNIQUE constraint via B-Tree
    for col in tbl.columns:
      if col.isUnique:
        let uVal = getValue(rowVals, fields, col.name)
        if not isNull(uVal):
          let idxName = tableName & "." & col.name
          if idxName in ctx.btrees and ctx.btrees[idxName].contains(uVal):
            return (false, "UNIQUE constraint violated: duplicate '" & uVal & "' for column '" & col.name & "'")

    # CHECK constraints
    for check in tbl.checks:
      if check.checkNode != nil:
        var row = initTable[string, Value]()
        for i, f in fields:
          if i < rowVals.len:
            row[f] = rowVals[i]
          else:
            row[f] = Value(kind: vkNull)
        let checkExpr = lowerExpr(check.checkNode)
        let checkResult = evalExpr(checkExpr, row, ctx)
        if valueToString(checkResult) != "true":
          return (false, "CHECK constraint '" & check.name & "' violated")

  return (true, "")

proc applyDefaultValues*(tbl: TableDef, fields: var seq[string], values: var seq[seq[string]]) =
  for col in tbl.columns:
    if col.defaultVal.len == 0: continue
    var hasField = false
    for f in fields:
      if f.toLower() == col.name.toLower():
        hasField = true
        break
    if not hasField:
      fields.add(col.name)
      for rowIdx in 0..<values.len:
        values[rowIdx].add(col.defaultVal)
    else:
      for rowIdx in 0..<values.len:
        for i, f in fields:
          if f.toLower() == col.name.toLower() and i < values[rowIdx].len:
            if isNull(values[rowIdx][i]):
              values[rowIdx][i] = col.defaultVal
            break
