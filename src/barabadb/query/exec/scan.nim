## Table scans — full scans and point reads against the LSM store.
##
## Extracted from `executor.nim` (Task 8 of the executor split).
import std/strutils
import std/tables
import ../../storage/lsm
import types
import values
import helpers
import rls

# ----------------------------------------------------------------------
# Table scan and storage
# ----------------------------------------------------------------------

proc execScan*(ctx: ExecutionContext, table: string): seq[Row] =
  result = @[]
  # Check CTE tables first
  if table in ctx.cteTables:
    return ctx.cteTables[table]
  let prefix = table & "."
  for (key, value) in ctx.db.scanAll():
    if not key.startsWith(prefix): continue
    let rest = key[prefix.len..^1]
    var row: Row
    row["$key"] = rest
    let valStr = cast[string](value)
    row["$value"] = valStr
    # Also parse individual columns
    for k, v in parseRowData(valStr):
      row[k] = v
    # Extract PK value from key
    let eqPos = rest.find('=')
    if eqPos >= 0:
      row[rest[0..<eqPos]] = rest[eqPos+1..^1]
    # RLS filter
    if passesPolicy(ctx, table, "SELECT", row):
      # Inject qualified columns from outerRow for correlated subqueries
      if ctx.outerRow.len > 0:
        var outerTables: seq[string] = @[]
        # Try to infer outer table from qualified refs already in outerRow keys
        for k in ctx.outerRow.keys:
          if k.contains('.') and not k.startsWith('$'):
            let tbl = k.split('.')[0]
            if tbl notin outerTables: outerTables.add(tbl)
        # If no qualified keys found, scan subquery plan for correlated refs
        if outerTables.len == 0 and ctx.subqueryPlan != nil:
          collectCorrelatedTablesFromPlan(ctx.subqueryPlan, outerTables)
        # Inject qualified columns
        for k, v in ctx.outerRow:
          if k.startsWith('$'): continue
          if k.contains('.'): continue  # already qualified
          for tbl in outerTables:
            row[tbl & "." & k] = v
      result.add(row)

proc execPointRead*(ctx: ExecutionContext, table: string, key: string): seq[Row] =
  let fullKey = table & "." & key
  let (found, val) = ctx.db.get(fullKey)
  if found:
    var row: Row
    row["$key"] = key
    let valStr = cast[string](val)
    row["$value"] = valStr
    for k, v in parseRowData(valStr):
      row[k] = v
    let eqPos = key.find('=')
    if eqPos >= 0:
      row[key[0..<eqPos]] = key[eqPos+1..^1]
    return @[row]
  return @[]
