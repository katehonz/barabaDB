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
import std/random
import std/monotimes
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
import ../vector/engine as vengine

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
    vectorIndexes*: Table[string, vengine.HNSWIndex]  # table.col -> HNSW index
    txnManager*: TxnManager
    pendingTxn*: Transaction
    onChange*: proc(ev: ChangeEvent) {.closure.}
    users*: Table[string, UserDef]
    policies*: Table[string, seq[PolicyDef]]  # table name -> policies
    currentUser*: string
    currentRole*: string
    sessionVars*: Table[string, string]  # session-scoped key/value variables
    autoIncCounters*: Table[string, int64]  # table.col -> next auto-increment value
    sequences*: Table[string, int64]  # sequence name -> current value

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
    autoIncrement*: bool

  Row* = Table[string, string]

  ExecResult* = object
    success*: bool
    columns*: seq[string]
    rows*: seq[Row]
    affectedRows*: int
    message*: string
    keyValuePairs*: seq[(string, seq[byte])]

proc `==`*(a, b: IndexEntry): bool =
  a.lsmKey == b.lsmKey and a.rowValue == b.rowValue

proc okResult*(rows: seq[Row] = @[], cols: seq[string] = @[], affected: int = 0, msg: string = "",
               kvPairs: seq[(string, seq[byte])] = @[]): ExecResult =
  ExecResult(success: true, columns: cols, rows: rows, affectedRows: affected, message: msg,
             keyValuePairs: kvPairs)

proc errResult*(msg: string): ExecResult =
  ExecResult(success: false, columns: @[], rows: @[], affectedRows: 0, message: msg)

# ----------------------------------------------------------------------
# Context management
# ----------------------------------------------------------------------

proc evalNodeToString(node: Node): string
proc restoreSchema(ctx: ExecutionContext)

proc newExecutionContext*(db: LSMTree): ExecutionContext =
  result = ExecutionContext(db: db, tables: initTable[string, TableDef](),
                   btrees: initTable[string, BTreeIndex[string, IndexEntry]](),
                   views: initTable[string, Node](),
                   cteTables: initTable[string, seq[Row]](),
                   ftsIndexes: initTable[string, fts.InvertedIndex](),
                   vectorIndexes: initTable[string, vengine.HNSWIndex](),
                   users: initTable[string, UserDef](),
                   policies: initTable[string, seq[PolicyDef]](),
                   currentUser: "", currentRole: "",
                   sessionVars: initTable[string, string](),
                   autoIncCounters: initTable[string, int64](),
                   sequences: initTable[string, int64](),
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
    return "'" & node.strVal.replace("'", "''") & "'"
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
    if node.funcArgs.len > 0:
      return node.funcName & "(" & exprToSql(node.funcArgs[0]) & ")"
    else:
      return node.funcName & "()"
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
  if node.selFrom != nil and node.selFrom.kind == nkFrom and node.selFrom.fromTable.len > 0:
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
      if j.joinLateral:
        result.add(" " & jkStr & " LATERAL (subquery)")
      else:
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
            colDef.autoIncrement = col.cdAutoIncrement
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
                of "default":
                  if cst.cstDefault != nil:
                    colDef.defaultVal = evalNodeToString(cst.cstDefault)
                of "fkey":
                  colDef.fkTable = cst.cstRefTable
                  colDef.fkColumn = if cst.cstRefColumns.len > 0: cst.cstRefColumns[0] else: ""
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
                   vectorIndexes: ctx.vectorIndexes,
                   users: ctx.users, policies: ctx.policies,
                   txnManager: ctx.txnManager,
                   currentUser: ctx.currentUser, currentRole: ctx.currentRole,
                   sessionVars: ctx.sessionVars,
                   autoIncCounters: ctx.autoIncCounters,
                   sequences: ctx.sequences,
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

proc escapeRowVal(v: string): string =
  v.replace("\\", "\\\\").replace(",", "\\,").replace("=", "\\=")

proc unescapeRowVal(v: string): string =
  result = ""
  var i = 0
  while i < v.len:
    if v[i] == '\\' and i + 1 < v.len:
      case v[i+1]
      of '\\', ',', '=':
        result &= v[i+1]
        i += 2
        continue
      else: discard
    result &= v[i]
    inc i

proc parseRowData(valStr: string): Table[string, string] =
  ## Parse "col1=val1,col2=val2" into a table
  result = initTable[string, string]()
  var i = 0
  var part = ""
  while i < valStr.len:
    if valStr[i] == '\\' and i + 1 < valStr.len:
      part &= valStr[i]
      part &= valStr[i+1]
      i += 2
      continue
    if valStr[i] == ',':
      let eqPos = part.find('=')
      if eqPos >= 0:
        let k = part[0..<eqPos].strip()
        let v = unescapeRowVal(part[eqPos+1..^1].strip())
        result[k] = v
      part = ""
    else:
      part &= valStr[i]
    inc i
  if part.len > 0:
    let eqPos = part.find('=')
    if eqPos >= 0:
      let k = part[0..<eqPos].strip()
      let v = unescapeRowVal(part[eqPos+1..^1].strip())
      result[k] = v

proc executePlan*(ctx: ExecutionContext, plan: IRPlan): seq[Row]

proc parseVectorString*(value: string): seq[float32] =
  ## Parse a vector string like "[1.0, 2.0, 3.0]" into seq[float32]
  result = @[]
  var cleaned = value.strip()
  if cleaned.len == 0: return result
  if cleaned.startsWith("[") and cleaned.endsWith("]"):
    cleaned = cleaned[1..^2]
  elif cleaned.startsWith("(") and cleaned.endsWith(")"):
    cleaned = cleaned[1..^2]
  for part in cleaned.split(","):
    let p = part.strip()
    if p.len > 0:
      try:
        result.add(parseFloat(p).float32)
      except:
        discard

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
    let srcVal = evalExpr(expr.jpExpr, row, ctx)
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
    let left = evalExpr(expr.binLeft, row, ctx)
    let right = evalExpr(expr.binRight, row, ctx)
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
      proc escapeRe(s: string): string =
        result = ""
        for ch in s:
          case ch
          of '\\', '.', '*', '+', '?', '|', '^', '$', '(', ')', '[', ']', '{', '}':
            result &= "\\" & ch
          else:
            result &= ch
      let pattern = "^" & escapeRe(right).replace("%", ".*").replace("_", ".") & "$"
      try:
        let rePattern = re(pattern)
        if left.match(rePattern): return "true"
      except: discard
      return "false"
    of irILike:
      proc escapeRe(s: string): string =
        result = ""
        for ch in s:
          case ch
          of '\\', '.', '*', '+', '?', '|', '^', '$', '(', ')', '[', ']', '{', '}':
            result &= "\\" & ch
          else:
            result &= ch
      let pattern = "^" & escapeRe(right.toLower()).replace("%", ".*").replace("_", ".") & "$"
      try:
        let rePattern = re(pattern)
        if left.toLower().match(rePattern): return "true"
      except: discard
      return "false"
    of irIn:
      if expr.binRight.kind == irekSubquery:
        let subRows = executePlan(ctx, expr.binRight.subqueryPlan)
        for row in subRows:
          for k, v in row:
            if k.startsWith("$"): continue
            if v == left: return "true"
        return "false"
      try:
        let lv = parseFloat(left)
        let rv = parseFloat(right)
        return if lv == rv: "true" else: "false"
      except: discard
      return if left == right: "true" else: "false"
    of irNotIn:
      if expr.binRight.kind == irekSubquery:
        let subRows = executePlan(ctx, expr.binRight.subqueryPlan)
        for row in subRows:
          for k, v in row:
            if k.startsWith("$"): continue
            if v == left: return "false"
        return "true"
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
    of irDistance:
      let vecA = parseVectorString(left)
      let vecB = parseVectorString(right)
      if vecA.len == 0 or vecB.len == 0:
        return "0"
      return $vengine.euclideanDistance(vecA, vecB)
    of irJsonContains:
      # Check if left JSON contains right JSON
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JObject:
          for key, val in rightNode:
            if not leftNode.hasKey(key) or $(leftNode[key]) != $val:
              return "false"
          return "true"
        elif leftNode.kind == JArray and rightNode.kind == JArray:
          for ritem in rightNode:
            var found = false
            for litem in leftNode:
              if $(litem) == $(ritem):
                found = true
                break
            if not found:
              return "false"
          return "true"
        else:
          return if $(leftNode) == $(rightNode): "true" else: "false"
      except:
        return "false"
    of irJsonContainedBy:
      # Check if left JSON is contained by right JSON (reverse of contains)
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JObject:
          for key, val in leftNode:
            if not rightNode.hasKey(key) or $(rightNode[key]) != $val:
              return "false"
          return "true"
        elif leftNode.kind == JArray and rightNode.kind == JArray:
          for litem in leftNode:
            var found = false
            for ritem in rightNode:
              if $(ritem) == $(litem):
                found = true
                break
            if not found:
              return "false"
          return "true"
        else:
          return if $(leftNode) == $(rightNode): "true" else: "false"
      except:
        return "false"
    of irJsonHasAny:
      # Check if JSON object has any of the keys in right array
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JArray:
          for key in rightNode:
            if key.kind == JString and leftNode.hasKey(key.getStr()):
              return "true"
        return "false"
      except:
        return "false"
    of irJsonHasAll:
      # Check if JSON object has all of the keys in right array
      try:
        let leftNode = parseJson(left)
        let rightNode = parseJson(right)
        if leftNode.kind == JObject and rightNode.kind == JArray:
          for key in rightNode:
            if key.kind == JString and not leftNode.hasKey(key.getStr()):
              return "false"
          return "true"
        return "false"
      except:
        return "false"
    else: return "false"
  of irekUnary:
    case expr.unOp
    of irNot:
      let v = evalExpr(expr.unExpr, row, ctx)
      return if v == "true": "false" else: "true"
    of irIsNull:
      let v = evalExpr(expr.unExpr, row, ctx)
      return if isNull(v): "true" else: "false"
    of irIsNotNull:
      let v = evalExpr(expr.unExpr, row, ctx)
      return if not isNull(v): "true" else: "false"
    of irNeg:
      let v = evalExpr(expr.unExpr, row, ctx)
      try:
        let f = -parseFloat(v)
        let s = $f
        if s.endsWith(".0"):
          return s[0..^3]
        return s
      except: return "0"
    else: return "false"
  of irekFuncCall:
    let fn = expr.irFunc.toLower()
    case fn
    of "cosine_distance", "euclidean_distance", "inner_product", "l2_distance", "l1_distance":
      if expr.irFuncArgs.len < 2:
        return "0"
      let left = evalExpr(expr.irFuncArgs[0], row, ctx)
      let right = evalExpr(expr.irFuncArgs[1], row, ctx)
      let vecA = parseVectorString(left)
      let vecB = parseVectorString(right)
      if vecA.len == 0 or vecB.len == 0:
        return "0"
      var dist: float64 = 0.0
      case fn
      of "cosine_distance": dist = vengine.cosineDistance(vecA, vecB)
      of "euclidean_distance", "l2_distance": dist = vengine.euclideanDistance(vecA, vecB)
      of "inner_product": dist = -vengine.dotProduct(vecA, vecB)
      of "l1_distance": dist = vengine.manhattanDistance(vecA, vecB)
      else: dist = 0.0
      return $dist
    of "vector_dims", "vector_dimension":
      if expr.irFuncArgs.len < 1:
        return "0"
      let arg = evalExpr(expr.irFuncArgs[0], row, ctx)
      return $parseVectorString(arg).len
    of "json_has_key":
      if expr.irFuncArgs.len < 2:
        return "false"
      let jsonStr = evalExpr(expr.irFuncArgs[0], row, ctx)
      let key = evalExpr(expr.irFuncArgs[1], row, ctx)
      try:
        let node = parseJson(jsonStr)
        if node.kind == JObject:
          return if node.hasKey(key): "true" else: "false"
        elif node.kind == JArray:
          try:
            let idx = parseInt(key)
            return if idx >= 0 and idx < node.len: "true" else: "false"
          except:
            return "false"
        return "false"
      except:
        return "false"
    of "current_setting":
      if expr.irFuncArgs.len < 1:
        return ""
      let key = evalExpr(expr.irFuncArgs[0], row, ctx)
      if ctx != nil and key in ctx.sessionVars:
        return ctx.sessionVars[key]
      return ""
    of "current_user":
      if ctx != nil: return ctx.currentUser
      return ""
    of "current_role":
      if ctx != nil: return ctx.currentRole
      return ""
    of "datetime":
      if expr.irFuncArgs.len > 0:
        let arg = evalExpr(expr.irFuncArgs[0], row, ctx).toLower()
        if arg == "now":
          return $now().format("yyyy-MM-dd HH:mm:ss")
        return arg
      return $now().format("yyyy-MM-dd HH:mm:ss")
    of "now":
      return $now().format("yyyy-MM-dd HH:mm:ss")
    of "gen_random_uuid", "uuid":
      # Generate UUID v4
      var uuidStr = ""
      for i in 0..<36:
        if i in @[8, 13, 18, 23]:
          uuidStr.add('-')
        elif i == 14:
          uuidStr.add('4')
        elif i == 19:
          uuidStr.add(['8', '9', 'a', 'b'][rand(3)])
        else:
          uuidStr.add("0123456789abcdef"[rand(15)])
      return uuidStr
    of "nextval":
      if expr.irFuncArgs.len < 1:
        return "0"
      if ctx == nil: return "0"
      let seqName = evalExpr(expr.irFuncArgs[0], row, ctx)
      var val: int64 = 0
      if seqName in ctx.sequences:
        val = ctx.sequences[seqName]
      val += 1
      ctx.sequences[seqName] = val
      return $val
    of "currval":
      if expr.irFuncArgs.len < 1:
        return "0"
      if ctx == nil: return "0"
      let seqName = evalExpr(expr.irFuncArgs[0], row, ctx)
      if seqName in ctx.sequences:
        return $ctx.sequences[seqName]
      return "0"
    of "snowflake_id":
      # Snowflake ID: timestamp_ms(41 bits) | node_id(10 bits) | sequence(12 bits)
      var nodeId: int64 = 0
      if expr.irFuncArgs.len > 0:
        try: nodeId = parseInt(evalExpr(expr.irFuncArgs[0], row, ctx))
        except: nodeId = 0
      nodeId = nodeId and 0x3FF  # 10 bits
      let ts = int64(epochTime() * 1000) and 0x1FFFFFFFFFF  # 41 bits
      var snowSeq = int64(getMonoTime().ticks() and 0xFFF)  # 12 bits from monotonic
      let snowflakeId = (ts shl 22) or (nodeId shl 12) or snowSeq
      return $snowflakeId
    of "strftime":
      if expr.irFuncArgs.len >= 2:
        let fmt = evalExpr(expr.irFuncArgs[0], row, ctx)
        let val = evalExpr(expr.irFuncArgs[1], row, ctx)
        if fmt == "%s":
          try:
            let dt = parse(val, "yyyy-MM-dd HH:mm:ss")
            return $(dt.toTime().toUnix())
          except:
            return "0"
        elif fmt == "%Y-%m-%dT%H:%M:%SZ":
          try:
            let dt = parse(val, "yyyy-MM-dd HH:mm:ss")
            return format(dt, "yyyy-MM-dd'T'HH:mm:ss'Z'")
          except:
            return ""
      return ""
    else:
      # Unknown function: try to evaluate args and return first arg as fallback
      if expr.irFuncArgs.len > 0:
        return evalExpr(expr.irFuncArgs[0], row, ctx)
      return ""
  of irekCast:
    let val = evalExpr(expr.irCastExpr, row, ctx)
    let castType = expr.irCastType.name.toLower()
    if castType.startsWith("vector"):
      let vec = parseVectorString(val)
      return "[" & vec.mapIt($it).join(", ") & "]"
    return val
  of irekExists:
    if ctx != nil:
      let rows = executePlan(ctx, expr.existsSubquery)
      return if rows.len > 0: "true" else: "false"
    return "false"
  of irekAggregate:
    # Look up pre-computed aggregate from group row
    let prefix = "$agg_" & $expr.aggOp & "_"
    for k, v in row:
      if k.startsWith(prefix):
        return v
    return ""
  else: return ""

proc lowerExpr*(node: Node): IRExpr
proc lowerSelect*(node: Node): IRPlan

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
      if evalExpr(expr, row, ctx) != "true":
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
      if evalExpr(expr, row, ctx) != "true":
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
  for (key, value) in ctx.db.scanAll():
    if not key.startsWith(prefix): continue
    let rest = key[prefix.len..^1]
    var row: Table[string, string]
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
          key = f & "=" & escapeRowVal(rowVals[i])
          keyFound = true
        else:
          valParts.add(f & "=" & escapeRowVal(rowVals[i]))
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

    # Update Vector indexes
    for vecKey, vecIdx in ctx.vectorIndexes:
      if vecKey.startsWith(table & "."):
        let colName = vecKey[table.len + 1..^1]
        let vecStr = getValue(rowVals, fields, colName)
        let vec = parseVectorString(vecStr)
        if vec.len > 0:
          var docId: uint64 = 0
          for ch in fullKey:
            docId = docId * 31 + uint64(ord(ch))
          var meta = initTable[string, string]()
          meta["key"] = fullKey
          vengine.insert(vecIdx, docId, vec, meta)

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
    # Update BTree indexes
    for colName in ctx.btrees.keys.toSeq():
      if colName.startsWith(table & "."):
        let colsPart = colName[table.len + 1..^1]
        let idxCols = colsPart.split(".")
        var oldVals: seq[string] = @[]
        for c in idxCols:
          if c in oldRow:
            oldVals.add(oldRow[c])
          else:
            oldVals.add("")
        let oldIdxVal = oldVals.join("|")
        if oldIdxVal.len > 0 and not isNull(oldIdxVal):
          ctx.btrees[colName].remove(oldIdxVal, IndexEntry(lsmKey: fullKey, rowValue: cast[string](existingVal)))
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
    parts.add(col & "=" & escapeRowVal(val))
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
      let oldIdxVal = oldVals.join("|")
      if oldIdxVal.len > 0 and not isNull(oldIdxVal):
        ctx.btrees[colName].remove(oldIdxVal, IndexEntry(lsmKey: fullKey, rowValue: cast[string](existing)))
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
  # Update Vector indexes: add new vector (no remove support in current HNSW)
  for vecKey, vecIdx in ctx.vectorIndexes:
    if vecKey.startsWith(table & "."):
      let colName = vecKey[table.len + 1..^1]
      let vecStr = if colName in parsed: parsed[colName] else: ""
      let vec = parseVectorString(vecStr)
      if vec.len > 0:
        var docId: uint64 = 0
        for ch in fullKey:
          docId = docId * 31 + uint64(ord(ch))
        var meta = initTable[string, string]()
        meta["key"] = fullKey
        vengine.insert(vecIdx, docId, vec, meta)
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
      except:
        expectedDim = 0
    if expectedDim > 0 and vec.len != expectedDim:
      return (false, "Vector dimension mismatch: expected " & $expectedDim & " but got " & $vec.len)
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

    # PK uniqueness (skip during UPDATE — PK shouldn't change)
    if not skipPkCheck and tbl.pkColumns.len > 0:
      var pkVals: seq[string] = @[]
      for pkCol in tbl.pkColumns:
        pkVals.add(getValue(rowVals, fields, pkCol))
      let pkStr = pkVals.join("|")
      # Check with field=value format (as stored by execInsert)
      var pkKey = tableName & "." & tbl.pkColumns[0] & "=" & escapeRowVal(pkVals[0])
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
        let checkResult = evalExpr(checkExpr, row, ctx)
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
  of nkCurrentUser:
    result = IRExpr(kind: irekFuncCall)
    result.irFunc = "current_user"
    result.irFuncArgs = @[]
  of nkCurrentRole:
    result = IRExpr(kind: irekFuncCall)
    result.irFunc = "current_role"
    result.irFuncArgs = @[]
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
    of bkDistance: irOp = irDistance
    of bkJsonContains: irOp = irJsonContains
    of bkJsonContainedBy: irOp = irJsonContainedBy
    of bkJsonHasAny: irOp = irJsonHasAny
    of bkJsonHasAll: irOp = irJsonHasAll
    else: irOp = irEq
    result.binOp = irOp
    result.binLeft = lowerExpr(node.binLeft)
    result.binRight = lowerExpr(node.binRight)
  of nkUnaryOp:
    result = IRExpr(kind: irekUnary)
    result.unOp = if node.unOp == ukNot: irNot else: irNeg
    result.unExpr = lowerExpr(node.unOperand)
  of nkFuncCall:
    case node.funcName.toLower()
    of "count", "sum", "avg", "min", "max", "array_agg", "string_agg":
      result = IRExpr(kind: irekAggregate)
      case node.funcName.toLower()
      of "count": result.aggOp = irCount
      of "sum": result.aggOp = irSum
      of "avg": result.aggOp = irAvg
      of "min": result.aggOp = irMin
      of "max": result.aggOp = irMax
      of "array_agg": result.aggOp = irArrayAgg
      of "string_agg": result.aggOp = irStringAgg
      else: discard
      result.aggArgs = @[]
      for arg in node.funcArgs: result.aggArgs.add(lowerExpr(arg))
      if node.funcFilter != nil:
        result.aggFilter = lowerExpr(node.funcFilter)
    else:
      result = IRExpr(kind: irekFuncCall)
      result.irFunc = node.funcName
      result.irFuncArgs = @[]
      for arg in node.funcArgs: result.irFuncArgs.add(lowerExpr(arg))
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
    elif node.inRight.kind == nkSubquery:
      result = IRExpr(kind: irekBinary)
      result.binOp = irIn
      result.binLeft = lowerExpr(node.inLeft)
      result.binRight = IRExpr(kind: irekSubquery)
      result.binRight.subqueryPlan = lowerSelect(node.inRight.subQuery)
    else:
      result = IRExpr(kind: irekBinary)
      result.binOp = irEq
      result.binLeft = lowerExpr(node.inLeft)
      result.binRight = lowerExpr(node.inRight)
  of nkExists:
    result = IRExpr(kind: irekExists)
  of nkStar:
    result = IRExpr(kind: irekStar)
  of nkWindowExpr:
    result = IRExpr(kind: irekWindowFunc)
    result.wfName = node.winFunc
    result.wfArgs = @[]
    for arg in node.winArgs: result.wfArgs.add(lowerExpr(arg))
    result.wfPartition = @[]
    if node.winOver != nil:
      for part in node.winOver.overPartition:
        result.wfPartition.add(lowerExpr(part))
      result.wfOrderBy = @[]
      result.wfOrderDirs = @[]
      for ob in node.winOver.overOrderBy:
        result.wfOrderBy.add(lowerExpr(ob.orderByExpr))
        result.wfOrderDirs.add(ob.orderByDir == sdDesc)
      if node.winOver.overFrame != nil:
        result.wfFrameMode = node.winOver.overFrame.frameMode
        result.wfFrameStart = node.winOver.overFrame.frameStartType
        result.wfFrameEnd = node.winOver.overFrame.frameEndType
      else:
        result.wfFrameMode = "ROWS"
        result.wfFrameStart = "UNBOUNDED PRECEDING"
        result.wfFrameEnd = "CURRENT ROW"
  else:
    result = IRExpr(kind: irekLiteral, literal: IRLiteral(kind: vkNull))

proc evalNodeToString(node: Node): string =
  ## Evaluate a simple AST node to a string value for INSERT/UPDATE.
  let ir = lowerExpr(node)
  return evalExpr(ir, initTable[string, string](), nil)

proc lowerSelect*(node: Node): IRPlan =
  result = IRPlan(kind: irpkScan)
  if node.selFrom != nil:
    if node.selFrom.kind == nkPivot:
      # PIVOT: source PIVOT (agg(val) FOR col IN ('v1', 'v2'))
      let pivotSrc = node.selFrom.pivotSource
      var pivotSource: IRPlan
      if pivotSrc.kind == nkFrom and pivotSrc.fromSubquery != nil:
        pivotSource = lowerSelect(pivotSrc.fromSubquery)
      elif pivotSrc.kind == nkFrom:
        pivotSource = IRPlan(kind: irpkScan)
        pivotSource.scanTable = pivotSrc.fromTable
        pivotSource.scanAlias = pivotSrc.fromAlias
      else:
        pivotSource = lowerSelect(Node(kind: nkSelect, selFrom: pivotSrc,
                                        selResult: @[Node(kind: nkStar)],
                                        selJoins: @[], selGroupBy: @[],
                                        line: node.line, col: node.col))
      let pivotPlan = IRPlan(kind: irpkPivot)
      pivotPlan.pivotSource = pivotSource
      pivotPlan.pivotAgg = lowerExpr(node.selFrom.pivotAgg)
      pivotPlan.pivotForCol = node.selFrom.pivotForCol
      pivotPlan.pivotInValues = node.selFrom.pivotInValues
      result = pivotPlan
    elif node.selFrom.kind == nkUnpivot:
      let unpivotSource = lowerSelect(Node(kind: nkSelect, selFrom: node.selFrom.unpivotSource,
                                            selResult: @[Node(kind: nkStar)],
                                            selJoins: @[], selGroupBy: @[],
                                            line: node.line, col: node.col))
      let unpivotPlan = IRPlan(kind: irpkUnpivot)
      unpivotPlan.unpivotSource = unpivotSource
      unpivotPlan.unpivotValueCol = node.selFrom.unpivotValueCol
      unpivotPlan.unpivotForCol = node.selFrom.unpivotForCol
      unpivotPlan.unpivotInCols = node.selFrom.unpivotInCols
      result = unpivotPlan
    elif node.selFrom.kind == nkGraphTraversal:
      let graphPlan = IRPlan(kind: irpkGraphTraversal)
      graphPlan.graphName = node.selFrom.gtGraphName
      graphPlan.graphAlgo = "bfs"
      graphPlan.graphEdgeLabel = node.selFrom.gtEdge
      graphPlan.graphMaxDepth = node.selFrom.gtMaxDepth
      graphPlan.graphReturnCols = node.selFrom.gtReturnCols
      result = graphPlan
    elif node.selFrom.fromTable.len > 0:
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
      joinPlan.joinLateral = joinNode.joinLateral
      joinPlan.joinLeft = result
      if joinNode.joinLateral and joinNode.joinTarget != nil and joinNode.joinTarget.kind == nkSubquery:
        # LATERAL: right side is a full subquery plan
        joinPlan.joinRight = lowerSelect(joinNode.joinTarget.subQuery)
      else:
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

  if node.selGroupBy.len > 0 or node.selGroupingSetsKind != gskNone:
    let groupPlan = IRPlan(kind: irpkGroupBy)
    groupPlan.groupSource = result
    groupPlan.groupKeys = @[]
    for g in node.selGroupBy: groupPlan.groupKeys.add(lowerExpr(g))
    # Collect aggregate expressions from SELECT list
    groupPlan.groupAggs = @[]
    for e in node.selResult:
      let lowered = lowerExpr(e)
      if lowered.kind == irekAggregate:
        groupPlan.groupAggs.add(lowered)
    if node.selHaving != nil:
      groupPlan.groupHaving = lowerExpr(node.selHaving.havingExpr)
    # Handle grouping sets
    case node.selGroupingSetsKind
    of gskNone:
      groupPlan.groupingSetsKind = irgskNone
    of gskGroupingSets:
      groupPlan.groupingSetsKind = irgskGroupingSets
      groupPlan.groupingSets = @[]
      for s in node.selGroupingSets:
        var setExprs: seq[IRExpr] = @[]
        for e in s: setExprs.add(lowerExpr(e))
        groupPlan.groupingSets.add(setExprs)
    of gskRollup:
      groupPlan.groupingSetsKind = irgskRollup
    of gskCube:
      groupPlan.groupingSetsKind = irgskCube
    result = groupPlan

  if node.selOrderBy.len > 0:
    let sortPlan = IRPlan(kind: irpkSort)
    sortPlan.sortSource = result
    sortPlan.sortExprs = @[]
    sortPlan.sortDirs = @[]
    for o in node.selOrderBy:
      sortPlan.sortExprs.add(lowerExpr(o.orderByExpr))
      sortPlan.sortDirs.add(o.orderByDir == sdAsc)
    result = sortPlan

  let projectPlan = IRPlan(kind: irpkProject)
  projectPlan.projectSource = result
  projectPlan.projectExprs = @[]
  projectPlan.projectAliases = @[]
  for i, e in node.selResult:
    projectPlan.projectExprs.add(lowerExpr(e))
    if e.exprAlias.len > 0:
      projectPlan.projectAliases.add(e.exprAlias)
    elif e.kind == nkIdent:
      projectPlan.projectAliases.add(e.identName)
    elif e.kind == nkPath and e.pathParts.len > 0:
      projectPlan.projectAliases.add(e.pathParts.join("."))
    elif e.kind == nkFuncCall:
      var aliasArgs: seq[string] = @[]
      for arg in e.funcArgs:
        aliasArgs.add(exprToSql(arg))
      projectPlan.projectAliases.add(e.funcName & "(" & aliasArgs.join(", ") & ")")
    elif e.kind == nkStar:
      projectPlan.projectAliases.add("*")
    else:
      projectPlan.projectAliases.add("col" & $i)
  result = projectPlan

  if node.selLimit != nil or node.selOffset != nil:
    let limitPlan = IRPlan(kind: irpkLimit)
    limitPlan.limitSource = result
    limitPlan.limitCount = if node.selLimit != nil and node.selLimit.limitExpr.kind == nkIntLit:
      node.selLimit.limitExpr.intVal else: 0
    limitPlan.limitOffset = if node.selOffset != nil and node.selOffset.offsetExpr.kind == nkIntLit:
      node.selOffset.offsetExpr.intVal else: 0
    result = limitPlan

# ----------------------------------------------------------------------
# Window Function Computation
# ----------------------------------------------------------------------

proc partitionKey(row: Row, partExprs: seq[IRExpr], ctx: ExecutionContext = nil): string =
  ## Compute a string partition key for a row
  result = ""
  for expr in partExprs:
    result &= evalExpr(expr, row, ctx) & "|"

proc compareRowsByOrder(a, b: Row, orderExprs: seq[IRExpr], orderDirs: seq[bool], ctx: ExecutionContext = nil): int =
  ## Compare two rows by their ORDER BY expressions
  for i, expr in orderExprs:
    let va = evalExpr(expr, a, ctx)
    let vb = evalExpr(expr, b, ctx)
    var cmpRes = 0
    try:
      let fa = parseFloat(va)
      let fb = parseFloat(vb)
      if fa < fb: cmpRes = -1
      elif fa > fb: cmpRes = 1
    except:
      cmpRes = cmp(va, vb)
    if cmpRes != 0:
      return if orderDirs.len > i and orderDirs[i]: -cmpRes else: cmpRes
  return 0

proc resolveFrameBounds(pos, partLen: int, frameStart, frameEnd: string): (int, int) =
  ## Resolve frame boundaries for ROWS mode.
  ## Returns (startPos, endPos) inclusive within the partition.
  var startPos = 0
  var endPos = partLen - 1

  # Parse start boundary
  if frameStart == "UNBOUNDED PRECEDING":
    startPos = 0
  elif frameStart == "CURRENT ROW":
    startPos = pos
  elif frameStart.endsWith(" PRECEDING"):
    let nStr = frameStart[0..^11]
    var n = 0
    try: n = parseInt(nStr) except: n = 0
    startPos = max(0, pos - n)
  elif frameStart.endsWith(" FOLLOWING"):
    let nStr = frameStart[0..^11]
    var n = 0
    try: n = parseInt(nStr) except: n = 0
    startPos = min(partLen - 1, pos + n)

  # Parse end boundary
  if frameEnd == "UNBOUNDED FOLLOWING":
    endPos = partLen - 1
  elif frameEnd == "CURRENT ROW":
    endPos = pos
  elif frameEnd.endsWith(" PRECEDING"):
    let nStr = frameEnd[0..^11]
    var n = 0
    try: n = parseInt(nStr) except: n = 0
    endPos = max(0, pos - n)
  elif frameEnd.endsWith(" FOLLOWING"):
    let nStr = frameEnd[0..^11]
    var n = 0
    try: n = parseInt(nStr) except: n = 0
    endPos = min(partLen - 1, pos + n)

  if startPos > endPos:
    startPos = endPos
  return (startPos, endPos)

proc computeWindowValues*(rows: seq[Row], expr: IRExpr, ctx: ExecutionContext = nil): seq[string] =
  ## Compute a window function for all rows, returning a value per row.
  ## The expr must be of kind irekWindowFunc.
  result = newSeq[string](rows.len)
  if rows.len == 0: return

  let wfName = expr.wfName.toLower()
  let frameStart = expr.wfFrameStart
  let frameEnd = expr.wfFrameEnd

  # Partition rows
  var groups = initTable[string, seq[int]]()
  for i, row in rows:
    let pk = partitionKey(row, expr.wfPartition, ctx)
    if pk notin groups:
      groups[pk] = @[]
    groups[pk].add(i)

  # For each partition, sort by ORDER BY
  for pk, idxs in groups:
    var sortedIdxs = idxs
    sortedIdxs.sort(proc(a, b: int): int =
      compareRowsByOrder(rows[a], rows[b], expr.wfOrderBy, expr.wfOrderDirs, ctx)
    )

    case wfName
    of "row_number":
      for pos, rowIdx in sortedIdxs:
        result[rowIdx] = $(pos + 1)
    of "rank":
      var currentRank = 1
      for pos, rowIdx in sortedIdxs:
        if pos > 0:
          let cmpRes = compareRowsByOrder(rows[sortedIdxs[pos - 1]], rows[rowIdx], expr.wfOrderBy, expr.wfOrderDirs, ctx)
          if cmpRes != 0:
            currentRank = pos + 1
        result[rowIdx] = $currentRank
    of "dense_rank":
      var currentRank = 1
      for pos, rowIdx in sortedIdxs:
        if pos > 0:
          let cmpRes = compareRowsByOrder(rows[sortedIdxs[pos - 1]], rows[rowIdx], expr.wfOrderBy, expr.wfOrderDirs, ctx)
          if cmpRes != 0:
            currentRank += 1
        result[rowIdx] = $currentRank
    of "ntile":
      var n = 1
      if expr.wfArgs.len > 0:
        try: n = parseInt(evalExpr(expr.wfArgs[0], rows[sortedIdxs[0]], ctx)) except: n = 1
      if n < 1: n = 1
      let groupSize = sortedIdxs.len div n
      let remainder = sortedIdxs.len mod n
      for pos, rowIdx in sortedIdxs:
        var bucket = 1
        var threshold = groupSize
        if 0 < remainder: threshold += 1
        var cumulative = threshold
        while pos >= cumulative and bucket < n:
          bucket += 1
          threshold = groupSize
          if (bucket - 1) < remainder: threshold += 1
          cumulative += threshold
        result[rowIdx] = $bucket
    of "lead":
      var offset = 1
      var defaultVal = ""
      if expr.wfArgs.len > 1:
        try: offset = parseInt(evalExpr(expr.wfArgs[1], rows[sortedIdxs[0]], ctx)) except: offset = 1
      if expr.wfArgs.len > 2:
        defaultVal = evalExpr(expr.wfArgs[2], rows[sortedIdxs[0]], ctx)
      for pos, rowIdx in sortedIdxs:
        let targetPos = pos + offset
        if targetPos < sortedIdxs.len:
          result[rowIdx] = evalExpr(expr.wfArgs[0], rows[sortedIdxs[targetPos]], ctx)
        else:
          result[rowIdx] = defaultVal
    of "lag":
      var offset = 1
      var defaultVal = ""
      if expr.wfArgs.len > 1:
        try: offset = parseInt(evalExpr(expr.wfArgs[1], rows[sortedIdxs[0]], ctx)) except: offset = 1
      if expr.wfArgs.len > 2:
        defaultVal = evalExpr(expr.wfArgs[2], rows[sortedIdxs[0]], ctx)
      for pos, rowIdx in sortedIdxs:
        let targetPos = pos - offset
        if targetPos >= 0:
          result[rowIdx] = evalExpr(expr.wfArgs[0], rows[sortedIdxs[targetPos]], ctx)
        else:
          result[rowIdx] = defaultVal
    of "first_value":
      for pos, rowIdx in sortedIdxs:
        let (fStart, _) = resolveFrameBounds(pos, sortedIdxs.len, frameStart, frameEnd)
        result[rowIdx] = evalExpr(expr.wfArgs[0], rows[sortedIdxs[fStart]], ctx)
    of "last_value":
      for pos, rowIdx in sortedIdxs:
        let (_, fEnd) = resolveFrameBounds(pos, sortedIdxs.len, frameStart, frameEnd)
        result[rowIdx] = evalExpr(expr.wfArgs[0], rows[sortedIdxs[fEnd]], ctx)
    else:
      # Unknown window function — fill with empty
      for rowIdx in sortedIdxs:
        result[rowIdx] = ""

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
    var sourceRows = executePlan(ctx, plan.projectSource)
    if plan.projectAliases.len == 0: return sourceRows
    # Scalar SELECT (no FROM): create a dummy row so expressions can be evaluated
    if sourceRows.len == 0 and plan.projectSource != nil and
       plan.projectSource.kind == irpkScan and plan.projectSource.scanTable.len == 0:
      sourceRows = @[initTable[string, string]()]

    # Check if this projection contains aggregates without GROUP BY
    var hasAggs = false
    let sourceIsGroupBy = plan.projectSource != nil and plan.projectSource.kind == irpkGroupBy
    for expr in plan.projectExprs:
      if expr != nil and expr.kind == irekAggregate:
        # If source is GroupBy, aggregates are pre-computed in group rows
        if not sourceIsGroupBy:
          hasAggs = true
        break

    # Check if projection contains window functions
    var hasWindowFuncs = false
    for expr in plan.projectExprs:
      if expr != nil and expr.kind == irekWindowFunc:
        hasWindowFuncs = true
        break

    if hasWindowFuncs:
      # Pre-compute window function values for all source rows
      var winValues = newSeq[seq[string]](plan.projectExprs.len)
      for i, expr in plan.projectExprs:
        if expr != nil and expr.kind == irekWindowFunc:
          winValues[i] = computeWindowValues(sourceRows, expr)
      result = @[]
      for rowIdx, row in sourceRows:
        var newRow: Table[string, string]
        for i, alias in plan.projectAliases:
          if i < plan.projectExprs.len:
            let expr = plan.projectExprs[i]
            if expr.kind == irekWindowFunc:
              newRow[alias] = winValues[i][rowIdx]
            elif expr.kind == irekStar:
              for k, v in row:
                if not k.startsWith("$") and not k.contains("."):
                  newRow[k] = v
            else:
              let val = evalExpr(expr, row, ctx)
              if alias.len > 0: newRow[alias] = val
              else: newRow["col" & $i] = val
        if newRow.len > 0:
          result.add(newRow)
        else:
          result.add(row)
      return result

    if hasAggs:
      # Produce exactly one row with aggregate values
      var newRow: Table[string, string]
      for i, alias in plan.projectAliases:
        if i < plan.projectExprs.len:
          let expr = plan.projectExprs[i]
          if expr.kind == irekStar:
            if sourceRows.len > 0:
              for k, v in sourceRows[0]:
                if not k.startsWith("$") and not k.contains("."):
                  newRow[k] = v
          elif expr.kind == irekAggregate:
            # Apply FILTER (WHERE ...) if present
            var filteredRows = sourceRows
            if expr.aggFilter != nil:
              filteredRows = @[]
              for row in sourceRows:
                if evalExpr(expr.aggFilter, row, ctx) == "true":
                  filteredRows.add(row)
            case expr.aggOp
            of irCount:
              if expr.aggArgs.len == 0:
                newRow[alias] = $filteredRows.len
              else:
                var count = 0
                for row in filteredRows:
                  let v = evalExpr(expr.aggArgs[0], row, ctx)
                  if v.len > 0: count += 1
                newRow[alias] = $count
            of irSum:
              var sum = 0.0
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                try: sum += parseFloat(v) except: discard
              newRow[alias] = $sum
            of irAvg:
              var sum = 0.0
              var count = 0
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                try: sum += parseFloat(v); count += 1 except: discard
              newRow[alias] = if count > 0: $(sum / float(count)) else: "0"
            of irMin:
              var minVal = ""
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                if minVal == "" or v < minVal: minVal = v
              newRow[alias] = minVal
            of irMax:
              var maxVal = ""
              for row in filteredRows:
                let v = evalExpr(expr.aggArgs[0], row, ctx)
                if maxVal == "" or v > maxVal: maxVal = v
              newRow[alias] = maxVal
            of irArrayAgg:
              var arr: seq[string]
              for row in filteredRows:
                if expr.aggArgs.len > 0:
                  arr.add(evalExpr(expr.aggArgs[0], row, ctx))
              newRow[alias] = "[" & arr.join(", ") & "]"
            of irStringAgg:
              var parts: seq[string]
              let delim = if expr.aggArgs.len > 1: evalExpr(expr.aggArgs[1], initTable[string, string](), ctx) else: ","
              for row in filteredRows:
                if expr.aggArgs.len > 0:
                  parts.add(evalExpr(expr.aggArgs[0], row, ctx))
              newRow[alias] = parts.join(delim)
          else:
            let val = evalExpr(expr, if sourceRows.len > 0: sourceRows[0] else: initTable[string, string](), ctx)
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
          elif expr.kind == irekAggregate and sourceIsGroupBy:
            # Look up pre-computed aggregate from GroupBy row
            let aggKey = "$agg_" & $expr.aggOp
            var found = false
            for k, v in row:
              if k.startsWith(aggKey):
                if alias.len > 0: newRow[alias] = v
                else: newRow["col" & $i] = v
                found = true
                break
            if not found:
              if alias.len > 0: newRow[alias] = "0"
              else: newRow["col" & $i] = "0"
          else:
            let val = evalExpr(expr, row, ctx)
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
      let va = evalExpr(sortExpr, a, ctx)
      let vb = evalExpr(sortExpr, b, ctx)
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
    if plan.groupKeys.len == 0 and plan.groupingSetsKind == irgskNone: return sourceRows

    # Generate grouping sets
    var groupingSets: seq[seq[IRExpr]]
    case plan.groupingSetsKind
    of irgskNone:
      groupingSets = @[plan.groupKeys]
    of irgskGroupingSets:
      groupingSets = plan.groupingSets
    of irgskRollup:
      # ROLLUP(a, b) => GROUPING SETS ((a, b), (a), ())
      groupingSets = @[]
      for i in countdown(plan.groupKeys.len, 0):
        groupingSets.add(plan.groupKeys[0..<i])
    of irgskCube:
      # CUBE(a, b) => GROUPING SETS ((a, b), (a), (b), ())
      groupingSets = @[@[]]  # start with empty set
      for key in plan.groupKeys:
        var newSets: seq[seq[IRExpr]]
        for s in groupingSets:
          newSets.add(s)
          var s2 = s
          s2.add(key)
          newSets.add(s2)
        groupingSets = newSets

    result = @[]
    for gkeys in groupingSets:
      # Group rows by this set's key values
      var groups = initTable[string, seq[Row]]()
      for row in sourceRows:
        var groupKey = ""
        for gk in gkeys:
          groupKey &= evalExpr(gk, row, ctx) & "|"
        if groupKey notin groups:
          groups[groupKey] = @[]
        groups[groupKey].add(row)
      for gk, groupRows in groups:
        var aggRow: Table[string, string]
        # Populate GROUP BY key columns
        for gkExpr in gkeys:
          if gkExpr.kind == irekField and gkExpr.fieldPath.len > 0:
            aggRow[gkExpr.fieldPath[^1]] = evalExpr(gkExpr, groupRows[0], ctx)
        # Populate non-aggregated columns from first row in group
        if groupRows.len > 0:
          for k, v in groupRows[0]:
            if not k.startsWith("$") and k notin aggRow:
              aggRow[k] = v
        # Compute each aggregate expression
        for aggExpr in plan.groupAggs:
          let aggKey = "$agg_" & $aggExpr.aggOp & "_" & $plan.groupAggs.find(aggExpr)
          var filteredRows = groupRows
          if aggExpr.aggFilter != nil:
            filteredRows = @[]
            for row in groupRows:
              if evalExpr(aggExpr.aggFilter, row, ctx) == "true":
                filteredRows.add(row)
          case aggExpr.aggOp
          of irCount:
            if aggExpr.aggArgs.len == 0:
              aggRow[aggKey] = $filteredRows.len
            else:
              var count = 0
              for row in filteredRows:
                let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
                if v.len > 0: count += 1
              aggRow[aggKey] = $count
          of irSum:
            var sum = 0.0
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              try: sum += parseFloat(v) except: discard
            aggRow[aggKey] = $sum
          of irAvg:
            var sum = 0.0
            var count = 0
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              try: sum += parseFloat(v); count += 1 except: discard
            aggRow[aggKey] = if count > 0: $(sum / float(count)) else: "0"
          of irMin:
            var minVal = ""
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              if minVal == "" or v < minVal: minVal = v
            aggRow[aggKey] = minVal
          of irMax:
            var maxVal = ""
            for row in filteredRows:
              let v = evalExpr(aggExpr.aggArgs[0], row, ctx)
              if maxVal == "" or v > maxVal: maxVal = v
            aggRow[aggKey] = maxVal
          of irArrayAgg:
            var arr: seq[string]
            for row in filteredRows:
              if aggExpr.aggArgs.len > 0:
                arr.add(evalExpr(aggExpr.aggArgs[0], row, ctx))
            aggRow[aggKey] = "[" & arr.join(", ") & "]"
          of irStringAgg:
            var parts: seq[string]
            let delim = if aggExpr.aggArgs.len > 1: evalExpr(aggExpr.aggArgs[1], initTable[string, string](), ctx) else: ","
            for row in filteredRows:
              if aggExpr.aggArgs.len > 0:
                parts.add(evalExpr(aggExpr.aggArgs[0], row, ctx))
            aggRow[aggKey] = parts.join(delim)
        # Apply HAVING filter
        if plan.groupHaving != nil:
          if evalExpr(plan.groupHaving, aggRow, ctx) != "true":
            continue
        result.add(aggRow)
    return result

  of irpkJoin:
    let leftRows = executePlan(ctx, plan.joinLeft)
    result = @[]

    proc mergeRow(left, right: Row, leftAlias, rightAlias: string): Row =
      result = initTable[string, string]()
      for k, v in left:
        if not k.startsWith("$"):
          result[k] = v
      for k, v in right:
        if not k.startsWith("$") and k notin result:
          result[k] = v
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

    # LATERAL JOIN: for each left row, scan right, merge, then filter/sort/limit
    if plan.joinLateral:
      let rightAlias = plan.joinAlias
      # Walk down right plan to extract filter, sort, limit
      var rightFilter: IRExpr = nil
      var rightSortExprs: seq[IRExpr]
      var rightSortDirs: seq[bool]
      var rightLimit: int = -1
      var rightScanPlan: IRPlan = plan.joinRight
      while rightScanPlan != nil:
        case rightScanPlan.kind
        of irpkScan: break
        of irpkFilter:
          if rightFilter == nil:
            rightFilter = rightScanPlan.filterCond
          else:
            rightFilter = IRExpr(kind: irekBinary, binOp: irAnd,
                                 binLeft: rightFilter, binRight: rightScanPlan.filterCond)
          rightScanPlan = rightScanPlan.filterSource
        of irpkSort:
          rightSortExprs = rightScanPlan.sortExprs
          rightSortDirs = rightScanPlan.sortDirs
          rightScanPlan = rightScanPlan.sortSource
        of irpkLimit:
          rightLimit = rightScanPlan.limitCount
          rightScanPlan = rightScanPlan.limitSource
        of irpkProject:
          rightScanPlan = rightScanPlan.projectSource
        of irpkGroupBy:
          rightScanPlan = rightScanPlan.groupSource
        else: break

      for l in leftRows:
        var rawRightRows: seq[Row]
        if rightScanPlan != nil and rightScanPlan.kind == irpkScan:
          rawRightRows = execScan(ctx, rightScanPlan.scanTable)
        else:
          rawRightRows = @[]

        # Merge, filter
        var mergedRows: seq[Row]
        for r in rawRightRows:
          let merged = mergeRow(l, r, leftAlias, rightAlias)
          if rightFilter != nil and evalExpr(rightFilter, merged, ctx) != "true":
            continue
          if plan.joinCond != nil and evalExpr(plan.joinCond, merged, ctx) != "true":
            continue
          mergedRows.add(merged)

        # Apply sort from subquery
        if rightSortExprs.len > 0 and mergedRows.len > 1:
          mergedRows.sort(proc(a, b: Row): int =
            for i, sExpr in rightSortExprs:
              let aVal = evalExpr(sExpr, a, ctx)
              let bVal = evalExpr(sExpr, b, ctx)
              let asc = if i < rightSortDirs.len: rightSortDirs[i] else: true
              var cmp = 0
              let aNum = parseFloat(aVal)
              let bNum = parseFloat(bVal)
              if aNum < bNum: cmp = -1
              elif aNum > bNum: cmp = 1
              if cmp != 0:
                return if asc: cmp else: -cmp
            return 0
          )

        # Apply limit from subquery
        let limitRows = if rightLimit >= 0 and rightLimit < mergedRows.len:
                          mergedRows[0 ..< rightLimit]
                        else:
                          mergedRows

        if limitRows.len > 0:
          for row in limitRows:
            result.add(row)
        elif plan.joinKind == irjkLeft or plan.joinKind == irjkFull:
          var rightCols: seq[string]
          for r in rawRightRows:
            for k, _ in r:
              if not k.startsWith("$") and k notin rightCols:
                rightCols.add(k)
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
      return result

    # Non-LATERAL: standard join execution
    let rightRows = executePlan(ctx, plan.joinRight)

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
        if plan.joinCond == nil or evalExpr(plan.joinCond, merged, ctx) == "true":
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
          if plan.joinCond == nil or evalExpr(plan.joinCond, merged, ctx) == "true":
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

  of irpkPivot:
    let sourceRows = executePlan(ctx, plan.pivotSource)
    result = @[]
    # Determine which columns are "group by" (all except pivot column and aggregate target)
    var groupCols: seq[string]
    if sourceRows.len > 0:
      for k, _ in sourceRows[0]:
        if not k.startsWith("$") and k != plan.pivotForCol:
          # Check if this column is the aggregate value column
          let isAggTarget = plan.pivotAgg.kind == irekAggregate and
                           plan.pivotAgg.aggArgs.len > 0 and
                           plan.pivotAgg.aggArgs[0].kind == irekField and
                           plan.pivotAgg.aggArgs[0].fieldPath.len > 0 and
                           plan.pivotAgg.aggArgs[0].fieldPath[^1] == k
          if not isAggTarget:
            groupCols.add(k)
    # Group rows by group columns
    var groups = initTable[string, seq[Row]]()
    for row in sourceRows:
      var groupKey = ""
      for col in groupCols:
        groupKey &= (if col in row: row[col] else: "") & "|"
      if groupKey notin groups:
        groups[groupKey] = @[]
      groups[groupKey].add(row)
    # For each group, create a pivoted row
    for gk, groupRows in groups:
      var newRow: Table[string, string]
      for col in groupCols:
        if col in groupRows[0]:
          newRow[col] = groupRows[0][col]
      # For each pivot value, compute the aggregate
      for pivotVal in plan.pivotInValues:
        var matchingRows: seq[Row]
        for row in groupRows:
          if plan.pivotForCol in row and row[plan.pivotForCol] == pivotVal:
            matchingRows.add(row)
        # Compute aggregate
        var aggResult = ""
        if plan.pivotAgg.kind == irekAggregate:
          case plan.pivotAgg.aggOp
          of irCount:
            if plan.pivotAgg.aggArgs.len == 0:
              aggResult = $matchingRows.len
            else:
              var count = 0
              for row in matchingRows:
                let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
                if v.len > 0: count += 1
              aggResult = $count
          of irSum:
            var sum = 0.0
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              try: sum += parseFloat(v) except: discard
            aggResult = $sum
          of irAvg:
            var sum = 0.0
            var count = 0
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              try: sum += parseFloat(v); count += 1 except: discard
            aggResult = if count > 0: $(sum / float(count)) else: "0"
          of irMin:
            var minVal = ""
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              if minVal == "" or v < minVal: minVal = v
            aggResult = minVal
          of irMax:
            var maxVal = ""
            for row in matchingRows:
              let v = evalExpr(plan.pivotAgg.aggArgs[0], row, ctx)
              if maxVal == "" or v > maxVal: maxVal = v
            aggResult = maxVal
          else: discard
        # Clean pivot value (remove quotes)
        let cleanVal = pivotVal.strip(chars = {'\''})
        newRow[cleanVal] = aggResult
      result.add(newRow)
    return result

  of irpkUnpivot:
    let sourceRows = executePlan(ctx, plan.unpivotSource)
    result = @[]
    # Determine which columns are "identity" (all except the IN columns)
    var identityCols: seq[string]
    if sourceRows.len > 0:
      for k, _ in sourceRows[0]:
        if not k.startsWith("$") and k notin plan.unpivotInCols:
          identityCols.add(k)
    # For each source row, create one row per IN column
    for row in sourceRows:
      for inCol in plan.unpivotInCols:
        var newRow: Table[string, string]
        for col in identityCols:
          if col in row:
            newRow[col] = row[col]
        newRow[plan.unpivotForCol] = inCol
        newRow[plan.unpivotValueCol] = (if inCol in row: row[inCol] else: "")
        result.add(newRow)
    return result

  of irpkGraphTraversal:
    # Execute graph traversal using the graph engine
    # For now, return graph metadata as rows
    result = @[]
    # Check if we have a cross-modal engine with graph
    # The graph is stored by name; for simplicity, we'll use a table-based approach
    # Graph nodes are stored as rows with their properties
    let graphTable = plan.graphName & "_nodes"
    # Try to scan the nodes table
    let nodeRows = execScan(ctx, graphTable)
    if nodeRows.len > 0:
      for row in nodeRows:
        var resultRow = row
        result.add(resultRow)
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

proc getSelectColumns(stmt: Node): seq[string] =
  result = @[]
  if stmt.kind != nkSelect: return result
  for i, e in stmt.selResult:
    if e.exprAlias.len > 0:
      result.add(e.exprAlias)
    elif e.kind == nkIdent:
      result.add(e.identName)
    elif e.kind == nkPath and e.pathParts.len > 0:
      result.add(e.pathParts[^1])
    elif e.kind == nkFuncCall:
      result.add(e.funcName & "()")
    elif e.kind == nkStar:
      result.add("*")
    else:
      result.add("col" & $i)

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
    if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom and stmt.selFrom.fromTable in ctx.views:
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
            if evalExpr(whereIr, row, ctx) == "true":
              tmp.add(row)
          filteredRows = tmp
        if stmt.selOrderBy.len > 0:
          let sortExpr = lowerExpr(stmt.selOrderBy[0].orderByExpr)
          let asc = stmt.selOrderBy[0].orderByDir == sdAsc
          proc sortCmp(a, b: Row): int =
            let va = evalExpr(sortExpr, a, ctx)
            let vb = evalExpr(sortExpr, b, ctx)
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
    var cols = getSelectColumns(stmt)
    # Expand star to table columns
    if "*" in cols:
      var expandedCols: seq[string] = @[]
      let tbl = ctx.getTableDef(if stmt.selFrom != nil and stmt.selFrom.kind == nkFrom: stmt.selFrom.fromTable else: "")
      for c in cols:
        if c == "*":
          for tc in tbl.columns:
            expandedCols.add(tc.name)
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
          else: row.add(evalNodeToString(v))
      else:
        if rowNode.kind == nkStringLit: row.add(rowNode.strVal)
        elif rowNode.kind == nkIntLit: row.add($rowNode.intVal)
        elif rowNode.kind == nkFloatLit: row.add($rowNode.floatVal)
        elif rowNode.kind == nkBoolLit: row.add($rowNode.boolVal)
        elif rowNode.kind == nkNullLit: row.add("")
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
        if counterKey in ctx.autoIncCounters:
          nextVal = ctx.autoIncCounters[counterKey]
        ctx.autoIncCounters[counterKey] = nextVal + int64(mutableValues.len)
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
                if counterKey notin ctx.autoIncCounters or intVal >= ctx.autoIncCounters[counterKey]:
                  ctx.autoIncCounters[counterKey] = intVal + 1
              except: discard

    applyDefaultValues(tbl, mutableFields, mutableValues)

    let (valid, errMsg) = validateConstraints(ctx, stmt.insTarget, mutableFields, mutableValues)
    if not valid: return errResult(errMsg)

    # Fire BEFORE INSERT triggers
    var row = initTable[string, string]()
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
        var rowMap = initTable[string, string]()
        for i, f in mutableFields:
          if i < rowVals.len:
            rowMap[f] = rowVals[i]
        var returnRow = initTable[string, string]()
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
    var sets = initTable[string, string]()
    for s in stmt.updSet:
      if s.kind == nkBinOp and s.binOp == bkAssign:
        if s.binLeft.kind == nkIdent:
          let val = if s.binRight.kind == nkStringLit: s.binRight.strVal
                    elif s.binRight.kind == nkIntLit: $s.binRight.intVal
                    elif s.binRight.kind == nkFloatLit: $s.binRight.floatVal
                    elif s.binRight.kind == nkBoolLit: $s.binRight.boolVal
                    elif s.binRight.kind == nkNullLit: ""
                    else: evalNodeToString(s.binRight)
          sets[s.binLeft.identName] = val

    # Scan and apply
    let rows = execScan(ctx, stmt.updTarget)
    var count = 0
    var kvPairs: seq[(string, seq[byte])]
    for row in rows:
      # Check WHERE
      if stmt.updWhere != nil and stmt.updWhere.whereExpr != nil:
        let whereExpr = lowerExpr(stmt.updWhere.whereExpr)
        if evalExpr(whereExpr, row, ctx) != "true": continue
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
        let (valid, errMsg) = validateConstraints(ctx, stmt.updTarget, updFields, @[updValues], skipPkCheck = true)
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
        if evalExpr(whereExpr, row, ctx) != "true": continue
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

  of nkMerge:
    # Execute source: subquery or table scan
    var sourceRows: seq[Row] = @[]
    if stmt.mergeSource != nil:
      if stmt.mergeSource.kind == nkSelect:
        let srcRes = executeQuery(ctx, Node(kind: nkStatementList, stmts: @[stmt.mergeSource]))
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
        if evalExpr(onExpr, rowWithTarget, ctx) == "true":
          matched = true
          if stmt.mergeMatchedUpdate.len > 0 and "$key" in tgtRow:
            var updateSets = initTable[string, string]()
            for s in stmt.mergeMatchedUpdate:
              if s.kind == nkBinOp and s.binOp == bkAssign:
                if s.binLeft.kind == nkIdent:
                  let valExpr = lowerExpr(s.binRight)
                  updateSets[s.binLeft.identName] = evalExpr(valExpr, rowWithTarget, ctx)
            var newRow = tgtRow
            for col, val in updateSets:
              newRow[col] = val
            fireTriggers(ctx, stmt.mergeTarget, "before", "update", tgtRow)
            count += execUpdateRow(ctx, stmt.mergeTarget, tgtRow["$key"], updateSets, kvPairs)
            fireTriggers(ctx, stmt.mergeTarget, "after", "update", newRow)
            if ctx.onChange != nil:
              ctx.onChange(ChangeEvent(table: stmt.mergeTarget, kind: ckUpdate, key: tgtRow["$key"], data: ""))
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
              values.add(evalExpr(valExpr, combinedRow, ctx))
            else:
              values.add("")
        if fields.len > 0:
          var row = initTable[string, string]()
          for i, f in fields:
            if i < values.len: row[f] = values[i]
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
      if col.autoIncrement: parts.add("AUTO_INCREMENT")
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
        let lsmKey = if "$key" in row: row["$key"] else: ""
        let docKey = stmt.ciTarget & "." & lsmKey
        var docId: uint64 = 0
        for ch in docKey:
          docId = docId * 31 + uint64(ord(ch))
        for col in stmt.ciColumns:
          let text = if col in row: row[col] else: ""
          if text.len > 0:
            ftsIdx.addDocument(docId, text)
      ctx.ftsIndexes[colKey] = ftsIdx
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING FTS")

    if stmt.ciKind == ikHNSW:
      # Vector HNSW index
      let rows = execScan(ctx, stmt.ciTarget)
      var dimensions = 0
      for row in rows:
        for col in stmt.ciColumns:
          if col in row:
            let vec = parseVectorString(row[col])
            if vec.len > 0:
              dimensions = vec.len
              break
        if dimensions > 0: break
      if dimensions == 0:
        dimensions = 128  # Default dimension
      var hnswIdx = vengine.newHNSWIndex(dimensions, m = 16, efConstruction = 200, metric = vengine.dmCosine)
      var docId: uint64 = 0
      for row in rows:
        for col in stmt.ciColumns:
          if col in row:
            let vec = parseVectorString(row[col])
            if vec.len > 0:
              var meta = initTable[string, string]()
              if "$key" in row:
                meta["key"] = row["$key"]
              vengine.insert(hnswIdx, docId, vec, meta)
        docId += 1
      ctx.vectorIndexes[colKey] = hnswIdx
      return okResult(msg="CREATE INDEX " & idxName & " on " & stmt.ciTarget & " USING HNSW")

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

  of nkSetVar:
    ctx.sessionVars[stmt.svName] = stmt.svValue
    return okResult(msg="SET " & stmt.svName & " = " & stmt.svValue)

  else:
    return errResult("Unsupported statement type: " & $stmt.kind)


proc executeMigrationSql(ctx: ExecutionContext, sql: string): ExecResult =
  let tokens = qlex.tokenize(sql)
  let astNode = qpar.parse(tokens)
  if astNode.stmts.len > 0:
    return executeQuery(ctx, astNode)
  return okResult(msg="Empty migration body")
