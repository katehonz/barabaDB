## Parameter binding — placeholder substitution and statement column metadata.
##
## Extracted from `executor.nim` (Task 3 of the executor split).
import std/strutils
import std/tables
import ../ast
import ../../protocol/wire
import context

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
# Statement metadata
# ----------------------------------------------------------------------

proc getSelectColumns*(stmt: Node): seq[string] =
  result = @[]
  if stmt.kind != nkSelect: return result
  var seenAliases = initTable[string, int]()
  for i, e in stmt.selResult:
    var alias = ""
    if e.exprAlias.len > 0:
      alias = e.exprAlias
    elif e.kind == nkIdent:
      alias = e.identName
    elif e.kind == nkPath and e.pathParts.len > 0:
      alias = e.pathParts.join(".")
    elif e.kind == nkFuncCall:
      var aliasArgs: seq[string] = @[]
      for arg in e.funcArgs:
        aliasArgs.add(exprToSql(arg))
      alias = e.funcName & "(" & aliasArgs.join(", ") & ")"
    elif e.kind == nkStar:
      alias = "*"
    else:
      alias = "col" & $i
    if alias in seenAliases:
      seenAliases[alias] += 1
      alias = alias & "_" & $seenAliases[alias]
    else:
      seenAliases[alias] = 0
    result.add(alias)

proc isDDL*(stmt: Node): bool =
  case stmt.kind
  of nkCreateTable, nkDropTable, nkAlterTable,
     nkCreateView, nkDropView,
     nkCreateIndex, nkDropIndex,
     nkCreateTrigger, nkDropTrigger,
     nkCreateUser, nkDropUser,
     nkCreatePolicy, nkDropPolicy,
     nkCreateGraph, nkDropGraph,
     nkCreateDatabase, nkDropDatabase,
     nkGrant, nkRevoke,
     nkEnableRLS, nkDisableRLS:
    result = true
  else:
    result = false

proc isRaftDdl*(stmt: Node): bool =
  ## Schema changes that go through the Raft log when clustering is on.
  ## CREATE/DROP DATABASE are excluded — multi-DB is out of scope for v1 raft
  ## (state machine is wired only to the default database).
  if not isDDL(stmt): return false
  case stmt.kind
  of nkCreateDatabase, nkDropDatabase:
    result = false
  else:
    result = true

proc isWrite*(stmt: Node): bool =
  ## True for statements that mutate stored data. `nkCommitTxn` is included
  ## because COMMIT emits the transaction's buffered kvPairs.
  case stmt.kind
  of nkInsert, nkUpdate, nkDelete, nkMerge, nkCommitTxn:
    result = true
  else:
    result = false
