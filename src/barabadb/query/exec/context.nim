## Execution context lifecycle — creation and per-connection cloning.
##
## Extracted from `executor.nim` (Task 1 of the executor split).
## Also hosts the AST-to-SQL serializer used for VIEW DDL persistence.
import std/strutils
import std/tables
import std/locks
import ../ast
import ../../storage/lsm
import ../../storage/btree
import ../../core/mvcc
import ../../core/registry
import ../../fts/engine as fts
import ../../vector/engine as vengine
import types
import schema

## Wired by executor.nim at module load. Breaks the context <-> executor
## module cycle: newExecutionContext cannot call executor code directly, so
## the engine-restore pass (FTS/HNSW/graph replay from persisted schema keys)
## is injected here and invoked nil-safely below.
var restoreEnginesHook*: proc(ctx: ExecutionContext)

# ----------------------------------------------------------------------
# Context management
# ----------------------------------------------------------------------

proc newExecutionContext*(db: LSMTree, registry: DatabaseRegistry = nil): ExecutionContext =
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
                    txnManager: newTxnManager(),
                    onChange: nil,
                    currentDatabase: "default",
                    registry: registry)
  result.sharedLock = SharedLock()
  initLock(result.sharedLock.lock)
  restoreSchema(result)
  if restoreEnginesHook != nil: restoreEnginesHook(result)

# ----------------------------------------------------------------------
# AST to SQL serializer (for VIEW DDL persistence)
# ----------------------------------------------------------------------

proc exprToSql*(node: Node): string =
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
    return "\"" & node.identName.replace("\"", "\"\"") & "\""
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
  of nkPath:
    return node.pathParts.join(".")
  else:
    return $node.kind

proc selectToSql*(node: Node): string =
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

proc cloneForConnection*(ctx: ExecutionContext): ExecutionContext =
  var svCopy = initTable[string, string]()
  for k, v in ctx.sessionVars:
    svCopy[k] = v
  result = ExecutionContext(db: ctx.db, tables: ctx.tables,
                   btrees: ctx.btrees, views: ctx.views,
                   cteTables: initTable[string, seq[Row]](),
                   ftsIndexes: ctx.ftsIndexes,
                   vectorIndexes: ctx.vectorIndexes,
                   graphs: ctx.graphs,
                   users: ctx.users, policies: ctx.policies,
                   txnManager: ctx.txnManager,
                   currentUser: ctx.currentUser, currentRole: ctx.currentRole,
                   sessionVars: svCopy,
                   autoIncCounters: ctx.autoIncCounters,
                    sequences: ctx.sequences,
                    pendingTxn: nil, onChange: ctx.onChange,
                    embedder: ctx.embedder,
                    llmClient: ctx.llmClient,
                    currentDatabase: ctx.currentDatabase,
                    registry: ctx.registry)
  result.sharedLock = ctx.sharedLock
