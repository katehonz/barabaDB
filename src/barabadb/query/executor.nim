## BaraQL Executor — AST lowering, IR compilation, and execution
import std/strutils
import std/tables
import std/hashes
import std/sequtils
import std/algorithm
import std/re
import lexer as qlex
import parser as qpar
import ast
import ir
import ../core/types
import ../storage/lsm
import ../storage/btree
import ../core/mvcc

type
  IndexEntry* = ref object
    lsmKey*: string
    rowValue*: string

  ChangeKind* = enum
    ckInsert, ckUpdate, ckDelete

  ChangeEvent* = object
    table*: string
    kind*: ChangeKind
    key*: string
    data*: string

  ExecutionContext* = ref object
    db*: LSMTree
    tables*: Table[string, TableDef]
    btrees*: Table[string, BTreeIndex[string, IndexEntry]]
    views*: Table[string, Node]  # view name -> SELECT AST
    txnManager*: TxnManager
    pendingTxn*: Transaction
    onChange*: proc(ev: ChangeEvent) {.closure.}

  ForeignKeyDef* = object
    refTable*: string
    refColumn*: string
    onDelete*: string  # CASCADE, SET NULL, RESTRICT

  CheckDef* = object
    name*: string
    expr*: string  # stored expression string
    checkNode*: Node  # AST for runtime evaluation

  TableDef* = object
    name*: string
    columns*: seq[ColumnDef]
    pkColumns*: seq[string]
    foreignKeys*: seq[ForeignKeyDef]
    checks*: seq[CheckDef]

  ColumnDef* = object
    name*: string
    colType*: string
    isPk*: bool
    isNotNull*: bool
    isUnique*: bool
    defaultVal*: string
    fkTable*: string
    fkColumn*: string

  Row* = Table[string, string]

  ExecResult* = object
    success*: bool
    columns*: seq[string]
    rows*: seq[Row]
    affectedRows*: int
    message*: string

proc okResult*(rows: seq[Row] = @[], cols: seq[string] = @[], affected: int = 0, msg: string = ""): ExecResult =
  ExecResult(success: true, columns: cols, rows: rows, affectedRows: affected, message: msg)

proc errResult*(msg: string): ExecResult =
  ExecResult(success: false, columns: @[], rows: @[], affectedRows: 0, message: msg)

# ----------------------------------------------------------------------
# Context management
# ----------------------------------------------------------------------

proc restoreSchema(ctx: ExecutionContext)

proc newExecutionContext*(db: LSMTree): ExecutionContext =
  result = ExecutionContext(db: db, tables: initTable[string, TableDef](),
                   btrees: initTable[string, BTreeIndex[string, IndexEntry]](),
                   views: initTable[string, Node](),
                   onChange: nil)
  restoreSchema(result)

proc restoreSchema(ctx: ExecutionContext) =
  let prefix = "_schema:migrations:"
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if not entry.key.startsWith(prefix): continue
    let ddl = cast[string](entry.value)
    if ddl.len == 0: continue
    let tokens = qlex.tokenize(ddl)
    let astNode = qpar.parse(tokens)
    if astNode.stmts.len > 0:
      let stmt = astNode.stmts[0]
      case stmt.kind
      of nkCreateTable:
        var tbl = TableDef(name: stmt.crtName, columns: @[], pkColumns: @[],
                           foreignKeys: @[], checks: @[])
        for col in stmt.crtColumns:
          if col.kind == nkColumnDef:
            var colDef = ColumnDef(name: col.cdName, colType: col.cdType)
            for cst in col.cdConstraints:
              if cst.kind == nkConstraintDef:
                case cst.cstType
                of "pkey":
                  colDef.isPk = true
                  tbl.pkColumns.add(col.cdName)
                  ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
                of "notnull": colDef.isNotNull = true
                of "unique":
                  colDef.isUnique = true
                  ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
                else: discard
            tbl.columns.add(colDef)
        ctx.tables[stmt.crtName] = tbl
      of nkCreateView:
        ctx.views[stmt.cvName] = stmt.cvQuery
      else: discard

proc cloneForConnection*(ctx: ExecutionContext): ExecutionContext =
  ExecutionContext(db: ctx.db, tables: ctx.tables,
                   btrees: ctx.btrees, views: ctx.views,
                   txnManager: ctx.txnManager,
                   pendingTxn: nil, onChange: ctx.onChange)

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

proc getTableDef(ctx: ExecutionContext, tableName: string): TableDef =
  if tableName in ctx.tables: return ctx.tables[tableName]
  return TableDef(name: tableName, columns: @[], pkColumns: @[], foreignKeys: @[], checks: @[])

proc getValue(values: seq[string], fields: seq[string], colName: string): string =
  for i, f in fields:
    if f.toLower() == colName.toLower() and i < values.len:
      return values[i]
  return ""

proc isNull*(value: string): bool =
  value.len == 0 or value.toLower() == "null"

proc parseRowData(valStr: string): Table[string, string] =
  ## Parse "col1=val1,col2=val2" into a table
  result = initTable[string, string]()
  for part in valStr.split(","):
    let eqPos = part.find('=')
    if eqPos >= 0:
      let k = part[0..<eqPos].strip()
      let v = part[eqPos+1..^1].strip()
      result[k] = v

proc evalExpr(expr: IRExpr, row: Table[string, string]): string =
  if expr == nil: return ""
  case expr.kind
  of irekLiteral:
    case expr.literal.kind
    of vkString: return expr.literal.strVal
    of vkInt64: return $expr.literal.int64Val
    of vkFloat64: return $expr.literal.float64Val
    of vkBool: return $expr.literal.boolVal
    of vkNull: return ""
    else: return ""
  of irekField:
    if expr.fieldPath.len > 0:
      let colName = expr.fieldPath[^1]
      if colName in row: return row[colName]
      if "$key" in row and row["$key"].startsWith(colName & "="):
        return row["$key"][colName.len+1..^1]
      if "$value" in row:
        let parsed = parseRowData(row["$value"])
        if colName in parsed: return parsed[colName]
    return ""
  of irekBinary:
    let left = evalExpr(expr.binLeft, row)
    let right = evalExpr(expr.binRight, row)
    case expr.binOp
    of irEq:
      if left == right: return "true"
      # Try numeric comparison
      try:
        if parseFloat(left) == parseFloat(right): return "true"
      except: discard
      return "false"
    of irNeq: return if left != right: "true" else: "false"
    of irLt:
      try:
        return if parseFloat(left) < parseFloat(right): "true" else: "false"
      except: return if left < right: "true" else: "false"
    of irLte:
      try:
        return if parseFloat(left) <= parseFloat(right): "true" else: "false"
      except: return if left <= right: "true" else: "false"
    of irGt:
      try:
        return if parseFloat(left) > parseFloat(right): "true" else: "false"
      except: return if left > right: "true" else: "false"
    of irGte:
      try:
        return if parseFloat(left) >= parseFloat(right): "true" else: "false"
      except: return if left >= right: "true" else: "false"
    of irAnd:
      if left == "true" and right == "true": return "true"
      return "false"
    of irOr:
      if left == "true" or right == "true": return "true"
      return "false"
    of irAdd:
      try: return $(parseFloat(left) + parseFloat(right))
      except: return left & right
    of irSub:
      try: return $(parseFloat(left) - parseFloat(right))
      except: return "0"
    of irMul:
      try: return $(parseFloat(left) * parseFloat(right))
      except: return "0"
    of irDiv:
      try:
        let r = parseFloat(right)
        if r != 0: return $(parseFloat(left) / r)
        return "0"
      except: return "0"
    of irLike:
      let pattern = right.replace("%", ".*").replace("_", ".")
      try:
        let rePattern = re(pattern)
        if left.match(rePattern): return "true"
      except: discard
      return "false"
    else: return "false"
  of irekUnary:
    case expr.unOp
    of irNot:
      let v = evalExpr(expr.unExpr, row)
      return if v == "true": "false" else: "true"
    of irIsNull:
      let v = evalExpr(expr.unExpr, row)
      return if isNull(v): "true" else: "false"
    of irIsNotNull:
      let v = evalExpr(expr.unExpr, row)
      return if not isNull(v): "true" else: "false"
    else: return "false"
  of irekExists: return "false"
  else: return ""

# ----------------------------------------------------------------------
# Table scan and storage
# ----------------------------------------------------------------------

proc execScan(ctx: ExecutionContext, table: string): seq[Row] =
  result = @[]
  let prefix = table & "."
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if not entry.key.startsWith(prefix): continue
    let rest = entry.key[prefix.len..^1]
    var row: Table[string, string]
    row["$key"] = rest
    let valStr = cast[string](entry.value)
    row["$value"] = valStr
    # Also parse individual columns
    for k, v in parseRowData(valStr):
      row[k] = v
    # Extract PK value from key
    let eqPos = rest.find('=')
    if eqPos >= 0:
      row[rest[0..<eqPos]] = rest[eqPos+1..^1]
    result.add(row)

proc execPointRead(ctx: ExecutionContext, table: string, key: string): seq[Row] =
  let fullKey = table & "." & key
  let (found, val) = ctx.db.get(fullKey)
  if found:
    var row: Table[string, string]
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

proc execInsert*(ctx: ExecutionContext, table: string, fields: seq[string], values: seq[seq[string]]): int =
  var count = 0
  for rowVals in values:
    var key = ""
    var keyFound = false
    var valParts: seq[string] = @[]
    for i, f in fields:
      if i < rowVals.len:
        if not keyFound:
          key = f & "=" & rowVals[i]
          keyFound = true
        else:
          valParts.add(f & "=" & rowVals[i])
      elif f.len > 0:
        valParts.add(f & "=")
    let valStr = valParts.join(",")
    let fullKey = table & "." & key

    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](valStr))
    else:
      ctx.db.put(fullKey, cast[seq[byte]](valStr))

    for colName in ctx.btrees.keys.toSeq():
      if colName.startsWith(table & "."):
        let colOnly = colName[table.len + 1..^1]
        let colVal = getValue(rowVals, fields, colOnly)
        if colVal.len > 0 and not isNull(colVal):
          ctx.btrees[colName].insert(colVal, IndexEntry(lsmKey: fullKey, rowValue: valStr))

    inc count
  return count

proc execDelete*(ctx: ExecutionContext, table: string, key: string): int =
  let fullKey = table & "." & key
  let (found, _) = ctx.db.get(fullKey)
  if found:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.delete(ctx.pendingTxn, fullKey)
    else:
      ctx.db.delete(fullKey)
    return 1
  return 0

proc execUpdateRow*(ctx: ExecutionContext, table: string, key: string, sets: Table[string, string]): int =
  let fullKey = table & "." & key
  let (found, existing) = ctx.db.get(fullKey)
  if not found: return 0
  var parsed = parseRowData(cast[string](existing))
  for col, val in sets:
    parsed[col] = val
  var parts: seq[string] = @[]
  for col, val in parsed:
    parts.add(col & "=" & val)
  let newVal = parts.join(",")
  if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
    discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](newVal))
  else:
    ctx.db.put(fullKey, cast[seq[byte]](newVal))
  return 1

# ----------------------------------------------------------------------
# Constraint Validation
# ----------------------------------------------------------------------

proc validateType*(colType: string, value: string): (bool, string) =
  if isNull(value): return (true, "")
  let t = colType.toUpper()
  if t == "INTEGER" or t == "INT" or t == "BIGINT" or t == "SMALLINT" or t == "SERIAL":
    try: discard parseInt(value)
    except: return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "FLOAT" or t == "REAL" or t == "DOUBLE" or t == "DOUBLE PRECISION" or t == "NUMERIC":
    try: discard parseFloat(value)
    except: return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  elif t == "BOOLEAN" or t == "BOOL":
    let lv = value.toLower()
    if lv notin ["true", "false", "1", "0", "t", "f", "yes", "no"]:
      return (false, "Type mismatch: expected BOOLEAN but got '" & value & "'")
  elif t == "TIMESTAMP" or t == "DATE":
    if value.len < 8:  # minimal date check
      return (false, "Type mismatch: expected " & t & " but got '" & value & "'")
  return (true, "")

proc lowerExpr*(node: Node): IRExpr

proc validateConstraints*(ctx: ExecutionContext, tableName: string,
    fields: seq[string], values: seq[seq[string]]): (bool, string) =
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

      # FK check
      if col.fkTable.len > 0 and col.fkColumn.len > 0 and not isNull(val):
        let fkKey = col.fkTable & "." & col.fkColumn & "=" & val
        let (fkExists, _) = ctx.db.get(fkKey)
        if not fkExists:
          # Also check if value is in any row's first field
          var found = false
          let prefix = col.fkTable & "."
          for entry in ctx.db.scanMemTable():
            if entry.deleted: continue
            if entry.key.startsWith(prefix):
              let rest = entry.key[prefix.len..^1]
              if rest.startsWith(col.fkColumn & "=") and rest[col.fkColumn.len+1..^1] == val:
                found = true
                break
          if not found:
            return (false, "FOREIGN KEY violation: '" & val & "' not found in " & col.fkTable & "." & col.fkColumn)

    # PK uniqueness
    if tbl.pkColumns.len > 0:
      var pkVals: seq[string] = @[]
      for pkCol in tbl.pkColumns:
        pkVals.add(getValue(rowVals, fields, pkCol))
      let pkStr = pkVals.join("|")
      let pkKey = tableName & "." & pkStr
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
        var row = initTable[string, string]()
        for i, f in fields:
          if i < rowVals.len:
            row[f] = rowVals[i]
          else:
            row[f] = ""
        let checkExpr = lowerExpr(check.checkNode)
        let checkResult = evalExpr(checkExpr, row)
        if checkResult != "true":
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

# ----------------------------------------------------------------------
# AST → IR Lowering
# ----------------------------------------------------------------------

proc lowerExpr*(node: Node): IRExpr =
  if node == nil: return nil
  case node.kind
  of nkIntLit:
    result = IRExpr(kind: irekLiteral)
    result.literal = IRLiteral(kind: vkInt64, int64Val: node.intVal)
  of nkFloatLit:
    result = IRExpr(kind: irekLiteral)
    result.literal = IRLiteral(kind: vkFloat64, float64Val: node.floatVal)
  of nkStringLit:
    result = IRExpr(kind: irekLiteral)
    result.literal = IRLiteral(kind: vkString, strVal: node.strVal)
  of nkBoolLit:
    result = IRExpr(kind: irekLiteral)
    result.literal = IRLiteral(kind: vkBool, boolVal: node.boolVal)
  of nkNullLit:
    result = IRExpr(kind: irekLiteral)
    result.literal = IRLiteral(kind: vkNull)
  of nkIdent:
    result = IRExpr(kind: irekField)
    result.fieldPath = @[node.identName]
  of nkPath:
    result = IRExpr(kind: irekField)
    result.fieldPath = node.pathParts
  of nkBinOp:
    result = IRExpr(kind: irekBinary)
    var irOp: IROperator
    case node.binOp
    of bkAdd: irOp = irAdd
    of bkSub: irOp = irSub
    of bkMul: irOp = irMul
    of bkDiv: irOp = irDiv
    of bkMod: irOp = irMod
    of bkEq: irOp = irEq
    of bkNotEq: irOp = irNeq
    of bkLt: irOp = irLt
    of bkLtEq: irOp = irLte
    of bkGt: irOp = irGt
    of bkGtEq: irOp = irGte
    of bkAnd: irOp = irAnd
    of bkOr: irOp = irOr
    else: irOp = irEq
    result.binOp = irOp
    result.binLeft = lowerExpr(node.binLeft)
    result.binRight = lowerExpr(node.binRight)
  of nkUnaryOp:
    result = IRExpr(kind: irekUnary)
    result.unOp = if node.unOp == ukNot: irNot else: irNot
    result.unExpr = lowerExpr(node.unOperand)
  of nkFuncCall:
    result = IRExpr(kind: irekAggregate)
    case node.funcName.toLower()
    of "count": result.aggOp = irCount
    of "sum": result.aggOp = irSum
    of "avg": result.aggOp = irAvg
    of "min": result.aggOp = irMin
    of "max": result.aggOp = irMax
    else: result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkNull))
    result.aggArgs = @[]
    for arg in node.funcArgs: result.aggArgs.add(lowerExpr(arg))
  of nkIsExpr:
    result = IRExpr(kind: irekUnary)
    result.unOp = if node.isNegated: irIsNotNull else: irIsNull
    result.unExpr = lowerExpr(node.isExpr)
  of nkLikeExpr:
    result = IRExpr(kind: irekBinary)
    result.binOp = if node.likeCaseInsensitive: irILike else: irLike
    result.binLeft = lowerExpr(node.likeExpr)
    result.binRight = lowerExpr(node.likePattern)
  of nkBetweenExpr:
    result = IRExpr(kind: irekBinary)
    result.binOp = irBetween
    result.binLeft = lowerExpr(node.betweenExpr)
    result.binRight = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkString, strVal: ""))
  of nkInExpr:
    result = IRExpr(kind: irekBinary)
    result.binOp = irIn
    result.binLeft = lowerExpr(node.inLeft)
    result.binRight = lowerExpr(node.inRight)
  of nkExists:
    result = IRExpr(kind: irekExists)
  else:
    result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkNull))

proc lowerSelect*(node: Node): IRPlan =
  result = IRPlan(kind: irpkScan)
  if node.selFrom != nil and node.selFrom.fromTable.len > 0:
    result.scanTable = node.selFrom.fromTable
    result.scanAlias = node.selFrom.fromAlias

  if node.selWhere != nil and node.selWhere.whereExpr != nil:
    let filterPlan = IRPlan(kind: irpkFilter)
    filterPlan.filterSource = result
    filterPlan.filterCond = lowerExpr(node.selWhere.whereExpr)
    result = filterPlan

  if node.selGroupBy.len > 0:
    let groupPlan = IRPlan(kind: irpkGroupBy)
    groupPlan.groupSource = result
    groupPlan.groupKeys = @[]
    for g in node.selGroupBy: groupPlan.groupKeys.add(lowerExpr(g))
    groupPlan.groupAggs = @[]
    if node.selHaving != nil:
      groupPlan.groupHaving = lowerExpr(node.selHaving.havingExpr)
    result = groupPlan

  let projectPlan = IRPlan(kind: irpkProject)
  projectPlan.projectSource = result
  projectPlan.projectExprs = @[]
  projectPlan.projectAliases = @[]
  for e in node.selResult:
    projectPlan.projectExprs.add(lowerExpr(e))
    if e.kind == nkIdent: projectPlan.projectAliases.add(e.identName)
    else: projectPlan.projectAliases.add("")
  result = projectPlan

  if node.selOrderBy.len > 0:
    let sortPlan = IRPlan(kind: irpkSort)
    sortPlan.sortSource = result
    sortPlan.sortExprs = @[]
    sortPlan.sortDirs = @[]
    for o in node.selOrderBy:
      sortPlan.sortExprs.add(lowerExpr(o.orderByExpr))
      sortPlan.sortDirs.add(o.orderByDir == sdAsc)
    result = sortPlan

  if node.selLimit != nil or node.selOffset != nil:
    let limitPlan = IRPlan(kind: irpkLimit)
    limitPlan.limitSource = result
    limitPlan.limitCount = if node.selLimit != nil and node.selLimit.limitExpr.kind == nkIntLit:
      node.selLimit.limitExpr.intVal else: 0
    limitPlan.limitOffset = if node.selOffset != nil and node.selOffset.offsetExpr.kind == nkIntLit:
      node.selOffset.offsetExpr.intVal else: 0
    result = limitPlan

# ----------------------------------------------------------------------
# IR Plan Execution (with actual filter/sort/projection)
# ----------------------------------------------------------------------

proc executePlan*(ctx: ExecutionContext, plan: IRPlan): seq[Row] =
  if plan == nil: return @[]

  case plan.kind
  of irpkScan:
    return execScan(ctx, plan.scanTable)

  of irpkFilter:
    let sourceRows = executePlan(ctx, plan.filterSource)
    if plan.filterCond == nil: return sourceRows
    result = @[]
    for row in sourceRows:
      let evalResult = evalExpr(plan.filterCond, row)
      if evalResult == "true":
        result.add(row)

  of irpkProject:
    let sourceRows = executePlan(ctx, plan.projectSource)
    if plan.projectAliases.len == 0: return sourceRows
    result = @[]
    for row in sourceRows:
      var newRow: Table[string, string]
      for i, alias in plan.projectAliases:
        if i < plan.projectExprs.len:
          let val = evalExpr(plan.projectExprs[i], row)
          if alias.len > 0: newRow[alias] = val
          else: newRow["col" & $i] = val
      if newRow.len > 0:
        result.add(newRow)
      else:
        result.add(row)

  of irpkSort:
    var sourceRows = executePlan(ctx, plan.sortSource)
    if plan.sortExprs.len == 0: return sourceRows
    let sortExpr = plan.sortExprs[0]
    let ascending = if plan.sortDirs.len > 0: plan.sortDirs[0] else: true
    proc sortCmp(a, b: Row): int =
      let va = evalExpr(sortExpr, a)
      let vb = evalExpr(sortExpr, b)
      try:
        let fa = parseFloat(va)
        let fb = parseFloat(vb)
        if fa < fb: return -1
        if fa > fb: return 1
        return 0
      except:
        return cmp(va, vb)
    sourceRows.sort(sortCmp, if ascending: Ascending else: Descending)
    return sourceRows

  of irpkLimit:
    let sourceRows = executePlan(ctx, plan.limitSource)
    var start = int(plan.limitOffset)
    if start > sourceRows.len: start = sourceRows.len
    var endIdx = start + int(plan.limitCount)
    if endIdx > sourceRows.len or plan.limitCount == 0:
      endIdx = sourceRows.len
    return sourceRows[start..<endIdx]

  of irpkGroupBy:
    let sourceRows = executePlan(ctx, plan.groupSource)
    if plan.groupKeys.len == 0: return sourceRows
    # Group rows by the group key values
    var groups = initTable[string, seq[Row]]()
    for row in sourceRows:
      var groupKey = ""
      for gk in plan.groupKeys:
        groupKey &= evalExpr(gk, row) & "|"
      if groupKey notin groups:
        groups[groupKey] = @[]
      groups[groupKey].add(row)
    result = @[]
    for gk, groupRows in groups:
      # For each group, produce one row with the group key and aggregates
      var aggRow: Table[string, string]
      for gkExpr in plan.groupKeys:
        if gkExpr.kind == irekField and gkExpr.fieldPath.len > 0:
          aggRow[gkExpr.fieldPath[^1]] = evalExpr(gkExpr, groupRows[0])
      # COUNT(*) = group size
      aggRow["count(*)"] = $groupRows.len
      result.add(aggRow)
    return result

  of irpkJoin:
    let leftRows = executePlan(ctx, plan.joinLeft)
    let rightRows = executePlan(ctx, plan.joinRight)
    return leftRows  # simplified: return left side

  else:
    return @[]

# ----------------------------------------------------------------------
# High-level execute
# ----------------------------------------------------------------------

proc executeQuery*(ctx: ExecutionContext, astNode: Node): ExecResult =
  if astNode == nil or astNode.stmts.len == 0:
    return okResult()

  let stmt = astNode.stmts[0]
  case stmt.kind
  of nkSelect:
    # Expand view if FROM table is a view
    if stmt.selFrom != nil and stmt.selFrom.fromTable in ctx.views:
      let viewQuery = ctx.views[stmt.selFrom.fromTable]
      if viewQuery != nil and viewQuery.kind == nkSelect:
        # Execute the view's underlying query
        var inner = Node(kind: nkStatementList, stmts: @[])
        inner.stmts.add(viewQuery)
        let innerResult = executeQuery(ctx, inner)
        # Now filter and project with outer query constraints
        var filteredRows = innerResult.rows
        var cols = innerResult.columns
        if stmt.selWhere != nil and stmt.selWhere.whereExpr != nil:
          let whereIr = lowerExpr(stmt.selWhere.whereExpr)
          var tmp: seq[Row] = @[]
          for row in filteredRows:
            if evalExpr(whereIr, row) == "true":
              tmp.add(row)
          filteredRows = tmp
        if stmt.selOrderBy.len > 0:
          let sortExpr = lowerExpr(stmt.selOrderBy[0].orderByExpr)
          let asc = stmt.selOrderBy[0].orderByDir == sdAsc
          proc sortCmp(a, b: Row): int =
            let va = evalExpr(sortExpr, a)
            let vb = evalExpr(sortExpr, b)
            try:
              let fa = parseFloat(va)
              let fb = parseFloat(vb)
              if fa < fb: return -1
              if fa > fb: return 1
              return 0
            except:
              return cmp(va, vb)
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
    if stmt.selFrom != nil and stmt.selFrom.fromTable.len > 0:
      if stmt.selWhere != nil and stmt.selWhere.whereExpr != nil:
        let w = stmt.selWhere.whereExpr
        if w.kind == nkBinOp and w.binOp == bkEq:
          if w.binLeft.kind == nkIdent and w.binRight.kind == nkStringLit:
            let colName = w.binLeft.identName
            let idxName = stmt.selFrom.fromTable & "." & colName
            if idxName in ctx.btrees:
              let entries = ctx.btrees[idxName].get(w.binRight.strVal)
              if entries.len > 0:
                # Fetch actual row data from LSM
                let rows = execPointRead(ctx, stmt.selFrom.fromTable, colName & "=" & w.binRight.strVal)
                let tbl = ctx.getTableDef(stmt.selFrom.fromTable)
                var cols: seq[string] = @[]
                for c in tbl.columns: cols.add(c.name)
                if cols.len == 0: cols = @["key", "value"]
                return okResult(rows, cols)

    # Full pipeline execution
    let plan = lowerSelect(stmt)
    let rows = executePlan(ctx, plan)
    let tbl = ctx.getTableDef(if stmt.selFrom != nil: stmt.selFrom.fromTable else: "")
    var cols: seq[string] = @[]
    for c in tbl.columns: cols.add(c.name)
    if cols.len == 0 and rows.len > 0:
      for k, _ in rows[0]: cols.add(k)
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
          elif v.kind == nkNullLit: row.add("")
          else: row.add("")
      else:
        if rowNode.kind == nkStringLit: row.add(rowNode.strVal)
        elif rowNode.kind == nkIntLit: row.add($rowNode.intVal)
        else: row.add("")
      values.add(row)

    if fields.len == 0:
      let tbl = ctx.getTableDef(stmt.insTarget)
      for col in tbl.columns: fields.add(col.name)

    let tbl = ctx.getTableDef(stmt.insTarget)
    var mutableFields = fields
    var mutableValues = values
    applyDefaultValues(tbl, mutableFields, mutableValues)

    let (valid, errMsg) = validateConstraints(ctx, stmt.insTarget, mutableFields, mutableValues)
    if not valid: return errResult(errMsg)

    let count = execInsert(ctx, stmt.insTarget, mutableFields, mutableValues)
    if ctx.onChange != nil:
      for i in 0..<count:
        ctx.onChange(ChangeEvent(table: stmt.insTarget, kind: ckInsert, key: "", data: ""))
    return okResult(affected=count)

  of nkUpdate:
    if stmt.updSet.len == 0: return okResult()
    # Simple UPDATE: scan table, filter by WHERE, apply SET
    var sets = initTable[string, string]()
    for s in stmt.updSet:
      if s.kind == nkBinOp and s.binOp == bkAssign:
        if s.binLeft.kind == nkIdent:
          let val = if s.binRight.kind == nkStringLit: s.binRight.strVal
                    elif s.binRight.kind == nkIntLit: $s.binRight.intVal
                    elif s.binRight.kind == nkFloatLit: $s.binRight.floatVal
                    else: ""
          sets[s.binLeft.identName] = val

    # Scan and apply
    let rows = execScan(ctx, stmt.updTarget)
    var count = 0
    for row in rows:
      # Check WHERE
      if stmt.updWhere != nil and stmt.updWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.updWhere.whereExpr)
        if evalExpr(whereExpr, row) != "true": continue
      # Get key from row
      if "$key" in row:
        let old = row["$key"]
        # Build updated row for constraint validation
        var updFields: seq[string] = @[]
        var updValues: seq[string] = @[]
        for col in ctx.getTableDef(stmt.updTarget).columns:
          updFields.add(col.name)
          if col.name in sets:
            updValues.add(sets[col.name])
          elif col.name in row:
            updValues.add(row[col.name])
          else:
            updValues.add("")
        let (valid, errMsg) = validateConstraints(ctx, stmt.updTarget, updFields, @[updValues])
        if not valid: return errResult(errMsg)
        count += execUpdateRow(ctx, stmt.updTarget, row["$key"], sets)
        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.updTarget, kind: ckUpdate, key: old, data: ""))
    return okResult(affected=count)

  of nkDelete:
    # Delete all rows matching WHERE
    let rows = execScan(ctx, stmt.delTarget)
    var count = 0
    for row in rows:
      if stmt.delWhere != nil and stmt.delWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.delWhere.whereExpr)
        if evalExpr(whereExpr, row) != "true": continue
      if "$key" in row:
        let old = row["$key"]
        count += execDelete(ctx, stmt.delTarget, row["$key"])
        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.delTarget, kind: ckDelete, key: old, data: ""))
    return okResult(affected=count)

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
            onDelete: cstNode.cstOnDelete))
          if cstNode.cstColumns.len > 0:
            for i, c in tbl.columns:
              if c.name in cstNode.cstColumns:
                tbl.columns[i].fkTable = cstNode.cstRefTable
                tbl.columns[i].fkColumn = if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: ""
        elif cstNode.cstType == "check":
          tbl.checks.add(CheckDef(name: "check_" & $tbl.checks.len, checkNode: cstNode.cstCheck))

    # Second pass: column definitions
    for col in stmt.crtColumns:
      if col.kind == nkColumnDef:
        var colDef = ColumnDef(name: col.cdName, colType: col.cdType)
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
            of "check":
              tbl.checks.add(CheckDef(name: "check_" & col.cdName, checkNode: cst.cstCheck))
            else: discard
        tbl.columns.add(colDef)
    ctx.tables[stmt.crtName] = tbl

    # Persist schema
    var colDefs: seq[string] = @[]
    for col in tbl.columns:
      var parts = @[col.name, col.colType]
      if col.isPk: parts.add("PRIMARY KEY")
      if col.isNotNull: parts.add("NOT NULL")
      if col.isUnique: parts.add("UNIQUE")
      if col.defaultVal.len > 0: parts.add("DEFAULT '" & col.defaultVal & "'")
      if col.fkTable.len > 0:
        parts.add("REFERENCES " & col.fkTable & "(" & col.fkColumn & ")")
      colDefs.add(parts.join(" "))
    let schemaKey = "_schema:migrations:" & $ctx.tables.len
    ctx.db.put(schemaKey, cast[seq[byte]]("CREATE TABLE " & stmt.crtName & " (" & colDefs.join(", ") & ")"))

    return okResult()

  of nkDropTable:
    ctx.tables.del(stmt.drtName)
    var toDelete: seq[string] = @[]
    for idxName in ctx.btrees.keys.toSeq():
      if idxName.startsWith(stmt.drtName & "."): toDelete.add(idxName)
    for idxName in toDelete: ctx.btrees.del(idxName)
    return okResult()

  of nkBeginTxn:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.commit(ctx.pendingTxn)
    ctx.pendingTxn = ctx.txnManager.beginTxn(ilReadCommitted)
    return okResult(msg="Transaction started")

  of nkCommitTxn:
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      for key, version in ctx.pendingTxn.writeSet:
        if version.value == @[]: ctx.db.delete(key)
        else: ctx.db.put(key, version.value)
      discard ctx.txnManager.commit(ctx.pendingTxn)
      ctx.pendingTxn = nil
      return okResult(msg="Transaction committed")
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
      if stmt.expStmt.selFrom != nil:
        planStr &= "SELECT on " & stmt.expStmt.selFrom.fromTable
      var indexUsed = false
      if stmt.expStmt.selFrom != nil and stmt.expStmt.selFrom.fromTable.len > 0:
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
      return okResult(msg="ALTER TABLE " & stmt.altName & " executed")
    return errResult("Table '" & stmt.altName & "' does not exist")

  of nkCreateView:
    ctx.views[stmt.cvName] = stmt.cvQuery
    let viewKey = "_schema:views:" & stmt.cvName
    let viewDdl = "CREATE VIEW " & stmt.cvName & " AS SELECT 1"  # placeholder; real AST serialization needed
    ctx.db.put(viewKey, cast[seq[byte]](viewDdl))
    return okResult(msg="CREATE VIEW " & stmt.cvName)

  of nkDropView:
    if stmt.dvName in ctx.views:
      ctx.views.del(stmt.dvName)
    let viewKey = "_schema:views:" & stmt.dvName
    ctx.db.delete(viewKey)
    return okResult(msg="DROP VIEW " & stmt.dvName)

  of nkCreateMigration:
    # Store migration in LSM-Tree
    let migKey = "_schema:migration:" & stmt.cmName
    ctx.db.put(migKey, cast[seq[byte]](stmt.cmBody))
    return okResult(msg="CREATE MIGRATION " & stmt.cmName)

  of nkApplyMigration:
    # Check if already applied
    let appliedKey = "_schema:migrations:applied:" & stmt.amName
    let (alreadyApplied, _) = ctx.db.get(appliedKey)
    if alreadyApplied:
      return okResult(msg="Migration '" & stmt.amName & "' already applied")
    # Execute stored migration SQL
    let migKey = "_schema:migration:" & stmt.amName
    let (found, val) = ctx.db.get(migKey)
    if not found:
      return errResult("Migration '" & stmt.amName & "' not found")
    let sql = cast[string](val)
    let tokens = qlex.tokenize(sql)
    let astNode = qpar.parse(tokens)
    var result = okResult(msg="APPLY MIGRATION " & stmt.amName)
    if astNode.stmts.len > 0:
      result = executeQuery(ctx, astNode)
    # Mark as applied
    ctx.db.put(appliedKey, cast[seq[byte]]("applied"))
    return result

  of nkCreateIndex:
    let idxName = if stmt.ciName.len > 0: stmt.ciName
                  else: stmt.ciTarget & "." & stmt.ciTarget
    let key = stmt.ciTarget & "." & stmt.ciTarget
    ctx.btrees[key] = newBTreeIndex[string, IndexEntry]()
    # Populate index from existing data
    let rows = execScan(ctx, stmt.ciTarget)
    for row in rows:
      if "$key" in row:
        let val = row["$key"]
        let eqPos = val.find('=')
        if eqPos >= 0:
          let colVal = val[eqPos+1..^1]
          ctx.btrees[key].insert(colVal, IndexEntry(lsmKey: stmt.ciTarget & "." & val, rowValue: ""))
    return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget)

  else:
    return errResult("Unsupported statement type: " & $stmt.kind)
