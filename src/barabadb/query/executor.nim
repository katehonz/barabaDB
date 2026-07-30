## BaraQL Executor — AST lowering, IR compilation, and execution
##
## Shared types/helpers live under `exec/` (re-exported below for API stability).
## See `exec/README.md` for module map and further extraction plan.
import std/os
import std/strutils
import std/tables
import std/sets
import std/hashes
import std/sequtils
import std/algorithm
import std/math
import std/times
import std/json
import std/locks
import lexer as qlex
import parser as qpar
import ast
import ../core/types
import ../protocol/wire
import ../storage/lsm
import ../storage/btree
import ../storage/wal
import ../core/mvcc
import ../core/tracing
import ../core/logging
import ../client/fileops
import ../fts/engine as fts
import ../core/registry

import ../vector/engine as vengine
import ../graph/engine as gengine

import exec/types
import exec/values
import exec/schema
import exec/context
import exec/helpers
import exec/params
import exec/migrations  # internal — not re-exported
import exec/eval
import exec/lower
import exec/scan  # internal — not re-exported
import exec/dml
import exec/fk  # internal — not re-exported
import exec/triggers
import exec/window
import exec/plan_exec
export types
export values
export schema
export context
export helpers
export params
export eval
export lower
export dml
export triggers
export computeWindowValues  # re-export only what executor exported before the split
export plan_exec  # executePlan (API freeze)

# ----------------------------------------------------------------------
# Forward declarations
# ----------------------------------------------------------------------

proc executeQuery*(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult


proc executeQueryImpl(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult
proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult

# ----------------------------------------------------------------------
# High-level execute
# ----------------------------------------------------------------------

proc executeQueryImpl(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult =
  if astNode == nil or astNode.stmts.len == 0:
    return okResult()

  var boundAst = astNode
  if params.len > 0:
    boundAst = bindParams(astNode, params)

  let stmt = boundAst.stmts[0]
  let spanName = case stmt.kind
    of nkSelect: "SELECT"
    of nkInsert: "INSERT"
    of nkUpdate: "UPDATE"
    of nkDelete: "DELETE"
    of nkMerge: "MERGE"
    else: $stmt.kind
  let span = defaultTracer.beginSpan(spanName)
  defer: defaultTracer.endSpan(span)

  case stmt.kind
  of nkSelect:
    defer:
      ctx.cteTables.clear()
    # Execute CTEs if present
    if stmt.selWith.len > 0:
      for (cteName, cteQuery, isRecursive) in stmt.selWith:
        if isRecursive:
          # Recursive CTE: must be UNION ALL with anchor + recursive member
          if cteQuery.kind == nkSetOp and cteQuery.setOpKind == sdkUnion:
            var allRows: seq[Row] = @[]

            # Step 1: Execute the non-recursive anchor (left side of UNION)
            var innerLeft = Node(kind: nkStatementList, stmts: @[])
            innerLeft.stmts.add(cteQuery.setOpLeft)
            let anchorRes = executeQueryImpl(ctx, innerLeft)
            for row in anchorRes.rows:
              allRows.add(row)

            var workTable = anchorRes.rows
            const maxIterations = 1000
            var iteration = 0

            # Step 2: Iteratively execute the recursive member
            while workTable.len > 0 and iteration < maxIterations:
              # Save CTE state; recursive member's executeQuery will clear it via defer
              let savedCte = ctx.cteTables
              ctx.cteTables = {cteName: workTable}.toTable()

              var innerRight = Node(kind: nkStatementList, stmts: @[])
              innerRight.stmts.add(cteQuery.setOpRight)
              let rightRes = executeQueryImpl(ctx, innerRight)

              ctx.cteTables = savedCte

              var newRows: seq[Row] = @[]
              if not cteQuery.setOpAll:
                # UNION: deduplicate against all already-accumulated rows
                var seen = initTable[string, bool]()
                for existing in allRows:
                  let key = if "$value" in existing: valueToString(existing["$value"]) else: $existing
                  if key.len > 0:
                    seen[key] = true
                for row in rightRes.rows:
                  let key = if "$value" in row: valueToString(row["$value"]) else: $row
                  if not seen.getOrDefault(key, false):
                    if key.len > 0:
                      seen[key] = true
                    newRows.add(row)
              else:
                newRows = rightRes.rows

              if newRows.len == 0:
                break

              for row in newRows:
                allRows.add(row)
              workTable = newRows
              iteration += 1

            ctx.cteTables[cteName] = allRows
          else:
            # Recursive CTE without UNION — treat as non-recursive fallback
            var inner = Node(kind: nkStatementList, stmts: @[])
            inner.stmts.add(cteQuery)
            let cteRes = executeQueryImpl(ctx, inner)
            var cteRows: seq[Row] = @[]
            for row in cteRes.rows:
              cteRows.add(row)
            ctx.cteTables[cteName] = cteRows
        else:
          var inner = Node(kind: nkStatementList, stmts: @[])
          inner.stmts.add(cteQuery)
          let savedCte = ctx.cteTables
          let cteRes = executeQueryImpl(ctx, inner)
          ctx.cteTables = savedCte
          var cteRows: seq[Row] = @[]
          for row in cteRes.rows:
            cteRows.add(row)
          ctx.cteTables[cteName] = cteRows

    # Expand view if FROM table is a view
    if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom and stmt.selFrom.fromTable in ctx.views:
      let viewQuery = ctx.views[stmt.selFrom.fromTable]
      if viewQuery != nil and viewQuery.kind == nkSelect:
        # Execute the view's underlying query
        var inner = Node(kind: nkStatementList, stmts: @[])
        inner.stmts.add(viewQuery)
        let innerResult = executeQueryImpl(ctx, inner)
        # Now filter and project with outer query constraints
        var filteredRows = innerResult.rows
        var cols = innerResult.columns
        if stmt.selWhere != nil and stmt.selWhere.whereExpr != nil:
          let whereIr = lowerExpr(stmt.selWhere.whereExpr)
          var tmp: seq[Row] = @[]
          for row in filteredRows:
            if valueToString(evalExpr(whereIr, row, ctx)) == "true":
              tmp.add(row)
          filteredRows = tmp
        if stmt.selOrderBy.len > 0:
          let sortExpr = lowerExpr(stmt.selOrderBy[0].orderByExpr)
          let asc = stmt.selOrderBy[0].orderByDir == sdAsc
          proc sortCmp(a, b: Row): int =
            let va = evalExpr(sortExpr, a, ctx)
            let vb = evalExpr(sortExpr, b, ctx)
            try:
              let fa = parseFloat(valueToString(va))
              let fb = parseFloat(valueToString(vb))
              if fa < fb: return -1
              if fa > fb: return 1
              return 0
            except CatchableError:
              return cmp(valueToString(va), valueToString(vb))
          filteredRows.sort(sortCmp, if asc: Ascending else: Descending)
        if stmt.selLimit != nil:
          let limitVal = if stmt.selLimit.limitExpr.kind == nkIntLit:
            int(stmt.selLimit.limitExpr.intVal) else: 0
          if limitVal > 0 and limitVal < filteredRows.len:
            filteredRows = filteredRows[0..<limitVal]
        return okResult(filteredRows, cols)
      else:
        return errResult("Invalid view definition")

    # Try B-Tree index point read first
    if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom and stmt.selFrom.fromTable.len > 0:
      if stmt.selWhere != nil and stmt.selWhere.whereExpr != nil:
        let w = stmt.selWhere.whereExpr
        # Multi-column exact match: AND chain of =
        var eqConds: seq[(string, string)] = @[]
        var rangeCond: tuple[col: string, op: BinOpKind, val: string] = ("", bkEq, "")
        proc collectEq(node: Node) =
          if node.kind == nkBinOp and node.binOp == bkEq and node.binLeft.kind == nkIdent and node.binRight.kind == nkStringLit:
            eqConds.add((node.binLeft.identName, node.binRight.strVal))
          elif node.kind == nkBinOp and node.binOp == bkAnd:
            collectEq(node.binLeft)
            collectEq(node.binRight)
          elif node.kind == nkBinOp and node.binOp in {bkGt, bkGtEq, bkLt, bkLtEq} and
               node.binLeft.kind == nkIdent and node.binRight.kind == nkStringLit:
            rangeCond = (node.binLeft.identName, node.binOp, node.binRight.strVal)
        collectEq(w)
        # Multi-column exact match
        if eqConds.len >= 2:
          var idxCols: seq[string] = @[]
          for c in eqConds: idxCols.add(c[0])
          let idxName = stmt.selFrom.fromTable & "." & idxCols.join(".")
          if idxName in ctx.btrees:
            var idxVals: seq[string] = @[]
            for c in eqConds: idxVals.add(c[1])
            let idxVal = idxVals.join("|")
            let entries = ctx.btrees[idxName].get(idxVal)
            if entries.len > 0:
              var rows: seq[Row] = @[]
              for entry in entries:
                let (found, val) = ctx.db.get(entry.lsmKey)
                if found:
                  rows.add(parseRowDataToValueRow(cast[string](val)))
              let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
              var cols: seq[string] = @[]
              for c in tbl.columns: cols.add(c.name)
              if cols.len == 0: cols = @["key", "value"]
              return okResult(rows, cols)
        # Multi-column range scan: exact match on prefix + range on last column
        if eqConds.len >= 1 and rangeCond.col.len > 0:
          var idxCols: seq[string] = @[]
          for c in eqConds: idxCols.add(c[0])
          idxCols.add(rangeCond.col)
          let idxName = stmt.selFrom.fromTable & "." & idxCols.join(".")
          if idxName in ctx.btrees:
            var prefix: string = ""
            for c in eqConds:
              if prefix.len > 0: prefix.add("|")
              prefix.add(c[1])
            if prefix.len > 0: prefix.add("|")
            var startKey, endKey: string
            case rangeCond.op
            of bkGt:
              startKey = prefix & rangeCond.val & "\x01"  # just above the value
              endKey = prefix & "\xFF"
            of bkGtEq:
              startKey = prefix & rangeCond.val
              endKey = prefix & "\xFF"
            of bkLt:
              startKey = prefix
              endKey = prefix & rangeCond.val
            of bkLtEq:
              startKey = prefix
              endKey = prefix & rangeCond.val & "\x01"
            else:
              startKey = prefix; endKey = prefix
            let scanned = ctx.btrees[idxName].scan(startKey, endKey)
            var rows: seq[Row] = @[]
            for (k, entries) in scanned:
              for entry in entries:
                let (found, val) = ctx.db.get(entry.lsmKey)
                if found:
                  rows.add(parseRowDataToValueRow(cast[string](val)))
            let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
            var cols: seq[string] = @[]
            for c in tbl.columns: cols.add(c.name)
            if cols.len == 0: cols = @["key", "value"]
            return okResult(rows, cols)
        if w.kind == nkBinOp and w.binOp == bkEq:
          if w.binLeft.kind == nkIdent and w.binRight.kind == nkStringLit:
            let colName = w.binLeft.identName
            let idxName = stmt.selFrom.fromTable & "." & colName
            if idxName in ctx.btrees:
              let entries = ctx.btrees[idxName].get(w.binRight.strVal)
              if entries.len > 0:
                # Check for covering index: SELECT list matches index column
                var isCovered = true
                var coveredCols: seq[string] = @[]
                for e in stmt.selResult:
                  if e.kind == nkIdent:
                    coveredCols.add(e.identName)
                    if e.identName != colName:
                      isCovered = false
                  elif e.kind != nkStar:
                    isCovered = false
                if isCovered and coveredCols.len > 0:
                  var rows: seq[Row] = @[]
                  for entry in entries:
                    var row = initTable[string, Value]()
                    row[colName] = w.binRight.strVal
                    rows.add(row)
                  return okResult(rows, coveredCols)
                # Fetch actual row data from LSM
                let rows = execPointRead(ctx, stmt.selFrom.fromTable, colName & "=" & w.binRight.strVal)
                let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
                var cols: seq[string] = @[]
                for c in tbl.columns: cols.add(c.name)
                if cols.len == 0: cols = @["key", "value"]
                return okResult(rows, cols)

        # B-Tree range scan for BETWEEN
        if w.kind == nkBetweenExpr:
          if w.betweenExpr.kind == nkIdent and w.betweenLow.kind == nkStringLit and w.betweenHigh.kind == nkStringLit:
            let colName = w.betweenExpr.identName
            let idxName = stmt.selFrom.fromTable & "." & colName
            if idxName in ctx.btrees:
              let scanned = ctx.btrees[idxName].scan(w.betweenLow.strVal, w.betweenHigh.strVal)
              var rows: seq[Row] = @[]
              for (k, entries) in scanned:
                for entry in entries:
                  let (found, val) = ctx.db.get(entry.lsmKey)
                  if found:
                    rows.add(parseRowDataToValueRow(cast[string](val)))
              let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
              var cols: seq[string] = @[]
              for c in tbl.columns: cols.add(c.name)
              if cols.len == 0: cols = @["key", "value"]
              return okResult(rows, cols)

        # B-Tree range scan for > >= < <=
        if w.kind == nkBinOp and w.binLeft.kind == nkIdent and w.binRight.kind == nkStringLit:
          let colName = w.binLeft.identName
          let idxName = stmt.selFrom.fromTable & "." & colName
          if idxName in ctx.btrees:
            var startKey = ""
            var endKey = ""
            case w.binOp
            of bkGt:
              startKey = w.binRight.strVal & "\x00"
              endKey = "\x7f"
            of bkGtEq:
              startKey = w.binRight.strVal
              endKey = "\x7f"
            of bkLt:
              startKey = ""
              endKey = w.binRight.strVal
            of bkLtEq:
              startKey = ""
              endKey = w.binRight.strVal
            else: discard
            if startKey != "" or endKey != "":
              let scanned = ctx.btrees[idxName].scan(startKey, endKey)
              var rows: seq[Row] = @[]
              for (k, entries) in scanned:
                for entry in entries:
                  let (found, val) = ctx.db.get(entry.lsmKey)
                  if found:
                    rows.add(parseRowDataToValueRow(cast[string](val)))
              let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
              var cols: seq[string] = @[]
              for c in tbl.columns: cols.add(c.name)
              if cols.len == 0: cols = @["key", "value"]
              return okResult(rows, cols)

    # Full pipeline execution
    let plan = lowerSelect(stmt)
    let rows = executePlan(ctx, plan)
    var cols = getSelectColumns(stmt)
    # Expand star to table columns
    if "*" in cols:
      var expandedCols: seq[string] = @[]
      var seenColNames = initTable[string, bool]()
      let fromTable = if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom: stmt.selFrom.fromTable else: ""
      for c in cols:
        if c == "*":
          if fromTable.len > 0:
            let tbl = ctx.getTableDef(fromTable)
            for tc in tbl.columns:
              expandedCols.add(tc.name)
              seenColNames[tc.name] = true
          for j in stmt.selJoins:
            if j.kind == nkJoin and j.joinTarget != nil and j.joinTarget.kind == nkFrom:
              let joinTbl = ctx.getTableDef(j.joinTarget.fromTable)
              let alias = j.joinTarget.fromAlias
              for tc in joinTbl.columns:
                if tc.name in seenColNames:
                  if alias.len > 0:
                    expandedCols.add(alias & "." & tc.name)
                  else:
                    expandedCols.add(j.joinTarget.fromTable & "." & tc.name)
                else:
                  expandedCols.add(tc.name)
                  seenColNames[tc.name] = true
        else:
          expandedCols.add(c)
      cols = expandedCols
    if cols.len == 0:
      let tbl = ctx.getTableDef(if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom: stmt.selFrom.fromTable else: "")
      for c in tbl.columns: cols.add(c.name)
    if cols.len == 0 and rows.len > 0:
      for k, _ in rows[0]: cols.add(k)
    return okResult(rows, cols)

  of nkSetOp:
    # Execute left and right queries
    var innerLeft = Node(kind: nkStatementList, stmts: @[])
    innerLeft.stmts.add(stmt.setOpLeft)
    let leftRes = executeQueryImpl(ctx, innerLeft)

    var innerRight = Node(kind: nkStatementList, stmts: @[])
    innerRight.stmts.add(stmt.setOpRight)
    let rightRes = executeQueryImpl(ctx, innerRight)

    # Derive columns from left side
    var cols = leftRes.columns
    if cols.len == 0:
      cols = rightRes.columns

    var rows: seq[Row] = @[]
    case stmt.setOpKind
    of sdkUnion:
      rows = leftRes.rows
      if stmt.setOpAll:
        # UNION ALL: simple concatenation
        for row in rightRes.rows:
          rows.add(row)
      else:
        # UNION: deduplicate
        var seen: Table[string, bool]
        for row in leftRes.rows:
          seen[valueToString(row["$value"])] = true
        for row in rightRes.rows:
          if not seen.getOrDefault(valueToString(row["$value"]), false):
            seen[valueToString(row["$value"])] = true
            rows.add(row)

    of sdkIntersect:
      var leftSet: Table[string, bool]
      for row in leftRes.rows:
        leftSet[valueToString(row["$value"])] = true
      for row in rightRes.rows:
        if leftSet.getOrDefault(valueToString(row["$value"]), false):
          rows.add(row)
          if not stmt.setOpAll:
            leftSet.del(valueToString(row["$value"]))  # remove to prevent duplicates for INTERSECT (not ALL)

    of sdkExcept:
      var rightSet: Table[string, bool]
      for row in rightRes.rows:
        rightSet[valueToString(row["$value"])] = true
      for row in leftRes.rows:
        if not rightSet.getOrDefault(valueToString(row["$value"]), false):
          rows.add(row)

    return okResult(rows, cols)

  of nkInsert:
    var fields: seq[string] = @[]
    for f in stmt.insFields:
      if f.kind == nkIdent: fields.add(f.identName)
      else: fields.add("")

    var values: seq[seq[string]] = @[]
    for rowNode in stmt.insValues:
      var row: seq[string] = @[]
      if rowNode.kind == nkArrayLit:
        for v in rowNode.arrayElems:
          if v.kind == nkStringLit: row.add(v.strVal)
          elif v.kind == nkIntLit: row.add($v.intVal)
          elif v.kind == nkFloatLit: row.add($v.floatVal)
          elif v.kind == nkBoolLit: row.add($v.boolVal)
          elif v.kind == nkNullLit: row.add("\\N")
          else: row.add(evalNodeToString(v))
      else:
        if rowNode.kind == nkStringLit: row.add(rowNode.strVal)
        elif rowNode.kind == nkIntLit: row.add($rowNode.intVal)
        elif rowNode.kind == nkFloatLit: row.add($rowNode.floatVal)
        elif rowNode.kind == nkBoolLit: row.add($rowNode.boolVal)
        elif rowNode.kind == nkNullLit: row.add("\\N")
        else: row.add(evalNodeToString(rowNode))
      values.add(row)

    if fields.len == 0:
      let tbl = ctx.getTableDef(stmt.insTarget)
      for col in tbl.columns: fields.add(col.name)

    let tbl = ctx.getTableDef(stmt.insTarget)

    # Auto-increment: populate missing auto-increment columns
    var mutableFields = fields
    var mutableValues = values
    for col in tbl.columns:
      if col.autoIncrement and col.name notin mutableFields:
        let counterKey = stmt.insTarget & "." & col.name
        var nextVal: int64 = 1
        acquire(ctx.sharedLock.lock)
        try:
          if counterKey in ctx.autoIncCounters:
            nextVal = ctx.autoIncCounters[counterKey]
          ctx.autoIncCounters[counterKey] = nextVal + int64(mutableValues.len)
        finally:
          release(ctx.sharedLock.lock)
        # Insert at position 0 so it becomes the primary storage key
        mutableFields.insert(col.name, 0)
        for i in 0..<mutableValues.len:
          mutableValues[i].insert($(nextVal + int64(i)), 0)
      elif col.autoIncrement and col.name in mutableFields:
        # User provided value — update counter to max
        let idx = mutableFields.find(col.name)
        if idx >= 0:
          for rowVals in mutableValues.mitems:
            if idx < rowVals.len:
              let providedVal = rowVals[idx]
              try:
                let intVal = parseInt(providedVal)
                let counterKey = stmt.insTarget & "." & col.name
                acquire(ctx.sharedLock.lock)
                try:
                  if counterKey notin ctx.autoIncCounters or intVal >= ctx.autoIncCounters[counterKey]:
                    ctx.autoIncCounters[counterKey] = intVal + 1
                finally:
                  release(ctx.sharedLock.lock)
              except CatchableError: discard

    applyDefaultValues(tbl, mutableFields, mutableValues)

    let (valid, errMsg) = validateConstraints(ctx, stmt.insTarget, mutableFields, mutableValues)
    if not valid: return errResult(errMsg)

    # Standalone UNIQUE index enforcement (same failure channel as
    # validateConstraints: errResult before any row is written)
    for rowVals in mutableValues:
      let uCol = violatesUniqueIndex(ctx, stmt.insTarget, mutableFields, rowVals)
      if uCol.len > 0:
        return errResult("UNIQUE constraint violated: duplicate value for unique index '" & uCol & "'")

    # Fire BEFORE INSERT triggers
    var row = initTable[string, Value]()
    if mutableValues.len > 0:
      for i, f in mutableFields:
        if i < mutableValues[0].len:
          row[f] = mutableValues[0][i]
    fireTriggers(ctx, stmt.insTarget, "before", "insert", row)

    var kvPairs: seq[(string, seq[byte])]
    let count = execInsert(ctx, stmt.insTarget, mutableFields, mutableValues, kvPairs)

    # Fire AFTER INSERT triggers
    fireTriggers(ctx, stmt.insTarget, "after", "insert", row)

    if ctx.onChange != nil:
      for i in 0..<count:
        ctx.onChange(ChangeEvent(table: stmt.insTarget, kind: ckInsert, key: "", data: ""))

    # RETURNING clause
    if stmt.insReturning.len > 0 and mutableValues.len > 0:
      var returnRows: seq[Row] = @[]
      var returnCols: seq[string] = @[]
      for retExpr in stmt.insReturning:
        if retExpr.kind == nkIdent:
          returnCols.add(retExpr.identName)
        elif retExpr.kind == nkStar:
          returnCols.add("*")
        elif retExpr.exprAlias.len > 0:
          returnCols.add(retExpr.exprAlias)
        else:
          returnCols.add("col" & $returnCols.len)
      for rowVals in mutableValues:
        var rowMap = initTable[string, Value]()
        for i, f in mutableFields:
          if i < rowVals.len:
            rowMap[f] = rowVals[i]
        var returnRow = initTable[string, Value]()
        for i, retExpr in stmt.insReturning:
          let ir = lowerExpr(retExpr)
          let val = evalExpr(ir, rowMap, ctx)
          if returnCols[i] == "*":
            for k, v in rowMap:
              returnRow[k] = v
          else:
            returnRow[returnCols[i]] = val
        returnRows.add(returnRow)
      if returnCols.contains("*"):
        var expandedCols: seq[string] = @[]
        for c in tbl.columns: expandedCols.add(c.name)
        return okResult(returnRows, expandedCols, affected=count)
      return okResult(returnRows, returnCols, affected=count)

    return okResult(affected=count, kvPairs=kvPairs)

  of nkUpdate:
    if stmt.updSet.len == 0: return okResult()
    # Simple UPDATE: scan table, filter by WHERE, apply SET
    # Scan and apply
    let rows = execScan(ctx, stmt.updTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]
    for row in rows:
      # Compute sets for this row (expressions may reference columns)
      var sets = initTable[string, string]()
      for s in stmt.updSet:
        if s.kind == nkBinOp and s.binOp == bkAssign:
          if s.binLeft.kind == nkIdent:
            let val = if s.binRight.kind == nkStringLit: s.binRight.strVal
                      elif s.binRight.kind == nkIntLit: $s.binRight.intVal
                      elif s.binRight.kind == nkFloatLit: $s.binRight.floatVal
                      elif s.binRight.kind == nkBoolLit: $s.binRight.boolVal
                      elif s.binRight.kind == nkNullLit: "\\N"
                      else: valueToString(evalExpr(lowerExpr(s.binRight), row, ctx))
            sets[s.binLeft.identName] = val
      # Check WHERE
      if stmt.updWhere != nil and stmt.updWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.updWhere.whereExpr)
        if valueToString(evalExpr(whereExpr, row, ctx)) != "true": continue
      # Get key from row
      if "$key" in row:
        let old = valueToString(row["$key"])
        # Build updated row for constraint validation
        var updFields: seq[string] = @[]
        var updValues: seq[string] = @[]
        for col in ctx.getTableDef(stmt.updTarget).columns:
          updFields.add(col.name)
          if col.name in sets:
            updValues.add(sets[col.name])
          elif col.name in row:
            updValues.add(valueToString(row[col.name]))
          else:
            updValues.add("\\N")
        let (valid, errMsg) = validateConstraints(ctx, stmt.updTarget, updFields, @[updValues], skipPkCheck = true)
        if not valid: return errResult(errMsg)
        # Standalone UNIQUE index enforcement — exclude this row's own entry
        let uCol = violatesUniqueIndex(ctx, stmt.updTarget, updFields, updValues,
                                       excludeLsmKey = stmt.updTarget & "." & old)
        if uCol.len > 0:
          return errResult("UNIQUE constraint violated: duplicate value for unique index '" & uCol & "'")
        # FK ON UPDATE enforcement (parent side)
        var refCols: seq[string] = @[]
        for _, childTbl in ctx.tables:
          for col in childTbl.columns:
            if col.fkTable == stmt.updTarget and col.fkColumn notin refCols:
              refCols.add(col.fkColumn)
        for refCol in refCols:
          if refCol in sets and refCol in row:
            let (fkOk, fkErr) = enforceFkOnUpdate(ctx, stmt.updTarget, refCol, valueToString(row[refCol]), sets[refCol])
            if not fkOk:
              return errResult(fkErr)
        # FK ON UPDATE enforcement (child side — validate new FK values)
        for colName, newVal in sets:
          let (fkOk, fkErr) = enforceFkOnChildUpdate(ctx, stmt.updTarget, colName, newVal)
          if not fkOk:
            return errResult(fkErr)
        # Fire BEFORE UPDATE triggers
        var oldRow = row
        var newRow = row
        for col, val in sets:
          newRow[col] = Value(kind: vkString, strVal: val)
        fireTriggers(ctx, stmt.updTarget, "before", "update", oldRow)

        count += execUpdateRow(ctx, stmt.updTarget, valueToString(row["$key"]), sets, kvPairs)

        # Fire AFTER UPDATE triggers
        fireTriggers(ctx, stmt.updTarget, "after", "update", newRow)

        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.updTarget, kind: ckUpdate, key: old, data: ""))
    return okResult(affected=count, kvPairs=kvPairs)

  of nkDelete:
    # Delete all rows matching WHERE
    let rows = execScan(ctx, stmt.delTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]
    for row in rows:
      if stmt.delWhere != nil and stmt.delWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.delWhere.whereExpr)
        if valueToString(evalExpr(whereExpr, row, ctx)) != "true": continue
      if "$key" in row:
        let old = valueToString(row["$key"])
        # Fire BEFORE DELETE triggers
        fireTriggers(ctx, stmt.delTarget, "before", "delete", row)

        # FK ON DELETE enforcement
        var refCols: seq[string] = @[]
        for _, childTbl in ctx.tables:
          for col in childTbl.columns:
            if col.fkTable == stmt.delTarget and col.fkColumn notin refCols:
              refCols.add(col.fkColumn)
        for refCol in refCols:
          if refCol in row:
            let (fkOk, fkErr) = enforceFkOnDelete(ctx, stmt.delTarget, refCol, valueToString(row[refCol]))
            if not fkOk:
              return errResult(fkErr)

        count += execDelete(ctx, stmt.delTarget, valueToString(row["$key"]), kvPairs)

        # Fire AFTER DELETE triggers
        fireTriggers(ctx, stmt.delTarget, "after", "delete", row)

        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.delTarget, kind: ckDelete, key: old, data: ""))
    return okResult(affected=count, kvPairs=kvPairs)

  of nkMerge:
    # Execute source: subquery or table scan
    var sourceRows: seq[Row] = @[]
    if stmt.mergeSource != nil:
      if stmt.mergeSource.kind == nkSelect:
        let srcRes = executeQueryImpl(ctx, Node(kind: nkStatementList, stmts: @[stmt.mergeSource]))
        sourceRows = srcRes.rows
      elif stmt.mergeSource.kind == nkIdent:
        sourceRows = execScan(ctx, stmt.mergeSource.identName)

    let targetRows = execScan(ctx, stmt.mergeTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]

    for srcRow in sourceRows:
      var matched = false
      var combinedRow = srcRow
      for k, v in srcRow:
        combinedRow[stmt.mergeSourceAlias & "." & k] = v
      for tgtRow in targetRows:
        # Evaluate ON condition with both source and target rows visible
        var rowWithTarget = combinedRow
        for k, v in tgtRow:
          rowWithTarget[stmt.mergeTargetAlias & "." & k] = v
        let onExpr = lowerExpr(stmt.mergeOn)
        if valueToString(evalExpr(onExpr, rowWithTarget, ctx)) == "true":
          matched = true
          if stmt.mergeMatchedUpdate.len > 0 and "$key" in tgtRow:
            var updateSets = initTable[string, string]()
            for s in stmt.mergeMatchedUpdate:
              if s.kind == nkBinOp and s.binOp == bkAssign:
                if s.binLeft.kind == nkIdent:
                  let valExpr = lowerExpr(s.binRight)
                  updateSets[s.binLeft.identName] = valueToString(evalExpr(valExpr, rowWithTarget, ctx))
            var newRow = tgtRow
            for col, val in updateSets:
              newRow[col] = Value(kind: vkString, strVal: val)
            fireTriggers(ctx, stmt.mergeTarget, "before", "update", tgtRow)
            count += execUpdateRow(ctx, stmt.mergeTarget, valueToString(tgtRow["$key"]), updateSets, kvPairs)
            fireTriggers(ctx, stmt.mergeTarget, "after", "update", newRow)
            if ctx.onChange != nil:
              ctx.onChange(ChangeEvent(table: stmt.mergeTarget, kind: ckUpdate, key: valueToString(tgtRow["$key"]), data: ""))
          break

      if not matched and stmt.mergeNotMatchedInsert.len > 0:
        var fields: seq[string] = @[]
        var values: seq[string] = @[]
        for i, colNode in stmt.mergeNotMatchedInsert:
          if colNode.kind == nkIdent:
            fields.add(colNode.identName)
            if i < stmt.mergeNotMatchedValues.len:
              let v = stmt.mergeNotMatchedValues[i]
              let valExpr = lowerExpr(v)
              values.add(valueToString(evalExpr(valExpr, combinedRow, ctx)))
            else:
              values.add("\\N")
        if fields.len > 0:
          var row = initTable[string, Value]()
          for i, f in fields:
            if i < values.len: row[f] = Value(kind: vkString, strVal: values[i])
          fireTriggers(ctx, stmt.mergeTarget, "before", "insert", row)
          var insKvPairs: seq[(string, seq[byte])]
          count += execInsert(ctx, stmt.mergeTarget, fields, @[values], insKvPairs)
          for kv in insKvPairs: kvPairs.add(kv)
          fireTriggers(ctx, stmt.mergeTarget, "after", "insert", row)
          if ctx.onChange != nil:
            ctx.onChange(ChangeEvent(table: stmt.mergeTarget, kind: ckInsert, key: "", data: ""))

    return okResult(affected=count, kvPairs=kvPairs)

  of nkCreateTable:
    var tbl = TableDef(name: stmt.crtName, columns: @[], pkColumns: @[],
                       foreignKeys: @[], checks: @[])
    # First pass: collect table-level constraints
    for cstNode in stmt.crtConstraints:
      if cstNode.kind == nkConstraintDef:
        if cstNode.cstType == "pkey":
          for c in cstNode.cstColumns: tbl.pkColumns.add(c)
          for i, c in tbl.columns:
            if c.name in cstNode.cstColumns:
              tbl.columns[i].isPk = true
              ctx.btrees[stmt.crtName & "." & c.name] = newBTreeIndex[string, IndexEntry]()
        elif cstNode.cstType == "fkey":
          tbl.foreignKeys.add(ForeignKeyDef(
            refTable: cstNode.cstRefTable,
            refColumn: if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: "",
            onDelete: cstNode.cstOnDelete,
            onUpdate: cstNode.cstOnUpdate))
          if cstNode.cstColumns.len > 0:
            for i, c in tbl.columns:
              if c.name in cstNode.cstColumns:
                tbl.columns[i].fkTable = cstNode.cstRefTable
                tbl.columns[i].fkColumn = if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: ""
                tbl.columns[i].fkOnDelete = cstNode.cstOnDelete
                tbl.columns[i].fkOnUpdate = cstNode.cstOnUpdate
        elif cstNode.cstType == "check":
          tbl.checks.add(CheckDef(name: "check_" & $tbl.checks.len, checkNode: cstNode.cstCheck))

    # Second pass: column definitions
    for col in stmt.crtColumns:
      if col.kind == nkColumnDef:
        var colDef = ColumnDef(name: col.cdName, colType: col.cdType)
        colDef.autoIncrement = col.cdAutoIncrement
        for cst in col.cdConstraints:
          if cst.kind == nkConstraintDef:
            case cst.cstType
            of "pkey":
              colDef.isPk = true
              if col.cdName notin tbl.pkColumns: tbl.pkColumns.add(col.cdName)
              ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
            of "notnull": colDef.isNotNull = true
            of "unique":
              colDef.isUnique = true
              ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
            of "default":
              if cst.cstDefault != nil:
                if cst.cstDefault.kind == nkStringLit: colDef.defaultVal = cst.cstDefault.strVal
                elif cst.cstDefault.kind == nkIntLit: colDef.defaultVal = $cst.cstDefault.intVal
                elif cst.cstDefault.kind == nkBoolLit: colDef.defaultVal = $cst.cstDefault.boolVal
                elif cst.cstDefault.kind == nkFloatLit: colDef.defaultVal = $cst.cstDefault.floatVal
            of "fkey":
              colDef.fkTable = cst.cstRefTable
              colDef.fkColumn = if cst.cstRefColumns.len > 0: cst.cstRefColumns[0] else: ""
              colDef.fkOnDelete = cst.cstOnDelete
              colDef.fkOnUpdate = cst.cstOnUpdate
            of "check":
              tbl.checks.add(CheckDef(name: "check_" & col.cdName, checkNode: cst.cstCheck))
            else: discard
        tbl.columns.add(colDef)
    # Third pass: apply table-level constraints to columns
    for cstNode in stmt.crtConstraints:
      if cstNode.kind == nkConstraintDef:
        if cstNode.cstType == "pkey":
          for i, c in tbl.columns:
            if c.name in cstNode.cstColumns:
              tbl.columns[i].isPk = true
        elif cstNode.cstType == "fkey":
          if cstNode.cstColumns.len > 0:
            for i, c in tbl.columns:
              if c.name in cstNode.cstColumns:
                tbl.columns[i].fkTable = cstNode.cstRefTable
                tbl.columns[i].fkColumn = if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: ""
                tbl.columns[i].fkOnDelete = cstNode.cstOnDelete
                tbl.columns[i].fkOnUpdate = cstNode.cstOnUpdate
    ctx.tables[stmt.crtName] = tbl
    persistTableSchema(ctx, tbl)
    return okResult()

  of nkDropTable:
    let dropName = stmt.drtName
    ctx.tables.del(dropName)
    var toDelete: seq[string] = @[]
    for idxName in ctx.btrees.keys.toSeq():
      if idxName.startsWith(dropName & "."): toDelete.add(idxName)
    for idxName in toDelete:
      ctx.btrees.del(idxName)
      ctx.uniqueIndexes.excl(idxName)
    # Drop FTS/HNSW engine indexes for this table (in-memory entries)
    var ftsToDelete: seq[string] = @[]
    for key in ctx.ftsIndexes.keys.toSeq():
      if key.startsWith(dropName & "."): ftsToDelete.add(key)
    for key in ftsToDelete: ctx.ftsIndexes.del(key)
    var vecToDelete: seq[string] = @[]
    for key in ctx.vectorIndexes.keys.toSeq():
      if key.startsWith(dropName & "."): vecToDelete.add(key)
    for key in vecToDelete: ctx.vectorIndexes.del(key)
    # Remove durable schema entry
    dropTableSchema(ctx, dropName)
    # Remove row data for this table
    var dataKeys: seq[string] = @[]
    let prefix = dropName & "."
    for (key, _) in ctx.db.scanAll():
      if key.startsWith(prefix):
        dataKeys.add(key)
    for key in dataKeys:
      ctx.db.delete(key)
    # Remove persisted FTS/HNSW/B-tree index schema keys for this table
    var engineKeys: seq[string] = @[]
    for (key, _) in ctx.db.scanAll():
      if key.startsWith(SchemaFtsIndexPrefix & prefix) or
         key.startsWith(SchemaVecIndexPrefix & prefix) or
         key.startsWith(SchemaBtreeIndexPrefix & prefix):
        engineKeys.add(key)
    for key in engineKeys:
      ctx.db.delete(key)
    # Drop orphan legacy schema keys that mentioned this table
    var legacyKeys: seq[string] = @[]
    for (key, value) in ctx.db.scanAll():
      if key.startsWith(SchemaLegacyCreatePrefix):
        let ddl = cast[string](value)
        if ddl.contains("CREATE TABLE " & dropName) or ddl.contains("CREATE TABLE \"" & dropName):
          legacyKeys.add(key)
    for key in legacyKeys:
      ctx.db.delete(key)
    return okResult()

  of nkCreateGraph:
    let name = stmt.cgName
    if name in ctx.graphs:
      if not stmt.cgIfNotExists:
        return errResult("Graph '" & name & "' already exists")
      return okResult(msg="Graph '" & name & "' already exists")
    var g = gengine.newGraph()
    ctx.graphs[name] = g
    var createNodesSql = "CREATE TABLE " & name & "_nodes (id INTEGER PRIMARY KEY, node_label TEXT, properties TEXT)"
    var createEdgesSql = "CREATE TABLE " & name & "_edges (source_id INTEGER, dest_id INTEGER, edge_label TEXT, weight REAL)"
    let nodesTokens = qlex.tokenize(createNodesSql)
    let nodesAst = qpar.parse(nodesTokens)
    let nodesRes = executeQueryImpl(ctx, nodesAst)
    if not nodesRes.success:
      ctx.graphs.del(name)
      return errResult("Failed to create graph nodes table: " & nodesRes.message)
    let edgesTokens = qlex.tokenize(createEdgesSql)
    let edgesAst = qpar.parse(edgesTokens)
    let edgesRes = executeQueryImpl(ctx, edgesAst)
    if not edgesRes.success:
      ctx.tables.del(name & "_nodes")
      ctx.graphs.del(name)
      return errResult("Failed to create graph edges table: " & edgesRes.message)
    # Persist a marker so restoreEngines can rebuild the Graph from the
    # backing tables after a restart. Written only on the success path.
    ctx.db.put(SchemaGraphsPrefix & name, cast[seq[byte]]("CREATE GRAPH " & name))
    return okResult(msg="CREATE GRAPH " & name)

  of nkDropGraph:
    let name = stmt.dgName
    if name notin ctx.graphs:
      if stmt.dgIfExists:
        return okResult()
      return errResult("Graph '" & name & "' does not exist")
    ctx.graphs.del(name)
    ctx.db.delete(SchemaGraphsPrefix & name)
    var dropNodesSql = "DROP TABLE " & name & "_nodes"
    var dropEdgesSql = "DROP TABLE " & name & "_edges"
    let nodesTokens = qlex.tokenize(dropNodesSql)
    let nodesAst = qpar.parse(nodesTokens)
    discard executeQueryImpl(ctx, nodesAst)
    let edgesTokens = qlex.tokenize(dropEdgesSql)
    let edgesAst = qpar.parse(edgesTokens)
    discard executeQueryImpl(ctx, edgesAst)
    return okResult(msg="DROP GRAPH " & name)

  of nkBeginTxn:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.commit(ctx.pendingTxn)
    ctx.pendingTxn = ctx.txnManager.beginTxn(ilReadCommitted)
    return okResult(msg="Transaction started")

  of nkCommitTxn:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      var kvPairs: seq[(string, seq[byte])]
      for key, version in ctx.pendingTxn.writeSet:
        if version.isDelete:
          ctx.db.delete(key)
        else:
          ctx.db.put(key, version.value)
        kvPairs.add((key, version.value))
      discard ctx.txnManager.commit(ctx.pendingTxn)
      ctx.pendingTxn = nil
      return okResult(msg="Transaction committed", kvPairs=kvPairs)
    return errResult("No active transaction to commit")

  of nkRollbackTxn:
    if ctx.pendingTxn != nil:
      discard ctx.txnManager.abortTxn(ctx.pendingTxn)
      ctx.pendingTxn = nil
      return okResult(msg="Transaction rolled back")
    return errResult("No active transaction to rollback")

  of nkCreateType:
    return okResult()

  of nkExplainStmt:
    if stmt.expStmt != nil and stmt.expStmt.kind == nkSelect:
      var planStr = "EXPLAIN "
      if stmt.expStmt.selFrom != nil and stmt.expStmt.selFrom.kind == nkFrom:
        planStr &= "SELECT on " & stmt.expStmt.selFrom.fromTable
      var indexUsed = false
      if stmt.expStmt.selFrom != nil and stmt.expStmt.selFrom.kind == nkFrom and stmt.expStmt.selFrom.fromTable.len > 0:
        if stmt.expStmt.selWhere != nil and stmt.expStmt.selWhere.whereExpr != nil:
          let w = stmt.expStmt.selWhere.whereExpr
          if w.kind == nkBinOp and w.binOp == bkEq:
            if w.binLeft.kind == nkIdent:
              let idxName = stmt.expStmt.selFrom.fromTable & "." & w.binLeft.identName
              if idxName in ctx.btrees:
                planStr &= " (using B-Tree index on " & w.binLeft.identName & ")"
                indexUsed = true
      if not indexUsed: planStr &= " (full table scan)"
      return okResult(msg=planStr)
    return okResult(msg="EXPLAIN")

  of nkAlterTable:
    if stmt.altName in ctx.tables:
      var tbl = ctx.tables[stmt.altName]
      for op in stmt.altOps:
        if op.kind == nkColumnDef:
          var colDef = ColumnDef(name: op.cdName, colType: op.cdType)
          tbl.columns.add(colDef)
      ctx.tables[stmt.altName] = tbl
      persistTableSchema(ctx, tbl)
      return okResult(msg="ALTER TABLE " & stmt.altName & " executed")
    return errResult("Table '" & stmt.altName & "' does not exist")

  of nkRecoverToTimestamp:
    let walPath = ctx.db.dir & "/wal.log"
    let entries = readEntries(walPath)
    var applied = 0
    for entry in entries:
      if entry.kind == wekPut:
        ctx.db.put(cast[string](entry.key), entry.value)
        inc applied
      elif entry.kind == wekDelete:
        ctx.db.delete(cast[string](entry.key))
        inc applied
    ctx.restoreSchema()
    return okResult(msg="RECOVERED " & $applied & " entries from WAL")

  of nkCreateView:
    ctx.views[stmt.cvName] = stmt.cvQuery
    let viewKey = "_schema:views:" & stmt.cvName
    let viewSql = selectToSql(stmt.cvQuery)
    let viewDdl = "CREATE VIEW \"" & sqlEscapeIdent(stmt.cvName) & "\" AS " & viewSql
    ctx.db.put(viewKey, cast[seq[byte]](viewDdl))
    return okResult(msg="CREATE VIEW " & stmt.cvName)

  of nkDropView:
    if stmt.dvName in ctx.views:
      ctx.views.del(stmt.dvName)
    let viewKey = "_schema:views:" & stmt.dvName
    ctx.db.delete(viewKey)
    return okResult(msg="DROP VIEW " & stmt.dvName)

  of nkCreateTrigger:
    let tbl = ctx.getTableDef(stmt.trigTable)
    var triggers = tbl.triggers
    triggers.add(TriggerDef(
      name: stmt.trigName,
      timing: stmt.trigTiming,
      event: stmt.trigEvent,
      action: stmt.trigAction,
    ))
    ctx.tables[stmt.trigTable].triggers = triggers
    # Persist trigger to LSM-Tree
    let trigKey = "_schema:triggers:" & stmt.trigTable & ":" & stmt.trigName
    let trigDdl = "CREATE TRIGGER \"" & sqlEscapeIdent(stmt.trigName) & "\" ON \"" & sqlEscapeIdent(stmt.trigTable) & "\" " &
                  stmt.trigTiming & " " & stmt.trigEvent & " AS " & stmt.trigAction.strVal
    ctx.db.put(trigKey, cast[seq[byte]](trigDdl))
    return okResult(msg="CREATE TRIGGER " & stmt.trigName)

  of nkDropTrigger:
    let tbl = ctx.getTableDef(stmt.trigTable)
    var newTriggers: seq[TriggerDef] = @[]
    for trig in tbl.triggers:
      if trig.name != stmt.trigDropName:
        newTriggers.add(trig)
    ctx.tables[stmt.trigTable].triggers = newTriggers
    let trigKey = "_schema:triggers:" & stmt.trigTable & ":" & stmt.trigDropName
    ctx.db.delete(trigKey)
    return okResult(msg="DROP TRIGGER " & stmt.trigDropName)

  of nkCreateMigration:
    let migKey = "_schema:migration:" & stmt.cmName
    let checksum = computeChecksum(stmt.cmBody)
    var storeBody = stmt.cmBody
    if stmt.cmDownBody.len > 0:
      storeBody = storeBody & "|DOWN|" & stmt.cmDownBody
    ctx.db.put(migKey, cast[seq[byte]](storeBody))
    var rec = getMigrationRecord(ctx, stmt.cmName)
    rec.checksum = checksum
    setMigrationRecord(ctx, rec)
    return okResult(msg="CREATE MIGRATION " & stmt.cmName & " (checksum: " & checksum[0..<16] & ")")

  of nkApplyMigration:
    if not acquireMigrationLock(ctx):
      return errResult("Migration already in progress (lock held)")
    defer: releaseMigrationLock(ctx)

    if isMigrationApplied(ctx, stmt.amName):
      return okResult(msg="Migration '" & stmt.amName & "' already applied")

    let (found, upBody, _) = getMigrationBody(ctx, stmt.amName)
    if not found:
      return errResult("Migration '" & stmt.amName & "' not found")

    let storedRec = getMigrationRecord(ctx, stmt.amName)
    let expectedChecksum = computeChecksum(upBody)
    if storedRec.checksum.len > 0 and storedRec.checksum != expectedChecksum:
      return errResult("Migration '" & stmt.amName & "' checksum mismatch! Stored: " &
                       storedRec.checksum[0..<16] & ", Expected: " & expectedChecksum[0..<16])

    let startTime = epochTime()
    let res = executeMigrationSql(ctx, upBody)
    let durationMs = int((epochTime() - startTime) * 1000)

    if not res.success:
      return errResult("Migration '" & stmt.amName & "' failed: " & res.message)

    ctx.db.put(migrationAppliedKey(stmt.amName), cast[seq[byte]]("applied"))
    setMigrationRecord(ctx, MigrationRecord(
      name: stmt.amName,
      checksum: expectedChecksum,
      appliedAt: int64(epochTime()),
      appliedBy: ctx.currentUser,
      durationMs: durationMs,
      rolledBack: false
    ))
    return okResult(msg="APPLY MIGRATION " & stmt.amName & " in " & $durationMs & "ms")

  of nkMigrationStatus:
    var rows: seq[Row] = @[]
    var cols = @["name", "status", "applied_at", "applied_by", "duration_ms", "checksum"]
    for name in listMigrations(ctx):
      let applied = isMigrationApplied(ctx, name)
      let rec = getMigrationRecord(ctx, name)
      var row = initTable[string, Value]()
      row["name"] = name
      row["status"] = if applied: "applied" else: "pending"
      row["applied_at"] = if rec.appliedAt > 0: $rec.appliedAt else: ""
      row["applied_by"] = rec.appliedBy
      row["duration_ms"] = $rec.durationMs
      row["checksum"] = if rec.checksum.len > 0: rec.checksum[0..<16] else: ""
      rows.add(row)
    return okResult(rows, cols, 0, "Migration status")

  of nkMigrationUp:
    if not acquireMigrationLock(ctx):
      return errResult("Migration already in progress (lock held)")
    defer: releaseMigrationLock(ctx)

    var pending: seq[string] = @[]
    for name in listMigrations(ctx):
      if not isMigrationApplied(ctx, name):
        pending.add(name)

    if pending.len == 0:
      return okResult(msg="No pending migrations")

    var toApply = pending
    if stmt.muCount > 0:
      toApply = pending[0 ..< min(stmt.muCount, pending.len)]

    var appliedCount = 0
    var totalDuration = 0
    for name in toApply:
      let (found, upBody, _) = getMigrationBody(ctx, name)
      if not found:
        return errResult("Migration '" & name & "' not found during batch apply")
      let startTime = epochTime()
      let res = executeMigrationSql(ctx, upBody)
      let durationMs = int((epochTime() - startTime) * 1000)
      if not res.success:
        return errResult("Migration '" & name & "' failed: " & res.message &
                         " (" & $appliedCount & " migrations applied before failure)")
      ctx.db.put(migrationAppliedKey(name), cast[seq[byte]]("applied"))
      setMigrationRecord(ctx, MigrationRecord(
        name: name,
        checksum: computeChecksum(upBody),
        appliedAt: int64(epochTime()),
        appliedBy: ctx.currentUser,
        durationMs: durationMs,
        rolledBack: false
      ))
      appliedCount.inc
      totalDuration += durationMs

    return okResult(msg="Applied " & $appliedCount & " migrations in " & $totalDuration & "ms")

  of nkMigrationDown:
    if not acquireMigrationLock(ctx):
      return errResult("Migration already in progress (lock held)")
    defer: releaseMigrationLock(ctx)

    var applied: seq[string] = @[]
    for name in listMigrations(ctx):
      if isMigrationApplied(ctx, name):
        applied.add(name)

    if applied.len == 0:
      return okResult(msg="No applied migrations to rollback")

    var toRollback = applied.reversed()
    let rollbackCount = if stmt.mdCount > 0: stmt.mdCount else: 1
    toRollback = toRollback[0 ..< min(rollbackCount, toRollback.len)]

    var rolledBackCount = 0
    for name in toRollback:
      let (found, _, downBody) = getMigrationBody(ctx, name)
      if not found:
        return errResult("Migration '" & name & "' not found during rollback")
      if downBody.len == 0:
        return errResult("Migration '" & name & "' has no DOWN script")
      let res = executeMigrationSql(ctx, downBody)
      if not res.success:
        return errResult("Rollback of '" & name & "' failed: " & res.message)
      ctx.db.delete(migrationAppliedKey(name))
      var rec = getMigrationRecord(ctx, name)
      rec.rolledBack = true
      setMigrationRecord(ctx, rec)
      rolledBackCount.inc

    return okResult(msg="Rolled back " & $rolledBackCount & " migrations")

  of nkImportFrom:
    let path = stmt.impPath
    let table = stmt.impTable
    let format = stmt.impFormat
    if not fileExists(path):
      return errResult("File not found: " & path)
    let content = readFile(path)
    var columns: seq[string] = @[]
    var rows: seq[seq[string]] = @[]
    case format
    of "csv":
      (columns, rows) = parseCsvTable(content, stmt.impDelimiter, stmt.impHasHeader)
    of "json":
      (columns, rows) = parseJsonTable(content)
    of "ndjson":
      (columns, rows) = parseNdjsonTable(content)
    else:
      return errResult("Unsupported import format: " & format)
    if columns.len == 0:
      return errResult("No columns found in import file")
    var inserted = 0
    let batchSize = stmt.impBatchSize
    var batchRows: seq[seq[string]] = @[]
    for row in rows:
      batchRows.add(row)
      if batchRows.len >= batchSize:
        # Generate INSERT INTO t (c1,c2) VALUES (...),(...) and execute
        let sql = buildInsertSql(table, columns, batchRows)
        let tokens = qlex.tokenize(sql)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          let insResult = executeQueryImpl(ctx, astNode)
          if insResult.success:
            inserted += batchRows.len
        batchRows.setLen(0)
    if batchRows.len > 0:
      let sql = buildInsertSql(table, columns, batchRows)
      let tokens = qlex.tokenize(sql)
      let astNode = qpar.parse(tokens)
      if astNode.stmts.len > 0:
        let insResult = executeQueryImpl(ctx, astNode)
        if insResult.success:
          inserted += batchRows.len
    return okResult(msg="IMPORTED " & $inserted & " rows into " & table)

  of nkExportTo:
    let path = stmt.expPath
    let table = stmt.expTable
    let format = stmt.expFormat
    var rows: seq[Row] = @[]
    var cols: seq[string] = @[]
    let scanResult = execScan(ctx, table)
    if scanResult.len == 0:
      let tbl = ctx.getTableDef(table)
      if tbl.columns.len == 0:
        return errResult("Table not found: " & table)
      for col in tbl.columns:
        cols.add(col.name)
    else:
      for k, v in scanResult[0].pairs:
        cols.add(k)
      rows = scanResult
    var content = ""
    var strRows: seq[seq[string]] = @[]
    for row in rows:
      var strRow: seq[string] = @[]
      for col in cols:
        strRow.add(if col in row: valueToString(row[col]) else: "")
      strRows.add(strRow)
    case format
    of "csv":
      content = toCsv(cols, strRows, stmt.expDelimiter, stmt.expIncludeHeader)
    of "json":
      content = toJson(cols, strRows)
    of "ndjson":
      content = toNdjson(cols, strRows)
    else:
      return errResult("Unsupported export format: " & format)
    writeFile(path, content)
    return okResult(msg="EXPORTED " & $strRows.len & " rows to " & path)

  of nkMigrationDryRun:
    let (found, upBody, downBody) = getMigrationBody(ctx, stmt.mdrName)
    if not found:
      return errResult("Migration '" & stmt.mdrName & "' not found")
    let tokens = qlex.tokenize(upBody)
    let astNode = qpar.parse(tokens)
    var msg = "DRY RUN " & stmt.mdrName & ":\n"
    msg.add("  Statements: " & $astNode.stmts.len & "\n")
    for i, s in astNode.stmts:
      msg.add("  [" & $(i+1) & "] " & $s.kind & "\n")
    msg.add("  DOWN script: " & (if downBody.len > 0: "yes" else: "no") & "\n")
    msg.add("  Checksum: " & computeChecksum(upBody)[0..<16] & "\n")
    return okResult(msg=msg)

  of nkCreateIndex:
    var colKey = stmt.ciTarget
    for col in stmt.ciColumns:
      colKey = colKey & "." & col
    let idxName = if stmt.ciName.len > 0: stmt.ciName else: colKey

    if stmt.ciKind == ikFullText:
      # Full-text search index
      var ftsIdx = fts.newInvertedIndex()
      let rows = execScan(ctx, stmt.ciTarget)
      for row in rows:
        let lsmKey = if "$key" in row: valueToString(row["$key"]) else: ""
        let docKey = stmt.ciTarget & "." & lsmKey
        var docId: uint64 = 0
        for ch in docKey:
          docId = docId * 31 + uint64(ord(ch))
        for col in stmt.ciColumns:
          let text = if col in row: valueToString(row[col]) else: ""
          if text.len > 0:
            ftsIdx.addDocument(docId, text)
      ctx.ftsIndexes[colKey] = ftsIdx
      # Persist reconstructed DDL so restoreEngines can rebuild the index
      # from table data after a restart (replay re-writes the same key).
      # Unnamed indexes: the colKey fallback name is dotted ("docs.content")
      # and unparseable, so persist the nameless form — replay regenerates
      # the same colKey default.
      let ftsDdl = if stmt.ciName.len > 0:
          "CREATE INDEX " & idxName & " ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ") USING FTS"
        else:
          "CREATE INDEX ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ") USING FTS"
      ctx.db.put(SchemaFtsIndexPrefix & colKey, cast[seq[byte]](ftsDdl))
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING FTS")

    if stmt.ciKind == ikHNSW:
      # Vector HNSW index
      let rows = execScan(ctx, stmt.ciTarget)
      var dimensions = 0
      for row in rows:
        for col in stmt.ciColumns:
          if col in row:
            let vec = parseVectorString(valueToString(row[col]))
            if vec.len > 0:
              dimensions = vec.len
              break
        if dimensions > 0: break
      if dimensions == 0:
        dimensions = 128  # Default dimension
      var hnswIdx = vengine.newHNSWIndex(dimensions, m = 16, efConstruction = 200, metric = vengine.dmCosine)
      for row in rows:
        for col in stmt.ciColumns:
          if col in row:
            let vec = parseVectorString(valueToString(row[col]))
            if vec.len > 0:
              var meta = initTable[string, string]()
              if "$key" in row:
                meta["key"] = valueToString(row["$key"])
              for col, val in row:
                if col.len > 0 and col != "$key" and col != "$value":
                  meta[col] = valueToString(val)
              let fullKey = stmt.ciTarget & "." & valueToString(row["$key"])
              var docId: uint64 = 0
              for ch in fullKey:
                docId = docId * 31 + uint64(ord(ch))
              vengine.insert(hnswIdx, docId, vec, meta)
      ctx.vectorIndexes[colKey] = hnswIdx
      # Persist reconstructed DDL so restoreEngines can rebuild the index
      # from table data after a restart (replay re-writes the same key).
      # Unnamed indexes: persist the nameless form (see FTS branch above).
      let vecDdl = if stmt.ciName.len > 0:
          "CREATE INDEX " & idxName & " ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ") USING HNSW"
        else:
          "CREATE INDEX ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ") USING HNSW"
      ctx.db.put(SchemaVecIndexPrefix & colKey, cast[seq[byte]](vecDdl))
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING HNSW")

    ctx.btrees[colKey] = newBTreeIndex[string, IndexEntry]()
    # Populate index from existing data
    let rows = execScan(ctx, stmt.ciTarget)
    for row in rows:
      var colVals: seq[string] = @[]
      for col in stmt.ciColumns:
        if col in row:
          colVals.add(valueToString(row[col]))
        else:
          colVals.add("\\N")
      let idxVal = colVals.join("|")
      if idxVal.len > 0 and not isNull(idxVal):
        let lsmKey = if "$key" in row: stmt.ciTarget & "." & valueToString(row["$key"]) else: ""
        if stmt.ciUnique and ctx.btrees[colKey].contains(idxVal):
          # Duplicate data — abort without registering the index
          ctx.btrees.del(colKey)
          return errResult("UNIQUE constraint violated: duplicate value '" & idxVal &
                           "' for unique index '" & colKey & "'")
        ctx.btrees[colKey].insert(idxVal, IndexEntry(lsmKey: lsmKey, rowValue: ""))
    if stmt.ciUnique:
      ctx.uniqueIndexes.incl(colKey)
    # Persist reconstructed DDL so restoreEngines can rebuild the index
    # from table data after a restart (replay re-writes the same key).
    # Unnamed indexes: persist the nameless form (see FTS branch above).
    let uniqueKw = if stmt.ciUnique: "UNIQUE " else: ""
    let btreeDdl = if stmt.ciName.len > 0:
        "CREATE " & uniqueKw & "INDEX " & idxName & " ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ")"
      else:
        "CREATE " & uniqueKw & "INDEX ON " & stmt.ciTarget & " (" & stmt.ciColumns.join(", ") & ")"
    ctx.db.put(SchemaBtreeIndexPrefix & colKey, cast[seq[byte]](btreeDdl))
    return okResult(msg="CREATE " & uniqueKw & "INDEX " & idxName & " on " & stmt.ciTarget)

  of nkDropIndex:
    # Find and remove index by name from ctx.btrees
    var found = false
    var targetKey = ""
    for key, _ in ctx.btrees:
      # Index key format: table.col or table.col1.col2
      # Try matching by the full key or by the table.indexName convention
      if key == stmt.diName or key.endsWith("." & stmt.diName):
        targetKey = key
        found = true
        break
      # A custom index name only appears in the persisted DDL — match it
      # against the stored "CREATE [UNIQUE] INDEX <name> ON" text as well.
      let (hasDdl, ddl) = ctx.db.get(SchemaBtreeIndexPrefix & key)
      if hasDdl and (cast[string](ddl).startsWith("CREATE INDEX " & stmt.diName & " ON ") or
                     cast[string](ddl).startsWith("CREATE UNIQUE INDEX " & stmt.diName & " ON ")):
        targetKey = key
        found = true
        break
    if found:
      ctx.btrees.del(targetKey)
      ctx.uniqueIndexes.excl(targetKey)
      ctx.db.delete(SchemaBtreeIndexPrefix & targetKey)
      return okResult(msg="DROP INDEX " & stmt.diName)
    # FTS/HNSW engine indexes: in-memory maps are keyed by table.col, and a
    # custom index name only appears in the persisted DDL — match it against
    # the stored "CREATE INDEX <name> ON" text as well.
    var ftsKey = ""
    for key in ctx.ftsIndexes.keys.toSeq():
      if key == stmt.diName or key.endsWith("." & stmt.diName):
        ftsKey = key
        break
      let (hasDdl, ddl) = ctx.db.get(SchemaFtsIndexPrefix & key)
      if hasDdl and cast[string](ddl).startsWith("CREATE INDEX " & stmt.diName & " ON "):
        ftsKey = key
        break
    if ftsKey.len > 0:
      ctx.ftsIndexes.del(ftsKey)
      ctx.db.delete(SchemaFtsIndexPrefix & ftsKey)
      return okResult(msg="DROP INDEX " & stmt.diName)
    var vecKey = ""
    for key in ctx.vectorIndexes.keys.toSeq():
      if key == stmt.diName or key.endsWith("." & stmt.diName):
        vecKey = key
        break
      let (hasDdl, ddl) = ctx.db.get(SchemaVecIndexPrefix & key)
      if hasDdl and cast[string](ddl).startsWith("CREATE INDEX " & stmt.diName & " ON "):
        vecKey = key
        break
    if vecKey.len > 0:
      ctx.vectorIndexes.del(vecKey)
      ctx.db.delete(SchemaVecIndexPrefix & vecKey)
      return okResult(msg="DROP INDEX " & stmt.diName)
    else:
      # Also remove from schema storage
      let idxKey = "_schema:indexes:" & stmt.diName
      ctx.db.delete(idxKey)
      return okResult(msg="DROP INDEX " & stmt.diName)

  of nkCreateUser:
    ctx.users[stmt.cuName] = UserDef(name: stmt.cuName, passwordHash: stmt.cuPassword,
                                     isSuperuser: stmt.cuSuperuser, roles: @[])
    let userKey = "_schema:users:" & stmt.cuName
    let userDdl = "CREATE USER \"" & sqlEscapeIdent(stmt.cuName) & "\" WITH PASSWORD '" & sqlEscapeString(stmt.cuPassword) & "'" &
                  (if stmt.cuSuperuser: " SUPERUSER" else: " NOSUPERUSER")
    ctx.db.put(userKey, cast[seq[byte]](userDdl))
    return okResult(msg="CREATE USER " & stmt.cuName)

  of nkDropUser:
    if stmt.duName in ctx.users:
      ctx.users.del(stmt.duName)
    let userKey = "_schema:users:" & stmt.duName
    ctx.db.delete(userKey)
    return okResult(msg="DROP USER " & stmt.duName)

  of nkCreatePolicy:
    var pols = ctx.policies.getOrDefault(stmt.cpTable)
    pols.add(PolicyDef(name: stmt.cpName, tableName: stmt.cpTable,
                       command: stmt.cpCommand, usingExpr: stmt.cpUsing,
                       withCheckExpr: stmt.cpWithCheck))
    ctx.policies[stmt.cpTable] = pols
    let polKey = "_schema:policies:" & stmt.cpTable & ":" & stmt.cpName
    var polDdl = "CREATE POLICY \"" & sqlEscapeIdent(stmt.cpName) & "\" ON \"" & sqlEscapeIdent(stmt.cpTable) & "\""
    if stmt.cpCommand != "ALL":
      polDdl.add(" FOR " & stmt.cpCommand)
    if stmt.cpUsing != nil:
      polDdl.add(" USING (expr)")
    if stmt.cpWithCheck != nil:
      polDdl.add(" WITH CHECK (expr)")
    ctx.db.put(polKey, cast[seq[byte]](polDdl))
    return okResult(msg="CREATE POLICY " & stmt.cpName)

  of nkDropPolicy:
    if stmt.dpTable in ctx.policies:
      var newPols: seq[PolicyDef] = @[]
      for pol in ctx.policies[stmt.dpTable]:
        if pol.name != stmt.dpName:
          newPols.add(pol)
      ctx.policies[stmt.dpTable] = newPols
    let polKey = "_schema:policies:" & stmt.dpTable & ":" & stmt.dpName
    ctx.db.delete(polKey)
    return okResult(msg="DROP POLICY " & stmt.dpName)

  of nkEnableRLS:
    # Mark table as RLS-enabled by creating a sentinel key
    let rlsKey = "_schema:rls:" & stmt.erlsTable
    ctx.db.put(rlsKey, cast[seq[byte]]("enabled"))
    return okResult(msg="ENABLE ROW LEVEL SECURITY on " & stmt.erlsTable)

  of nkDisableRLS:
    let rlsKey = "_schema:rls:" & stmt.drlsTable
    ctx.db.delete(rlsKey)
    return okResult(msg="DISABLE ROW LEVEL SECURITY on " & stmt.drlsTable)

  of nkGrant:
    # Store grant in LSM-Tree for persistence
    let grantKey = "_schema:grants:" & stmt.grTable & ":" & stmt.grPrivilege & ":" & stmt.grGrantee
    ctx.db.put(grantKey, cast[seq[byte]]("granted"))
    return okResult(msg="GRANT " & stmt.grPrivilege & " ON " & stmt.grTable & " TO " & stmt.grGrantee)

  of nkRevoke:
    let grantKey = "_schema:grants:" & stmt.rvTable & ":" & stmt.rvPrivilege & ":" & stmt.rvGrantee
    ctx.db.delete(grantKey)
    return okResult(msg="REVOKE " & stmt.rvPrivilege & " ON " & stmt.rvTable & " FROM " & stmt.rvGrantee)

  of nkSetVar:
    ctx.sessionVars[stmt.svName] = stmt.svValue
    return okResult(msg="SET " & stmt.svName & " = " & stmt.svValue)

  of nkCreateDatabase:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    if not isValidDbName(stmt.cdDbName):
      return errResult("Invalid database name: " & stmt.cdDbName)
    if databaseExists(ctx.registry, stmt.cdDbName) and not stmt.cdIfNotExists:
      return errResult("Database already exists: " & stmt.cdDbName)
    if databaseExists(ctx.registry, stmt.cdDbName) and stmt.cdIfNotExists:
      return okResult(msg="CREATE DATABASE " & stmt.cdDbName)
    try:
      discard getOrCreateDatabase(ctx.registry, stmt.cdDbName)
      let dbKey = "_schema:databases:" & stmt.cdDbName
      ctx.db.put(dbKey, cast[seq[byte]]("created"))
      return okResult(msg="CREATE DATABASE " & stmt.cdDbName)
    except CatchableError as e:
      return errResult("CREATE DATABASE failed: " & e.msg)

  of nkDropDatabase:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    if stmt.ddDbName == "default":
      return errResult("Cannot drop the default database")
    try:
      let count = getConnectionCount(ctx.registry, stmt.ddDbName)
      if count > 0:
        return errResult("Cannot drop database '" & stmt.ddDbName &
                         "': " & $count & " active connections")
      let dbKey = "_schema:databases:" & stmt.ddDbName
      ctx.db.delete(dbKey)
      if dropDatabase(ctx.registry, stmt.ddDbName):
        return okResult(msg="DROP DATABASE " & stmt.ddDbName)
      elif stmt.ddIfExists:
        return okResult(msg="DROP DATABASE " & stmt.ddDbName)
      else:
        return errResult("Database not found: " & stmt.ddDbName)
    except CatchableError as e:
      return errResult("DROP DATABASE failed: " & e.msg)

  of nkUseDatabase:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    if ctx.pendingTxn != nil:
      return errResult("Cannot switch database inside a transaction. Commit or rollback first.")
    let info = getDatabaseInfo(ctx.registry, stmt.udDbName)
    if info == nil:
      return errResult("Database not found: " & stmt.udDbName)
    let targetCtx = cast[ExecutionContext](cast[pointer](info.ctx))
    let oldDb = ctx.currentDatabase
    ctx.db = info.db
    ctx.tables = targetCtx.tables
    ctx.btrees = targetCtx.btrees
    ctx.views = targetCtx.views
    ctx.ftsIndexes = targetCtx.ftsIndexes
    ctx.vectorIndexes = targetCtx.vectorIndexes
    ctx.users = targetCtx.users
    ctx.policies = targetCtx.policies
    ctx.graphs = targetCtx.graphs
    ctx.autoIncCounters = targetCtx.autoIncCounters
    ctx.sequences = targetCtx.sequences
    ctx.currentDatabase = stmt.udDbName
    decrementConnections(ctx.registry, oldDb)
    incrementConnections(ctx.registry, stmt.udDbName)
    return okResult(msg="Changed to database '" & stmt.udDbName & "'")

  of nkShowDatabases:
    if ctx.registry == nil:
      return errResult("Multi-database support not enabled")
    var rows: seq[Row] = @[]
    for dbName in listDatabases(ctx.registry):
      var row = initTable[string, Value]()
      row["name"] = dbName
      rows.add(row)
    return okResult(rows, @["name"])

  of nkShowTables:
    if stmt.stTableName.len == 0:
      # SHOW TABLES — list all tables
      var rows: seq[Row] = @[]
      for tableName in ctx.tables.keys:
        var row = initTable[string, Value]()
        row["name"] = tableName
        rows.add(row)
      return okResult(rows, @["name"])
    else:
      # SHOW COLUMNS FROM table — describe a specific table
      var rows: seq[Row] = @[]
      let tbl = ctx.getTableDef(stmt.stTableName)
      for col in tbl.columns:
        var row = initTable[string, Value]()
        row["column_name"] = col.name
        row["data_type"] = col.colType
        row["is_nullable"] = if col.isNotNull: "NO" else: "YES"
        row["is_primary_key"] = if col.isPk: "YES" else: "NO"
        if col.defaultVal.len > 0:
          row["column_default"] = col.defaultVal
        else:
          row["column_default"] = ""
        rows.add(row)
      return okResult(rows, @["column_name", "data_type", "is_nullable", "is_primary_key", "column_default"])

  else:
    return errResult("Unsupported statement type: " & $stmt.kind)


proc executeQuery*(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult =
  if astNode == nil or astNode.stmts.len == 0:
    return okResult()
  let stmt = astNode.stmts[0]
  if isDDL(stmt):
    acquire(ctx.sharedLock.lock)
    try:
      result = executeQueryImpl(ctx, astNode, params)
    finally:
      release(ctx.sharedLock.lock)
  else:
    result = executeQueryImpl(ctx, astNode, params)

proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult =
  let tokens = qlex.tokenize(sql)
  let astNode = qpar.parse(tokens)
  if astNode.stmts.len > 0:
    return executeQueryImpl(ctx, astNode)
  return okResult(msg="Empty migration body")

proc restoreEngines*(ctx: ExecutionContext) =
  ## Rebuild ephemeral engines (B-tree/FTS/HNSW indexes, graphs) from persisted
  ## schema keys after restoreSchema. Invoked via context.restoreEnginesHook
  ## at the end of newExecutionContext. Index replay re-persists the same
  ## key, so it is idempotent.
  var ddls: seq[string] = @[]
  for (key, value) in ctx.db.scanAll():
    if not key.startsWith(SchemaFtsIndexPrefix) and
       not key.startsWith(SchemaVecIndexPrefix) and
       not key.startsWith(SchemaBtreeIndexPrefix): continue
    let ddl = cast[string](value)
    if ddl.len == 0: continue
    ddls.add(ddl)
  for ddl in ddls:
    try:
      let res = executeQueryImpl(ctx, qpar.parse(qlex.tokenize(ddl)))
      if not res.success:
        warn("restoreEngines: replay failed for DDL '" & ddl & "': " & res.message)
    except CatchableError as e:
      warn("restoreEngines: replay raised for DDL '" & ddl & "': " & e.msg)

  # Graphs cannot be replayed via CREATE GRAPH (the backing tables already
  # exist after restart), so rebuild each Graph object from the rows of its
  # <name>_nodes / <name>_edges backing tables. Row mapping mirrors the
  # INSERT path in exec/dml.nim.
  var graphNames: seq[string] = @[]
  for (key, _) in ctx.db.scanAll():
    if key.startsWith(SchemaGraphsPrefix):
      let name = key[SchemaGraphsPrefix.len..^1]
      if name.len > 0: graphNames.add(name)
  for name in graphNames:
    if name in ctx.graphs: continue
    try:
      var g = gengine.newGraph()
      for row in execScan(ctx, name & "_nodes"):
        try:
          if "id" notin row: continue
          let idStr = valueToString(row["id"])
          if idStr.len == 0: continue
          let nid = gengine.NodeId(parseUInt(idStr))
          var label = ""
          var props = initTable[string, string]()
          for col, val in row:
            if col == "node_label":
              label = valueToString(val)
            elif col != "id" and col != "properties" and
                 col != "$key" and col != "$value":
              props[col] = valueToString(val)
          gengine.addNodeWithId(g, nid, label, props)
        except CatchableError:
          discard
      for row in execScan(ctx, name & "_edges"):
        try:
          if "source_id" notin row or "dest_id" notin row: continue
          let srcStr = valueToString(row["source_id"])
          let dstStr = valueToString(row["dest_id"])
          if srcStr.len == 0 or dstStr.len == 0: continue
          var label = ""
          var weight = 1.0
          if "edge_label" in row:
            label = valueToString(row["edge_label"])
          if "weight" in row:
            try: weight = parseFloat(valueToString(row["weight"]))
            except CatchableError: discard
          gengine.addEdgeWithId(g, gengine.NodeId(parseUInt(srcStr)),
                                gengine.NodeId(parseUInt(dstStr)), label, weight)
        except CatchableError:
          discard
      ctx.graphs[name] = g
    except CatchableError as e:
      warn("restoreEngines: graph rebuild failed for '" & name & "': " & e.msg)

# ----------------------------------------------------------------------
# Hook wiring — breaks the module cycle between executor and the exec/*
# submodules: eval.nim calls back into the engine for subqueries, hybrid
# search, and NL->SQL validation; triggers.nim executes trigger bodies.
# Wired once at module scope.
# ----------------------------------------------------------------------
eval.executePlanHook = plan_exec.executePlan
eval.execScanHook = scan.execScan
eval.executeQueryHook = executeQuery
context.restoreEnginesHook = restoreEngines

# triggers.nim back-edge: fireTriggers executes trigger action statements
# via the private dispatcher, so the lambda closes over executeQueryImpl.
triggers.executeQueryHook = (proc(ctx: ExecutionContext, astNode: Node): ExecResult = executeQueryImpl(ctx, astNode))
