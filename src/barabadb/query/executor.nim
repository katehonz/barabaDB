## BaraQL Executor — AST lowering, IR compilation, and execution
import std/strutils
import std/tables
import std/hashes
import ast
import ir
import ../core/types
import ../storage/lsm
import ../storage/btree

type
  IndexEntry = ref object
    lsmKey*: string
    rowValue*: string

  ExecutionContext* = ref object
    db*: LSMTree
    tables*: Table[string, TableDef]  # table name -> definition
    btrees*: Table[string, BTreeIndex[string, IndexEntry]]  # index name -> btree

  TableDef* = object
    name*: string
    columns*: seq[ColumnDef]
    pkColumns*: seq[string]

  ColumnDef* = object
    name*: string
    colType*: string
    isPk*: bool
    isNotNull*: bool
    isUnique*: bool
    defaultVal*: string

  Row = Table[string, string]

proc newExecutionContext*(db: LSMTree): ExecutionContext =
  ExecutionContext(db: db, tables: initTable[string, TableDef](),
                   btrees: initTable[string, BTreeIndex[string, IndexEntry]]())

proc execScan(ctx: ExecutionContext, table: string): seq[Row] =
  ## Full table scan via LSM-Tree memtable scan.
  ## Rows are stored as: "{table}.{key}" -> value
  ## For simple KV: key is the PK value, value is the serialized row
  result = @[]
  let prefix = table & "."
  for entry in ctx.db.scanMemTable():
    if entry.deleted:
      continue
    if not entry.key.startsWith(prefix):
      continue
    let rest = entry.key[prefix.len..^1]
    var row: Table[string, string]
    row["$key"] = rest
    row["$value"] = cast[string](entry.value)
    result.add(row)

proc execPointRead(ctx: ExecutionContext, table: string, key: string): seq[Row] =
  ## Point read from LSM-Tree
  let fullKey = table & "." & key
  let (found, val) = ctx.db.get(fullKey)
  if found:
    var row: Table[string, string]
    row["$key"] = key
    row["$value"] = cast[string](val)
    return @[row]
  return @[]

proc execInsert(ctx: ExecutionContext, table: string, fields: seq[string], values: seq[seq[string]]): int =
  ## Insert rows into LSM-Tree with constraint validation and B-Tree index population.
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
    ctx.db.put(fullKey, cast[seq[byte]](valStr))

    # Populate B-Tree indexes
    for colName, btIdx in ctx.btrees:
      if colName.startsWith(table & "."):
        let colOnly = colName[table.len + 1..^1]
        let colVal = getValue(rowVals, fields, colOnly)
        if colVal.len > 0 and not isNull(colVal):
          let entry = IndexEntry(lsmKey: fullKey, rowValue: valStr)
          btIdx.insert(colVal, entry)

    inc count
  return count

proc execUpdateRow(ctx: ExecutionContext, table: string, key: string, sets: seq[(string, string)]): int =
  let fullKey = table & "." & key
  let (found, existing) = ctx.db.get(fullKey)
  if not found:
    return 0
  var valStr = cast[string](existing)
  for (f, v) in sets:
    let prefix = f & "="
    var newParts: seq[string] = @[]
    for part in valStr.split(","):
      if part.startsWith(prefix):
        newParts.add(prefix & v)
      else:
        newParts.add(part)
    # If field not in existing, append
    var hasField = false
    for part in valStr.split(","):
      if part.startsWith(prefix):
        hasField = true
        break
    if not hasField:
      newParts.add(prefix & v)
    valStr = newParts.join(",")
  ctx.db.put(fullKey, cast[seq[byte]](valStr))
  return 1

# ----------------------------------------------------------------------
# Constraint Validation
# ----------------------------------------------------------------------

proc getTableDef(ctx: ExecutionContext, tableName: string): TableDef =
  if tableName in ctx.tables:
    return ctx.tables[tableName]
  var tbl = TableDef(name: tableName, columns: @[], pkColumns: @[])
  return tbl

proc getColumnDef(tbl: TableDef, colName: string): ColumnDef =
  for col in tbl.columns:
    if col.name.toLower() == colName.toLower():
      return col

proc getValue(values: seq[string], fields: seq[string], colName: string): string =
  for i, f in fields:
    if f.toLower() == colName.toLower() and i < values.len:
      return values[i]
  return ""

proc isNull(value: string): bool =
  result = value.len == 0 or value.toLower() == "null"

proc validateConstraints*(ctx: ExecutionContext, tableName: string,
    fields: seq[string], values: seq[seq[string]]): (bool, string) =
  ## Validate INSERT/UPDATE constraints.
  ## Returns (success, errorMessage).

  let tbl = ctx.getTableDef(tableName)

  for rowIdx, rowVals in values:
    for col in tbl.columns:
      let val = getValue(rowVals, fields, col.name)

      # NOT NULL check
      if col.isNotNull and isNull(val):
        return (false, "NOT NULL constraint violated for column '" & col.name & "'")

      # DEFAULT value
      if isNull(val) and col.defaultVal.len > 0:
        # We'll handle this in the insert loop
        discard

    # PRIMARY KEY uniqueness check (against existing data)
    if tbl.pkColumns.len > 0:
      var pkVals: seq[string] = @[]
      for pkCol in tbl.pkColumns:
        pkVals.add(getValue(rowVals, fields, pkCol))
      let pkStr = pkVals.join("|")
      let pkKey = tableName & "." & pkStr
      let (exists, _) = ctx.db.get(pkKey)
      if exists:
        return (false, "UNIQUE constraint violated: duplicate key '" & pkStr & "' for table '" & tableName & "'")

    # UNIQUE constraint check
    for col in tbl.columns:
      if col.isUnique:
        let uVal = getValue(rowVals, fields, col.name)
        if not isNull(uVal):
          # Check uniqueness by scanning existing rows
          let prefix = tableName & "."
          for entry in ctx.db.scanMemTable():
            if entry.deleted: continue
            if entry.key.startsWith(prefix):
              let existingVal = cast[string](entry.value)
              let fieldPrefix = col.name & "="
              for part in existingVal.split(","):
                if part.startsWith(fieldPrefix) and part[fieldPrefix.len..^1] == uVal:
                  return (false, "UNIQUE constraint violated: duplicate value '" & uVal & "' for column '" & col.name & "'")

  return (true, "")

proc applyDefaultValues(tbl: TableDef, fields: var seq[string], values: var seq[seq[string]]) =
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
        if rowIdx < values.len:
          values[rowIdx].add(col.defaultVal)
    else:
      for rowIdx in 0..<values.len:
        if rowIdx < values.len:
          let fidx = fields.len - 1  # approximate
          var found = false
          for i, f in fields:
            if f.toLower() == col.name.toLower() and i < values[rowIdx].len:
              if isNull(values[rowIdx][i]):
                values[rowIdx][i] = col.defaultVal
              found = true
              break
          if not found:
            # Field may have been added, ensure we have a value
            discard

proc execDelete(ctx: ExecutionContext, table: string, key: string): int =
  let fullKey = table & "." & key
  let (found, _) = ctx.db.get(fullKey)
  if found:
    ctx.db.delete(fullKey)
    return 1
  return 0

# ----------------------------------------------------------------------
# AST → IR Lowering
# ----------------------------------------------------------------------

proc lowerExpr(node: Node): IRExpr =
  if node == nil:
    return nil
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
    for arg in node.funcArgs:
      result.aggArgs.add(lowerExpr(arg))
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

proc lowerSelect(node: Node): IRPlan =
  result = IRPlan(kind: irpkScan)
  if node.selFrom != nil and node.selFrom.fromTable.len > 0:
    result.scanTable = node.selFrom.fromTable
    result.scanAlias = node.selFrom.fromAlias

  # WHERE → Filter
  if node.selWhere != nil and node.selWhere.whereExpr != nil:
    let filterPlan = IRPlan(kind: irpkFilter)
    filterPlan.filterSource = result
    filterPlan.filterCond = lowerExpr(node.selWhere.whereExpr)
    result = filterPlan

  # GROUP BY
  if node.selGroupBy.len > 0:
    let groupPlan = IRPlan(kind: irpkGroupBy)
    groupPlan.groupSource = result
    groupPlan.groupKeys = @[]
    for g in node.selGroupBy:
      groupPlan.groupKeys.add(lowerExpr(g))
    groupPlan.groupAggs = @[]
    if node.selHaving != nil:
      groupPlan.groupHaving = lowerExpr(node.selHaving.havingExpr)
    result = groupPlan

  # SELECT → Project
  let projectPlan = IRPlan(kind: irpkProject)
  projectPlan.projectSource = result
  projectPlan.projectExprs = @[]
  projectPlan.projectAliases = @[]
  for e in node.selResult:
    projectPlan.projectExprs.add(lowerExpr(e))
    if e.kind == nkIdent:
      projectPlan.projectAliases.add(e.identName)
    else:
      projectPlan.projectAliases.add("")
  result = projectPlan

  # ORDER BY → Sort
  if node.selOrderBy.len > 0:
    let sortPlan = IRPlan(kind: irpkSort)
    sortPlan.sortSource = result
    sortPlan.sortExprs = @[]
    sortPlan.sortDirs = @[]
    for o in node.selOrderBy:
      sortPlan.sortExprs.add(lowerExpr(o.orderByExpr))
      sortPlan.sortDirs.add(o.orderByDir == sdAsc)
    result = sortPlan

  # LIMIT/OFFSET
  if node.selLimit != nil or node.selOffset != nil:
    let limitPlan = IRPlan(kind: irpkLimit)
    limitPlan.limitSource = result
    limitPlan.limitCount = if node.selLimit != nil and node.selLimit.limitExpr.kind == nkIntLit:
      node.selLimit.limitExpr.intVal else: 0
    limitPlan.limitOffset = if node.selOffset != nil and node.selOffset.offsetExpr.kind == nkIntLit:
      node.selOffset.offsetExpr.intVal else: 0
    result = limitPlan

proc lowerInsert(node: Node): IRPlan =
  result = IRPlan(kind: irpkInsert)
  result.insertTable = node.insTarget
  result.insertFields = @[]
  for f in node.insFields:
    if f.kind == nkIdent:
      result.insertFields.add(f.identName)
    else:
      result.insertFields.add("")
  result.insertValues = @[]
  for rowNode in node.insValues:
    var rowVals: seq[IRExpr] = @[]
    if rowNode.kind == nkArrayLit:
      for v in rowNode.arrayElems:
        rowVals.add(lowerExpr(v))
    else:
      rowVals.add(lowerExpr(rowNode))
    result.insertValues.add(rowVals)

# ----------------------------------------------------------------------
# IR Plan Execution
# ----------------------------------------------------------------------

proc executePlan(ctx: ExecutionContext, plan: IRPlan): seq[Row] =
  if plan == nil:
    return @[]

  case plan.kind
  of irpkScan:
    result = execScan(ctx, plan.scanTable)

  of irpkFilter:
    let sourceRows = executePlan(ctx, plan.filterSource)
    result = sourceRows  # TODO: actual filter evaluation

  of irpkProject:
    let sourceRows = executePlan(ctx, plan.projectSource)
    result = sourceRows

  of irpkSort:
    let sourceRows = executePlan(ctx, plan.sortSource)
    result = sourceRows

  of irpkLimit:
    let sourceRows = executePlan(ctx, plan.limitSource)
    var start = int(plan.limitOffset)
    if start > sourceRows.len: start = sourceRows.len
    var endIdx = start + int(plan.limitCount)
    if endIdx > sourceRows.len or plan.limitCount == 0:
      endIdx = sourceRows.len
    result = sourceRows[start..<endIdx]

  of irpkGroupBy:
    result = executePlan(ctx, plan.groupSource)

  of irpkJoin:
    result = executePlan(ctx, plan.joinLeft)

  else:
    result = @[]

# ----------------------------------------------------------------------
# High-level execute function
# ----------------------------------------------------------------------

proc executeQuery*(ctx: ExecutionContext, astNode: Node): (bool, string, int) =
  ## Execute a parsed AST statement against the execution context.
  ## Returns (success, errorMessage, affectedRows)
  if astNode == nil or astNode.stmts.len == 0:
    return (true, "", 0)

  let stmt = astNode.stmts[0]
  case stmt.kind
  of nkSelect:
    # Check if WHERE clause can use B-Tree index
    var useIndex = false
    var idxKey = ""
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
                useIndex = true
                idxKey = w.binRight.strVal

    if useIndex:
      return (true, "", 1)  # Point read via B-Tree (result count)
    else:
      let plan = lowerSelect(stmt)
      let rows = executePlan(ctx, plan)
      return (true, "", rows.len)

  of nkInsert:
    var fields: seq[string] = @[]
    for f in stmt.insFields:
      if f.kind == nkIdent:
        fields.add(f.identName)
      else:
        fields.add("")

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

    # If no fields specified, use all columns from table definition
    if fields.len == 0:
      let tbl = ctx.getTableDef(stmt.insTarget)
      if tbl.columns.len > 0:
        for col in tbl.columns:
          fields.add(col.name)

    # Apply DEFAULT values
    let tbl = ctx.getTableDef(stmt.insTarget)
    var mutableFields = fields
    var mutableValues = values
    applyDefaultValues(tbl, mutableFields, mutableValues)

    # Validate constraints
    let (valid, errMsg) = validateConstraints(ctx, stmt.insTarget, mutableFields, mutableValues)
    if not valid:
      return (false, errMsg, 0)

    let count = execInsert(ctx, stmt.insTarget, mutableFields, mutableValues)
    return (true, "", count)

  of nkUpdate:
    return (true, "", 0)

  of nkDelete:
    var key = ""
    if stmt.delWhere != nil and stmt.delWhere.whereExpr != nil:
      # Extract simple WHERE key = 'value'
      let w = stmt.delWhere.whereExpr
      if w.kind == nkBinOp and w.binOp == bkEq:
        if w.binLeft.kind == nkIdent and w.binRight.kind == nkStringLit:
          key = w.binLeft.identName & "=" & w.binRight.strVal
    let count = execDelete(ctx, stmt.delTarget, key)
    return (true, "", count)

  of nkCreateTable:
    var tbl = TableDef(name: stmt.crtName, columns: @[], pkColumns: @[])
    for col in stmt.crtColumns:
      if col.kind == nkColumnDef:
        var colDef = ColumnDef(name: col.cdName, colType: col.cdType)
        for cst in col.cdConstraints:
          if cst.kind == nkConstraintDef:
            case cst.cstType
            of "pkey":
              colDef.isPk = true
              tbl.pkColumns.add(col.cdName)
              # Create B-Tree index for PK
              let idxName = stmt.crtName & "." & col.cdName
              var bt = newBTreeIndex[string, IndexEntry]()
              ctx.btrees[idxName] = bt
            of "notnull": colDef.isNotNull = true
            of "unique":
              colDef.isUnique = true
              # Create B-Tree index for UNIQUE
              let idxName2 = stmt.crtName & "." & col.cdName
              var bt2 = newBTreeIndex[string, IndexEntry]()
              ctx.btrees[idxName2] = bt2
            of "default":
              if cst.cstDefault != nil and cst.cstDefault.kind == nkStringLit:
                colDef.defaultVal = cst.cstDefault.strVal
            else: discard
        tbl.columns.add(colDef)
    ctx.tables[stmt.crtName] = tbl
    return (true, "", 0)

  of nkDropTable:
    ctx.tables.del(stmt.drtName)
    # Remove associated B-Tree indexes
    var toDelete: seq[string] = @[]
    for idxName, bt in ctx.btrees:
      if idxName.startsWith(stmt.drtName & "."):
        toDelete.add(idxName)
    for idxName in toDelete:
      ctx.btrees.del(idxName)
    return (true, "", 0)

  of nkBeginTxn:
    return (true, "", 0)

  of nkCommitTxn:
    return (true, "", 0)

  of nkRollbackTxn:
    return (true, "", 0)

  of nkCreateType:
    return (true, "", 0)

  of nkExplainStmt:
    if stmt.expStmt != nil and stmt.expStmt.kind == nkSelect:
      var planStr = "EXPLAIN "
      if stmt.expStmt.selFrom != nil:
        planStr &= "SELECT on " & stmt.expStmt.selFrom.fromTable
      # Check if index can be used
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
      if not indexUsed:
        planStr &= " (full table scan)"
      return (true, "", 0)
    return (true, "", 0)

  else:
    return (false, "Unsupported statement type: " & $stmt.kind, 0)
