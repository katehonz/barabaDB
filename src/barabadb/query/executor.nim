## BaraQL Executor — AST lowering, IR compilation, and execution
import std/strutils
import std/tables
import std/hashes
import std/sequtils
import std/algorithm
import std/re
import checksums/sha2
import std/math
import std/times
import std/json
import lexer as qlex
import parser as qpar
import ast
import ir
import ../core/types
import ../protocol/wire
import ../storage/lsm
import ../storage/btree
import ../storage/wal
import ../core/mvcc
import ../core/tracing
import ../fts/engine as fts

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

  UserDef* = object
    name*: string
    passwordHash*: string
    isSuperuser*: bool
    roles*: seq[string]

  PrivilegeDef* = object
    tableName*: string
    command*: string  # SELECT, INSERT, UPDATE, DELETE, ALL

  PolicyDef* = object
    name*: string
    tableName*: string
    command*: string   # ALL, SELECT, INSERT, UPDATE, DELETE
    usingExpr*: Node   # parsed USING expression
    withCheckExpr*: Node  # parsed WITH CHECK expression

  ExecutionContext* = ref object
    db*: LSMTree
    tables*: Table[string, TableDef]
    btrees*: Table[string, BTreeIndex[string, IndexEntry]]
    views*: Table[string, Node]  # view name -> SELECT AST
    cteTables*: Table[string, seq[Row]]  # CTE name -> rows
    ftsIndexes*: Table[string, fts.InvertedIndex]  # table.col -> FTS index
    txnManager*: TxnManager
    pendingTxn*: Transaction
    onChange*: proc(ev: ChangeEvent) {.closure.}
    users*: Table[string, UserDef]
    policies*: Table[string, seq[PolicyDef]]  # table name -> policies
    currentUser*: string
    currentRole*: string

  MigrationRecord* = object
    name*: string
    checksum*: string
    appliedAt*: int64
    appliedBy*: string
    durationMs*: int
    rolledBack*: bool

  ForeignKeyDef* = object
    refTable*: string
    refColumn*: string
    onDelete*: string  # CASCADE, SET NULL, RESTRICT

  CheckDef* = object
    name*: string
    expr*: string  # stored expression string
    checkNode*: Node  # AST for runtime evaluation

  TriggerDef* = object
    name*: string
    timing*: string   # BEFORE, AFTER
    event*: string    # INSERT, UPDATE, DELETE
    action*: Node     # SQL statement AST

  TableDef* = object
    name*: string
    columns*: seq[ColumnDef]
    pkColumns*: seq[string]
    foreignKeys*: seq[ForeignKeyDef]
    checks*: seq[CheckDef]
    triggers*: seq[TriggerDef]

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
    keyValuePairs*: seq[(string, seq[byte])]

proc okResult*(rows: seq[Row] = @[], cols: seq[string] = @[], affected: int = 0, msg: string = "",
               kvPairs: seq[(string, seq[byte])] = @[]): ExecResult =
  ExecResult(success: true, columns: cols, rows: rows, affectedRows: affected, message: msg,
             keyValuePairs: kvPairs)

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
                   cteTables: initTable[string, seq[Row]](),
                   ftsIndexes: initTable[string, fts.InvertedIndex](),
                   users: initTable[string, UserDef](),
                   policies: initTable[string, seq[PolicyDef]](),
                   currentUser: "", currentRole: "",
                   onChange: nil)
  restoreSchema(result)

# ----------------------------------------------------------------------
# AST to SQL serializer (for VIEW DDL persistence)
# ----------------------------------------------------------------------

proc exprToSql(node: Node): string =
  if node == nil:
    return ""
  case node.kind
  of nkIntLit:
    return $node.intVal
  of nkFloatLit:
    return $node.floatVal
  of nkStringLit:
    return "'" & node.strVal & "'"
  of nkBoolLit:
    return if node.boolVal: "true" else: "false"
  of nkNullLit:
    return "null"
  of nkIdent:
    return node.identName
  of nkStar:
    return "*"
  of nkBinOp:
    let opStr = case node.binOp
      of bkEq: "="
      of bkNotEq: "!="
      of bkLt: "<"
      of bkLtEq: "<="
      of bkGt: ">"
      of bkGtEq: ">="
      of bkAnd: " AND "
      of bkOr: " OR "
      of bkAdd: " + "
      of bkSub: " - "
      of bkMul: " * "
      of bkDiv: " / "
      else: " " & $node.binOp & " "
    return exprToSql(node.binLeft) & opStr & exprToSql(node.binRight)
  of nkFuncCall:
    return node.funcName & "(" & exprToSql(node.funcArgs[0]) & ")"
  of nkUnaryOp:
    return $node.unOp & " " & exprToSql(node.unOperand)
  else:
    return $node.kind

proc selectToSql(node: Node): string =
  if node == nil:
    return ""
  result = "SELECT "
  # Column list
  for i, e in node.selResult:
    if i > 0: result.add(", ")
    result.add(exprToSql(e))
    if e.exprAlias.len > 0:
      result.add(" AS " & e.exprAlias)
  # FROM
  if node.selFrom != nil and node.selFrom.fromTable.len > 0:
    result.add(" FROM " & node.selFrom.fromTable)
    if node.selFrom.fromAlias.len > 0:
      result.add(" AS " & node.selFrom.fromAlias)
  # JOINs
  for j in node.selJoins:
    if j.kind == nkJoin:
      let jkStr = case j.joinKind
        of jkInner: "INNER JOIN"
        of jkLeft: "LEFT JOIN"
        of jkRight: "RIGHT JOIN"
        of jkFull: "FULL JOIN"
        of jkCross: "CROSS JOIN"
      result.add(" " & jkStr & " " & j.joinTarget.fromTable)
      if j.joinAlias.len > 0:
        result.add(" AS " & j.joinAlias)
      if j.joinOn != nil:
        result.add(" ON " & exprToSql(j.joinOn))
  # WHERE
  if node.selWhere != nil and node.selWhere.whereExpr != nil:
    result.add(" WHERE " & exprToSql(node.selWhere.whereExpr))
  # GROUP BY
  if node.selGroupBy.len > 0:
    result.add(" GROUP BY ")
    for i, g in node.selGroupBy:
      if i > 0: result.add(", ")
      result.add(exprToSql(g))
  # HAVING
  if node.selHaving != nil and node.selHaving.havingExpr != nil:
    result.add(" HAVING " & exprToSql(node.selHaving.havingExpr))
  # ORDER BY
  if node.selOrderBy.len > 0:
    result.add(" ORDER BY ")
    for i, o in node.selOrderBy:
      if i > 0: result.add(", ")
      result.add(exprToSql(o.orderByExpr))
      if o.orderByDir == sdDesc:
        result.add(" DESC")
  # LIMIT / OFFSET
  if node.selLimit != nil and node.selLimit.limitExpr.kind == nkIntLit:
    result.add(" LIMIT " & $node.selLimit.limitExpr.intVal)
  if node.selOffset != nil and node.selOffset.offsetExpr.kind == nkIntLit:
    result.add(" OFFSET " & $node.selOffset.offsetExpr.intVal)

# ----------------------------------------------------------------------
# Schema restore
# ----------------------------------------------------------------------

proc restoreSchema(ctx: ExecutionContext) =
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if not entry.key.startsWith("_schema:"): continue
    let ddl = cast[string](entry.value)
    if ddl.len == 0: continue
    let tokens = qlex.tokenize(ddl)
    let astNode = qpar.parse(tokens)
    if astNode.stmts.len > 0:
      let stmt = astNode.stmts[0]
      case stmt.kind
      of nkCreateTable:
        var tbl = TableDef(name: stmt.crtName, columns: @[], pkColumns: @[],
                           foreignKeys: @[], checks: @[], triggers: @[])
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
      of nkCreateTrigger:
        if stmt.trigTable in ctx.tables:
          ctx.tables[stmt.trigTable].triggers.add(TriggerDef(
            name: stmt.trigName,
            timing: stmt.trigTiming,
            event: stmt.trigEvent,
            action: stmt.trigAction,
          ))
      of nkCreateUser:
        ctx.users[stmt.cuName] = UserDef(name: stmt.cuName,
            passwordHash: stmt.cuPassword, isSuperuser: stmt.cuSuperuser, roles: @[])
      of nkCreatePolicy:
        var pols = ctx.policies.getOrDefault(stmt.cpTable)
        pols.add(PolicyDef(name: stmt.cpName, tableName: stmt.cpTable,
                           command: stmt.cpCommand, usingExpr: stmt.cpUsing,
                           withCheckExpr: stmt.cpWithCheck))
        ctx.policies[stmt.cpTable] = pols
      else: discard

proc cloneForConnection*(ctx: ExecutionContext): ExecutionContext =
  ExecutionContext(db: ctx.db, tables: ctx.tables,
                   btrees: ctx.btrees, views: ctx.views,
                   cteTables: initTable[string, seq[Row]](),
                   ftsIndexes: ctx.ftsIndexes,
                   users: ctx.users, policies: ctx.policies,
                   txnManager: ctx.txnManager,
                   currentUser: ctx.currentUser, currentRole: ctx.currentRole,
                   pendingTxn: nil, onChange: ctx.onChange)

# ----------------------------------------------------------------------
# Migration Helpers
# ----------------------------------------------------------------------

proc migrationLockKey(): string = "_schema:migrations:_lock"

proc acquireMigrationLock(ctx: ExecutionContext): bool =
  let lockKey = migrationLockKey()
  let (locked, _) = ctx.db.get(lockKey)
  if locked:
    return false
  ctx.db.put(lockKey, cast[seq[byte]]("locked"))
  return true

proc releaseMigrationLock(ctx: ExecutionContext) =
  ctx.db.delete(migrationLockKey())

proc migrationAppliedKey(name: string): string = "_schema:migrations:applied:" & name

proc migrationRecordKey(name: string): string = "_schema:migrations:record:" & name

proc isMigrationApplied(ctx: ExecutionContext, name: string): bool =
  let (applied, _) = ctx.db.get(migrationAppliedKey(name))
  return applied

proc getMigrationRecord(ctx: ExecutionContext, name: string): MigrationRecord =
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

proc setMigrationRecord(ctx: ExecutionContext, rec: MigrationRecord) =
  let val = rec.name & "|" & rec.checksum & "|" & $rec.appliedAt & "|" &
            rec.appliedBy & "|" & $rec.durationMs & "|" & (if rec.rolledBack: "true" else: "false")
  ctx.db.put(migrationRecordKey(rec.name), cast[seq[byte]](val))

proc computeChecksum(body: string): string =
  let h = secureHash(Sha_256, body)
  return $h

proc listMigrations(ctx: ExecutionContext): seq[string] =
  result = @[]
  for entry in ctx.db.scanMemTable():
    if entry.deleted: continue
    if entry.key.startsWith("_schema:migration:") and not entry.key.contains(":applied:") and
       not entry.key.contains(":record:") and not entry.key.contains(":_lock"):
      let name = entry.key["_schema:migration:".len..^1]
      result.add(name)
  sort(result)

proc getMigrationBody(ctx: ExecutionContext, name: string): (bool, string, string) =
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

proc evalExpr*(expr: IRExpr, row: Table[string, string], ctx: ExecutionContext = nil): string =
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
      # Check full path first for joined columns (e.g. "u.name")
      let fullPath = expr.fieldPath.join(".")
      if fullPath in row: return row[fullPath]
      let colName = expr.fieldPath[^1]
      if colName in row: return row[colName]
      if "$key" in row and row["$key"].startsWith(colName & "="):
        return row["$key"][colName.len+1..^1]
      if "$value" in row:
        let parsed = parseRowData(row["$value"])
        if colName in parsed: return parsed[colName]
    return ""
  of irekStar:
    return "*"
  of irekJsonPath:
    let srcVal = evalExpr(expr.jpExpr, row)
    if srcVal.len == 0: return ""
    try:
      let node = parseJson(srcVal)
      if node.hasKey(expr.jpKey):
        let val = node[expr.jpKey]
        if expr.jpAsText:
          case val.kind
          of JString: return val.getStr()
          of JInt: return $val.getInt()
          of JFloat: return $val.getFloat()
          of JBool: return $val.getBool()
          of JNull: return "null"
          else: return $val
        else:
          case val.kind
          of JString: return "\"" & val.getStr() & "\""
          of JNull: return "null"
          else: return $val
      return ""
    except:
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
    of irMod:
      try:
        let a = parseInt(left)
        let b = parseInt(right)
        if b != 0: return $(a mod b)
        return "0"
      except: return "0"
    of irPow:
      try: return $(pow(parseFloat(left), parseFloat(right)))
      except: return "0"
    of irLike:
      let pattern = right.replace("%", ".*").replace("_", ".")
      try:
        let rePattern = re(pattern)
        if left.match(rePattern): return "true"
      except: discard
      return "false"
    of irILike:
      let pattern = right.toLower().replace("%", ".*").replace("_", ".")
      try:
        let rePattern = re(pattern)
        if left.toLower().match(rePattern): return "true"
      except: discard
      return "false"
    of irIn:
      try:
        let lv = parseFloat(left)
        let rv = parseFloat(right)
        return if lv == rv: "true" else: "false"
      except: discard
      return if left == right: "true" else: "false"
    of irNotIn:
      try:
        let lv = parseFloat(left)
        let rv = parseFloat(right)
        return if lv != rv: "true" else: "false"
      except: discard
      return if left != right: "true" else: "false"
    of irFtsMatch:
      # Check for FTS index via ctx
      if ctx != nil and expr.binLeft.kind == irekField and expr.binLeft.fieldPath.len > 0:
        let colName = expr.binLeft.fieldPath[^1]
        # Find FTS index for this column (search by column name suffix)
        var ftsIdx: fts.InvertedIndex = nil
        var ftsKey = ""
        for key, idx in ctx.ftsIndexes:
          if key.endsWith("." & colName):
            ftsIdx = idx
            ftsKey = key
            break
        if ftsIdx != nil:
          let results = ftsIdx.search(right, limit = 10000)
          # Get the row's document key to check if it's in results
          let rowKey = if "$key" in row: row["$key"] else: ""
          let tableName = ftsKey[0..<ftsKey.rfind('.')]
          let docKey = tableName & "." & rowKey
          # Assign docId from key hash
          var docId: uint64 = 0
          for ch in docKey:
            docId = docId * 31 + uint64(ord(ch))
          for r in results:
            if r.docId == docId:
              return "true"
          return "false"
      # Fallback: case-insensitive phrase containment
      let colVal = left.toLower()
      let query = right.toLower()
      let terms = query.split()
      for term in terms:
        if term.len > 0 and term notin colVal:
          return "false"
      return "true"
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

proc lowerExpr*(node: Node): IRExpr

# ----------------------------------------------------------------------
# Row-Level Security
# ----------------------------------------------------------------------

proc hasPrivilege(ctx: ExecutionContext, tableName, command: string): bool =
  if ctx.currentUser.len == 0: return true
  let user = ctx.users.getOrDefault(ctx.currentUser)
  if user.isSuperuser: return true
  # Check table-level policies for user or PUBLIC
  # For now: if no policies exist, allow everything (backward compatible)
  if tableName notin ctx.policies: return true
  let policies = ctx.policies[tableName]
  # If RLS is enabled (policies exist), check if user matches any policy
  for pol in policies:
    if pol.command == "ALL" or pol.command == command:
      return true
  return false

proc passesPolicy(ctx: ExecutionContext, tableName, command: string, row: Row): bool =
  if ctx.currentUser.len == 0: return true
  let user = ctx.users.getOrDefault(ctx.currentUser)
  if user.isSuperuser: return true
  if tableName notin ctx.policies: return true
  let policies = ctx.policies[tableName]
  for pol in policies:
    if pol.command != "ALL" and pol.command != command:
      continue
    if pol.usingExpr != nil:
      let expr = lowerExpr(pol.usingExpr)
      if evalExpr(expr, row) != "true":
        return false
  return true

proc checkInsertPolicy(ctx: ExecutionContext, tableName: string, row: Row): bool =
  if ctx.currentUser.len == 0: return true
  let user = ctx.users.getOrDefault(ctx.currentUser)
  if user.isSuperuser: return true
  if tableName notin ctx.policies: return true
  let policies = ctx.policies[tableName]
  for pol in policies:
    if pol.command != "ALL" and pol.command != "INSERT":
      continue
    if pol.withCheckExpr != nil:
      let expr = lowerExpr(pol.withCheckExpr)
      if evalExpr(expr, row) != "true":
        return false
  return true

# ----------------------------------------------------------------------
# Table scan and storage
# ----------------------------------------------------------------------

proc execScan(ctx: ExecutionContext, table: string): seq[Row] =
  result = @[]
  # Check CTE tables first
  if table in ctx.cteTables:
    return ctx.cteTables[table]
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
    # RLS filter
    if passesPolicy(ctx, table, "SELECT", row):
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

proc execInsert*(ctx: ExecutionContext, table: string, fields: seq[string], values: seq[seq[string]],
                  kvPairs: var seq[(string, seq[byte])]): int =
  if not hasPrivilege(ctx, table, "INSERT"):
    return 0
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

    # Build row for RLS WITH CHECK
    var row = initTable[string, string]()
    for i, f in fields:
      if i < rowVals.len:
        row[f] = rowVals[i]
    if not checkInsertPolicy(ctx, table, row):
      continue

    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](valStr))
    else:
      ctx.db.put(fullKey, cast[seq[byte]](valStr))
      kvPairs.add((fullKey, cast[seq[byte]](valStr)))

    for colName in ctx.btrees.keys.toSeq():
      if colName.startsWith(table & "."):
        let colsPart = colName[table.len + 1..^1]
        let idxCols = colsPart.split(".")
        var colVals: seq[string] = @[]
        for c in idxCols:
          colVals.add(getValue(rowVals, fields, c))
        let idxVal = colVals.join("|")
        if idxVal.len > 0 and not isNull(idxVal):
          ctx.btrees[colName].insert(idxVal, IndexEntry(lsmKey: fullKey, rowValue: valStr))

    # Update FTS indexes
    for ftsKey, ftsIdx in ctx.ftsIndexes:
      if ftsKey.startsWith(table & "."):
        let colName = ftsKey[table.len + 1..^1]
        let text = getValue(rowVals, fields, colName)
        if text.len > 0:
          var docId: uint64 = 0
          for ch in fullKey:
            docId = docId * 31 + uint64(ord(ch))
          ftsIdx.addDocument(docId, text)

    inc count
  return count

proc execDelete*(ctx: ExecutionContext, table: string, key: string,
                  kvPairs: var seq[(string, seq[byte])]): int =
  if not hasPrivilege(ctx, table, "DELETE"):
    return 0
  let fullKey = table & "." & key
  let (found, existingVal) = ctx.db.get(fullKey)
  if found:
    # RLS USING check on existing row
    var oldRow = parseRowData(cast[string](existingVal))
    let eqPos = key.find('=')
    if eqPos >= 0:
      oldRow[key[0..<eqPos]] = key[eqPos+1..^1]
    if not passesPolicy(ctx, table, "DELETE", oldRow):
      return 0
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.delete(ctx.pendingTxn, fullKey)
    else:
      ctx.db.delete(fullKey)
      kvPairs.add((fullKey, @[]))
    # Update FTS indexes
    for ftsKey, ftsIdx in ctx.ftsIndexes:
      if ftsKey.startsWith(table & "."):
        var docId: uint64 = 0
        for ch in fullKey:
          docId = docId * 31 + uint64(ord(ch))
        ftsIdx.removeDocument(docId)
    return 1
  return 0

proc execUpdateRow*(ctx: ExecutionContext, table: string, key: string, sets: Table[string, string],
                     kvPairs: var seq[(string, seq[byte])]): int =
  if not hasPrivilege(ctx, table, "UPDATE"):
    return 0
  let fullKey = table & "." & key
  let (found, existing) = ctx.db.get(fullKey)
  if not found: return 0
  var oldRow = parseRowData(cast[string](existing))
  let eqPos = key.find('=')
  if eqPos >= 0:
    oldRow[key[0..<eqPos]] = key[eqPos+1..^1]
  # RLS USING check on old row
  if not passesPolicy(ctx, table, "UPDATE", oldRow):
    return 0
  var parsed = parseRowData(cast[string](existing))
  for col, val in sets:
    parsed[col] = val
  # RLS WITH CHECK on new row
  if not checkInsertPolicy(ctx, table, parsed):
    return 0
  var parts: seq[string] = @[]
  for col, val in parsed:
    parts.add(col & "=" & val)
  let newVal = parts.join(",")
  # Update indexes: remove old, insert new
  for colName in ctx.btrees.keys.toSeq():
    if colName.startsWith(table & "."):
      let colsPart = colName[table.len + 1..^1]
      let idxCols = colsPart.split(".")
      var oldVals: seq[string] = @[]
      var newVals: seq[string] = @[]
      for c in idxCols:
        if c in oldRow:
          oldVals.add(oldRow[c])
        else:
          oldVals.add("")
        if c in parsed:
          newVals.add(parsed[c])
        else:
          newVals.add("")
      let newIdxVal = newVals.join("|")
      if newIdxVal.len > 0 and not isNull(newIdxVal):
        ctx.btrees[colName].insert(newIdxVal, IndexEntry(lsmKey: fullKey, rowValue: newVal))
  if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
    discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](newVal))
  else:
    ctx.db.put(fullKey, cast[seq[byte]](newVal))
    kvPairs.add((fullKey, cast[seq[byte]](newVal)))
  # Update FTS indexes: remove old doc, add new
  for ftsKey, ftsIdx in ctx.ftsIndexes:
    if ftsKey.startsWith(table & "."):
      var docId: uint64 = 0
      for ch in fullKey:
        docId = docId * 31 + uint64(ord(ch))
      ftsIdx.removeDocument(docId)
      let colName = ftsKey[table.len + 1..^1]
      let newText = if colName in parsed: parsed[colName] else: ""
      if newText.len > 0:
        ftsIdx.addDocument(docId, newText)
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
  elif t == "JSON" or t == "JSONB":
    try:
      discard parseJson(value)
    except:
      return (false, "Type mismatch: expected JSON but got '" & value & "'")
  return (true, "")

proc executeQuery*(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult
proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult

proc fireTriggers*(ctx: ExecutionContext, tableName: string, timing: string, event: string, row: Table[string, string]) =
  let tbl = ctx.getTableDef(tableName)
  for trig in tbl.triggers:
    if trig.timing == timing and trig.event == event:
      if trig.action != nil:
        let tokens = qlex.tokenize(trig.action.strVal)
        let astNode = qpar.parse(tokens)
        if astNode.stmts.len > 0:
          discard executeQuery(ctx, astNode)

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
  of nkJsonPath:
    result = IRExpr(kind: irekJsonPath)
    result.jpExpr = lowerExpr(node.jpLeft)
    result.jpKey = node.jpKey
    result.jpAsText = node.jpAsText
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
    of bkFtsMatch: irOp = irFtsMatch
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
    result.binOp = irAnd
    let leftCmp = IRExpr(kind: irekBinary)
    leftCmp.binOp = irGte
    leftCmp.binLeft = lowerExpr(node.betweenExpr)
    leftCmp.binRight = lowerExpr(node.betweenLow)
    let rightCmp = IRExpr(kind: irekBinary)
    rightCmp.binOp = irLte
    rightCmp.binLeft = lowerExpr(node.betweenExpr)
    rightCmp.binRight = lowerExpr(node.betweenHigh)
    result.binLeft = leftCmp
    result.binRight = rightCmp
  of nkInExpr:
    if node.inRight.kind == nkArrayLit:
      result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkBool, boolVal: false))
      for elem in node.inRight.arrayElems:
        let eqCmp = IRExpr(kind: irekBinary)
        eqCmp.binOp = irEq
        eqCmp.binLeft = lowerExpr(node.inLeft)
        eqCmp.binRight = lowerExpr(elem)
        let orNode = IRExpr(kind: irekBinary)
        orNode.binOp = irOr
        orNode.binLeft = result
        orNode.binRight = eqCmp
        result = orNode
    else:
      result = IRExpr(kind: irekBinary)
      result.binOp = irEq
      result.binLeft = lowerExpr(node.inLeft)
      result.binRight = lowerExpr(node.inRight)
  of nkExists:
    result = IRExpr(kind: irekExists)
  of nkStar:
    result = IRExpr(kind: irekStar)
  else:
    result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkNull))

proc lowerSelect*(node: Node): IRPlan =
  result = IRPlan(kind: irpkScan)
  if node.selFrom != nil and node.selFrom.fromTable.len > 0:
    result.scanTable = node.selFrom.fromTable
    result.scanAlias = node.selFrom.fromAlias

  # Build JOIN chain
  for joinNode in node.selJoins:
    if joinNode.kind == nkJoin:
      let joinPlan = IRPlan(kind: irpkJoin)
      case joinNode.joinKind
      of jkInner: joinPlan.joinKind = irjkInner
      of jkLeft: joinPlan.joinKind = irjkLeft
      of jkRight: joinPlan.joinKind = irjkRight
      of jkFull: joinPlan.joinKind = irjkFull
      of jkCross: joinPlan.joinKind = irjkCross
      joinPlan.joinLeft = result
      joinPlan.joinRight = IRPlan(kind: irpkScan)
      if joinNode.joinTarget != nil and joinNode.joinTarget.kind == nkFrom:
        joinPlan.joinRight.scanTable = joinNode.joinTarget.fromTable
        joinPlan.joinRight.scanAlias = joinNode.joinTarget.fromAlias
      else:
        joinPlan.joinRight.scanTable = ""
      joinPlan.joinAlias = joinNode.joinAlias
      if joinNode.joinOn != nil:
        joinPlan.joinCond = lowerExpr(joinNode.joinOn)
      result = joinPlan

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
    if e.exprAlias.len > 0:
      projectPlan.projectAliases.add(e.exprAlias)
    elif e.kind == nkIdent:
      projectPlan.projectAliases.add(e.identName)
    elif e.kind == nkPath and e.pathParts.len > 0:
      projectPlan.projectAliases.add(e.pathParts[^1])
    else:
      projectPlan.projectAliases.add("")
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
      let evalResult = evalExpr(plan.filterCond, row, ctx)
      if evalResult == "true":
        result.add(row)

  of irpkProject:
    let sourceRows = executePlan(ctx, plan.projectSource)
    if plan.projectAliases.len == 0: return sourceRows

    # Check if this projection contains aggregates without GROUP BY
    var hasAggs = false
    for expr in plan.projectExprs:
      if expr != nil and expr.kind == irekAggregate:
        hasAggs = true
        break

    if hasAggs:
      # Produce exactly one row with aggregate values
      var newRow: Table[string, string]
      for i, alias in plan.projectAliases:
        if i < plan.projectExprs.len:
          let expr = plan.projectExprs[i]
          if expr.kind == irekStar:
            for k, v in sourceRows[0]:
              if not k.startsWith("$") and not k.contains("."):
                newRow[k] = v
          elif expr.kind == irekAggregate:
            case expr.aggOp
            of irCount:
              if expr.aggArgs.len == 0:
                newRow[alias] = $sourceRows.len
              else:
                var count = 0
                for row in sourceRows:
                  let v = evalExpr(expr.aggArgs[0], row)
                  if v.len > 0: count += 1
                newRow[alias] = $count
            of irSum:
              var sum = 0.0
              for row in sourceRows:
                let v = evalExpr(expr.aggArgs[0], row)
                try: sum += parseFloat(v) except: discard
              newRow[alias] = $sum
            of irAvg:
              var sum = 0.0
              var count = 0
              for row in sourceRows:
                let v = evalExpr(expr.aggArgs[0], row)
                try: sum += parseFloat(v); count += 1 except: discard
              newRow[alias] = if count > 0: $(sum / float(count)) else: "0"
            of irMin:
              var minVal = ""
              for row in sourceRows:
                let v = evalExpr(expr.aggArgs[0], row)
                if minVal == "" or v < minVal: minVal = v
              newRow[alias] = minVal
            of irMax:
              var maxVal = ""
              for row in sourceRows:
                let v = evalExpr(expr.aggArgs[0], row)
                if maxVal == "" or v > maxVal: maxVal = v
              newRow[alias] = maxVal
          else:
            let val = evalExpr(expr, if sourceRows.len > 0: sourceRows[0] else: initTable[string, string]())
            if alias.len > 0: newRow[alias] = val
            else: newRow["col" & $i] = val
      result = @[newRow]
      return result

    result = @[]
    for row in sourceRows:
      var newRow: Table[string, string]
      for i, alias in plan.projectAliases:
        if i < plan.projectExprs.len:
          let expr = plan.projectExprs[i]
          if expr.kind == irekStar:
            # Expand star to all columns in the row (excluding internal keys)
            for k, v in row:
              if not k.startsWith("$") and not k.contains("."):
                newRow[k] = v
          else:
            let val = evalExpr(expr, row)
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
    result = @[]

    # Collect all unique column names from each side (excluding internal $ keys)
    var leftCols, rightCols: seq[string]
    for l in leftRows:
      for k, _ in l:
        if not k.startsWith("$") and k notin leftCols:
          leftCols.add(k)
    for r in rightRows:
      for k, _ in r:
        if not k.startsWith("$") and k notin rightCols:
          rightCols.add(k)

    proc mergeRow(left, right: Row, leftAlias, rightAlias: string): Row =
      result = initTable[string, string]()
      # Copy left keys first (left wins on collision for bare keys)
      for k, v in left:
        if not k.startsWith("$"):
          result[k] = v
      # Copy right keys that don't collide; colliding keys only get prefixed
      for k, v in right:
        if not k.startsWith("$") and k notin result:
          result[k] = v
      # Always add prefixed versions for disambiguation
      if leftAlias.len > 0:
        for k, v in left:
          if not k.startsWith("$"):
            result[leftAlias & "." & k] = v
      if rightAlias.len > 0:
        for k, v in right:
          if not k.startsWith("$"):
            result[rightAlias & "." & k] = v

    let leftAlias = if plan.joinLeft != nil and plan.joinLeft.kind == irpkScan:
                      plan.joinLeft.scanAlias else: ""
    let rightAlias = if plan.joinRight != nil and plan.joinRight.kind == irpkScan:
                       plan.joinRight.scanAlias else: ""

    if plan.joinKind == irjkCross:
      for l in leftRows:
        for r in rightRows:
          result.add(mergeRow(l, r, leftAlias, rightAlias))
      return result

    for l in leftRows:
      var matched = false
      for r in rightRows:
        let merged = mergeRow(l, r, leftAlias, rightAlias)
        if plan.joinCond == nil or evalExpr(plan.joinCond, merged) == "true":
          result.add(merged)
          matched = true
      if not matched and (plan.joinKind == irjkLeft or plan.joinKind == irjkFull):
        var padded = initTable[string, string]()
        for k, v in l:
          if not k.startsWith("$"):
            padded[k] = v
        for col in rightCols:
          if col notin padded: padded[col] = ""
        if leftAlias.len > 0:
          for k, v in l:
            if not k.startsWith("$"):
              padded[leftAlias & "." & k] = v
        if rightAlias.len > 0:
          for col in rightCols:
            padded[rightAlias & "." & col] = ""
        result.add(padded)

    if plan.joinKind == irjkRight or plan.joinKind == irjkFull:
      for r in rightRows:
        var found = false
        for l in leftRows:
          let merged = mergeRow(l, r, leftAlias, rightAlias)
          if plan.joinCond == nil or evalExpr(plan.joinCond, merged) == "true":
            found = true
            break
        if not found:
          var padded = initTable[string, string]()
          for k, v in r:
            if not k.startsWith("$"):
              padded[k] = v
          for col in leftCols:
            if col notin padded: padded[col] = ""
          if rightAlias.len > 0:
            for k, v in r:
              if not k.startsWith("$"):
                padded[rightAlias & "." & k] = v
          if leftAlias.len > 0:
            for col in leftCols:
              padded[leftAlias & "." & col] = ""
          result.add(padded)

    return result

  else:
    return @[]

# ----------------------------------------------------------------------
# Parameter binding
# ----------------------------------------------------------------------

proc doBindParams(node: Node, params: seq[WireValue], idx: var int): Node =
  if node == nil: return nil
  case node.kind
  of nkPlaceholder:
    if idx < params.len:
      let p = params[idx]
      inc idx
      case p.kind
      of fkString:  return Node(kind: nkStringLit, strVal: p.strVal)
      of fkInt64:   return Node(kind: nkIntLit, intVal: int(p.int64Val))
      of fkInt32:   return Node(kind: nkIntLit, intVal: int(p.int32Val))
      of fkInt16:   return Node(kind: nkIntLit, intVal: int(p.int16Val))
      of fkInt8:    return Node(kind: nkIntLit, intVal: int(p.int8Val))
      of fkFloat64: return Node(kind: nkFloatLit, floatVal: p.float64Val)
      of fkFloat32: return Node(kind: nkFloatLit, floatVal: float(p.float32Val))
      of fkBool:    return Node(kind: nkBoolLit, boolVal: p.boolVal)
      of fkNull:    return Node(kind: nkNullLit)
      else:         return Node(kind: nkNullLit)
    else:
      return Node(kind: nkNullLit)
  of nkBinOp:
    result = Node(kind: nkBinOp, binOp: node.binOp,
                  line: node.line, col: node.col)
    result.binLeft = doBindParams(node.binLeft, params, idx)
    result.binRight = doBindParams(node.binRight, params, idx)
  of nkUnaryOp:
    result = Node(kind: nkUnaryOp, unOp: node.unOp,
                  line: node.line, col: node.col)
    result.unOperand = doBindParams(node.unOperand, params, idx)
  of nkFuncCall:
    result = Node(kind: nkFuncCall, funcName: node.funcName,
                  line: node.line, col: node.col)
    result.funcArgs = @[]
    for arg in node.funcArgs:
      result.funcArgs.add(doBindParams(arg, params, idx))
  of nkArrayLit:
    result = Node(kind: nkArrayLit, line: node.line, col: node.col)
    result.arrayElems = @[]
    for e in node.arrayElems:
      result.arrayElems.add(doBindParams(e, params, idx))
  of nkStatementList:
    result = Node(kind: nkStatementList, line: node.line, col: node.col)
    result.stmts = @[]
    for s in node.stmts:
      result.stmts.add(doBindParams(s, params, idx))
  of nkSelect:
    result = Node(kind: nkSelect, line: node.line, col: node.col)
    result.selDistinct = node.selDistinct
    result.selResult = @[]
    for e in node.selResult:
      result.selResult.add(doBindParams(e, params, idx))
    result.selFrom = node.selFrom  # FROM doesn't have placeholders
    result.selJoins = @[]
    for j in node.selJoins:
      var nj = Node(kind: nkJoin, joinKind: j.joinKind,
                    joinTarget: j.joinTarget, joinAlias: j.joinAlias,
                    line: j.line, col: j.col)
      nj.joinOn = doBindParams(j.joinOn, params, idx)
      result.selJoins.add(nj)
    result.selWhere = doBindParams(node.selWhere, params, idx)
    result.selGroupBy = @[]
    for g in node.selGroupBy:
      result.selGroupBy.add(doBindParams(g, params, idx))
    result.selHaving = doBindParams(node.selHaving, params, idx)
    result.selOrderBy = @[]
    for o in node.selOrderBy:
      var no = Node(kind: nkOrderBy, orderByDir: o.orderByDir,
                    line: o.line, col: o.col)
      no.orderByExpr = doBindParams(o.orderByExpr, params, idx)
      result.selOrderBy.add(no)
    result.selLimit = doBindParams(node.selLimit, params, idx)
    result.selOffset = doBindParams(node.selOffset, params, idx)
  of nkInsert:
    result = Node(kind: nkInsert, insTarget: node.insTarget,
                  line: node.line, col: node.col)
    result.insFields = node.insFields
    result.insValues = @[]
    for v in node.insValues:
      result.insValues.add(doBindParams(v, params, idx))
    result.insReturning = node.insReturning
  of nkUpdate:
    result = Node(kind: nkUpdate, updTarget: node.updTarget,
                  updAlias: node.updAlias, line: node.line, col: node.col)
    result.updSet = @[]
    for s in node.updSet:
      var ns = Node(kind: nkBinOp, binOp: s.binOp, line: s.line, col: s.col)
      ns.binLeft = s.binLeft
      ns.binRight = doBindParams(s.binRight, params, idx)
      result.updSet.add(ns)
    result.updWhere = doBindParams(node.updWhere, params, idx)
    result.updReturning = node.updReturning
  of nkWhere:
    result = Node(kind: nkWhere, line: node.line, col: node.col)
    result.whereExpr = doBindParams(node.whereExpr, params, idx)
  of nkHaving:
    result = Node(kind: nkHaving, line: node.line, col: node.col)
    result.havingExpr = doBindParams(node.havingExpr, params, idx)
  of nkLimit:
    result = Node(kind: nkLimit, line: node.line, col: node.col)
    result.limitExpr = doBindParams(node.limitExpr, params, idx)
  of nkOffset:
    result = Node(kind: nkOffset, line: node.line, col: node.col)
    result.offsetExpr = doBindParams(node.offsetExpr, params, idx)
  of nkReturning:
    result = Node(kind: nkReturning, line: node.line, col: node.col)
    result.retExprs = @[]
    for e in node.retExprs:
      result.retExprs.add(doBindParams(e, params, idx))
  of nkDelete:
    result = Node(kind: nkDelete, delTarget: node.delTarget,
                  delAlias: node.delAlias, line: node.line, col: node.col)
    result.delWhere = doBindParams(node.delWhere, params, idx)
    result.delReturning = node.delReturning
  else:
    result = node

proc bindParams*(node: Node, params: seq[WireValue]): Node =
  var idx = 0
  result = doBindParams(node, params, idx)

# ----------------------------------------------------------------------
# High-level execute
# ----------------------------------------------------------------------

proc executeQuery*(ctx: ExecutionContext, astNode: Node, params: seq[WireValue] = @[]): ExecResult =
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
            let anchorRes = executeQuery(ctx, innerLeft)
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
              let rightRes = executeQuery(ctx, innerRight)

              ctx.cteTables = savedCte

              var newRows: seq[Row] = @[]
              if not cteQuery.setOpAll:
                # UNION: deduplicate against all already-accumulated rows
                var seen = initTable[string, bool]()
                for existing in allRows:
                  let key = if "$value" in existing: existing["$value"] else: $existing
                  if key.len > 0:
                    seen[key] = true
                for row in rightRes.rows:
                  let key = if "$value" in row: row["$value"] else: $row
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
            let cteRes = executeQuery(ctx, inner)
            var cteRows: seq[Row] = @[]
            for row in cteRes.rows:
              cteRows.add(row)
            ctx.cteTables[cteName] = cteRows
        else:
          var inner = Node(kind: nkStatementList, stmts: @[])
          inner.stmts.add(cteQuery)
          let cteRes = executeQuery(ctx, inner)
          var cteRows: seq[Row] = @[]
          for row in cteRes.rows:
            cteRows.add(row)
          ctx.cteTables[cteName] = cteRows

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
                  rows.add(parseRowData(cast[string](val)))
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
                  rows.add(parseRowData(cast[string](val)))
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
                    var row = initTable[string, string]()
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
                    rows.add(parseRowData(cast[string](val)))
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
                    rows.add(parseRowData(cast[string](val)))
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

  of nkSetOp:
    # Execute left and right queries
    var innerLeft = Node(kind: nkStatementList, stmts: @[])
    innerLeft.stmts.add(stmt.setOpLeft)
    let leftRes = executeQuery(ctx, innerLeft)

    var innerRight = Node(kind: nkStatementList, stmts: @[])
    innerRight.stmts.add(stmt.setOpRight)
    let rightRes = executeQuery(ctx, innerRight)

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
          seen[row["$value"]] = true
        for row in rightRes.rows:
          if not seen.getOrDefault(row["$value"], false):
            seen[row["$value"]] = true
            rows.add(row)

    of sdkIntersect:
      var leftSet: Table[string, bool]
      for row in leftRes.rows:
        leftSet[row["$value"]] = true
      for row in rightRes.rows:
        if leftSet.getOrDefault(row["$value"], false):
          rows.add(row)
          if not stmt.setOpAll:
            leftSet.del(row["$value"])  # remove to prevent duplicates for INTERSECT (not ALL)

    of sdkExcept:
      var rightSet: Table[string, bool]
      for row in rightRes.rows:
        rightSet[row["$value"]] = true
      for row in leftRes.rows:
        if not rightSet.getOrDefault(row["$value"], false):
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

    # Fire BEFORE INSERT triggers
    var row = initTable[string, string]()
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
    return okResult(affected=count, kvPairs=kvPairs)

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
    var kvPairs: seq[(string, seq[byte])]
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
        # Fire BEFORE UPDATE triggers
        var oldRow = row
        var newRow = row
        for col, val in sets:
          newRow[col] = val
        fireTriggers(ctx, stmt.updTarget, "before", "update", oldRow)

        count += execUpdateRow(ctx, stmt.updTarget, row["$key"], sets, kvPairs)

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
        if evalExpr(whereExpr, row) != "true": continue
      if "$key" in row:
        let old = row["$key"]
        # Fire BEFORE DELETE triggers
        fireTriggers(ctx, stmt.delTarget, "before", "delete", row)

        count += execDelete(ctx, stmt.delTarget, row["$key"], kvPairs)

        # Fire AFTER DELETE triggers
        fireTriggers(ctx, stmt.delTarget, "after", "delete", row)

        if ctx.onChange != nil:
          ctx.onChange(ChangeEvent(table: stmt.delTarget, kind: ckDelete, key: old, data: ""))
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
      var kvPairs: seq[(string, seq[byte])]
      for key, version in ctx.pendingTxn.writeSet:
        if version.value == @[]: ctx.db.delete(key)
        else: ctx.db.put(key, version.value)
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
    let viewDdl = "CREATE VIEW " & stmt.cvName & " AS " & viewSql
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
    let trigDdl = "CREATE TRIGGER " & stmt.trigName & " ON " & stmt.trigTable & " " &
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

    let (found, upBody, downBody) = getMigrationBody(ctx, stmt.amName)
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
      var row = initTable[string, string]()
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
      let (found, upBody, downBody) = getMigrationBody(ctx, name)
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
      let (found, upBody, downBody) = getMigrationBody(ctx, name)
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
      var docId: uint64 = 0
      for row in rows:
        for col in stmt.ciColumns:
          let text = if col in row: row[col] else: ""
          if text.len > 0:
            ftsIdx.addDocument(docId, text)
        let lsmKey = if "$key" in row: row["$key"] else: ""
        docId += 1
      ctx.ftsIndexes[colKey] = ftsIdx
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING FTS")

    ctx.btrees[colKey] = newBTreeIndex[string, IndexEntry]()
    # Populate index from existing data
    let rows = execScan(ctx, stmt.ciTarget)
    for row in rows:
      var colVals: seq[string] = @[]
      for col in stmt.ciColumns:
        if col in row:
          colVals.add(row[col])
        else:
          colVals.add("")
      let idxVal = colVals.join("|")
      if idxVal.len > 0 and not isNull(idxVal):
        let lsmKey = if "$key" in row: stmt.ciTarget & "." & row["$key"] else: ""
        ctx.btrees[colKey].insert(idxVal, IndexEntry(lsmKey: lsmKey, rowValue: ""))
    return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget)

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
    if found:
      ctx.btrees.del(targetKey)
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
    let userDdl = "CREATE USER " & stmt.cuName & " WITH PASSWORD '" & stmt.cuPassword & "'" &
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
    var polDdl = "CREATE POLICY " & stmt.cpName & " ON " & stmt.cpTable
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

  else:
    return errResult("Unsupported statement type: " & $stmt.kind)


proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult =
  let tokens = qlex.tokenize(sql)
  let astNode = qpar.parse(tokens)
  if astNode.stmts.len > 0:
    return executeQuery(ctx, astNode)
  return okResult(msg="Empty migration body")
