## BaraQL AST — Abstract Syntax Tree nodes
import ../core/types

type
  NodeKind* = enum
    # Statements
    nkSelect
    nkInsert
    nkUpdate
    nkDelete
    nkCreateType
    nkDropType
    nkAlterType
    nkCreateTable
    nkDropTable
    nkAlterTable
    nkCreateIndex
    nkDropIndex
    nkBeginTxn
    nkCommitTxn
    nkRollbackTxn
    nkExplainStmt

    # Clauses
    nkFrom
    nkWhere
    nkOrderBy
    nkGroupBy
    nkHaving
    nkLimit
    nkOffset
    nkReturning
    nkWith

    # Expressions
    nkBinOp
    nkUnaryOp
    nkFuncCall
    nkTypeCast
    nkPath
    nkIdent
    nkIntLit
    nkFloatLit
    nkStringLit
    nkBoolLit
    nkNullLit
    nkArrayLit
    nkVectorLit
    nkObjectLit
    nkIfElse
    nkCase
    nkSubquery
    nkExists
    nkInExpr
    nkBetweenExpr
    nkLikeExpr
    nkIsExpr

    # Graph-specific
    nkGraphTraversal
    nkBfsQuery
    nkDfsQuery
    nkShortestPath
    nkPatternMatch

    # Vector-specific
    nkVectorSimilar
    nkVectorNearest

    # Join
    nkJoin

    # Type definitions / DDL
    nkPropertyDef
    nkLinkDef
    nkIndexDef
    nkColumnDef
    nkConstraintDef

    # Top-level
    nkStatementList

  BinOpKind* = enum
    bkAdd = "+"
    bkSub = "-"
    bkMul = "*"
    bkDiv = "/"
    bkMod = "%"
    bkPow = "**"
    bkFloorDiv = "//"
    bkEq = "="
    bkNotEq = "!="
    bkLt = "<"
    bkLtEq = "<="
    bkGt = ">"
    bkGtEq = ">="
    bkAnd = "AND"
    bkOr = "OR"
    bkIn = "IN"
    bkNotIn = "NOT IN"
    bkLike = "LIKE"
    bkILike = "ILIKE"
    bkConcat = "++"
    bkCoalesce = "??"
    bkAssign = ":="
    bkArrow = "=>"

  UnaryOpKind* = enum
    ukNeg = "-"
    ukNot = "NOT"
    ukIsNull = "IS NULL"
    ukIsNotNull = "IS NOT NULL"

  JoinKind* = enum
    jkInner
    jkLeft
    jkRight
    jkFull
    jkCross

  SortDir* = enum
    sdAsc
    sdDesc

  Node* = ref object
    line*: int
    col*: int
    case kind*: NodeKind
    of nkSelect:
      selDistinct*: bool
      selWith*: seq[(string, Node)]
      selResult*: seq[Node]
      selFrom*: Node
      selJoins*: seq[Node]
      selWhere*: Node
      selGroupBy*: seq[Node]
      selHaving*: Node
      selOrderBy*: seq[Node]
      selLimit*: Node
      selOffset*: Node
    of nkInsert:
      insTarget*: string
      insFields*: seq[Node]
      insValues*: seq[Node]
      insReturning*: seq[Node]
      insConflict*: Node
    of nkUpdate:
      updTarget*: string
      updAlias*: string
      updSet*: seq[Node]
      updWhere*: Node
      updReturning*: seq[Node]
    of nkDelete:
      delTarget*: string
      delAlias*: string
      delWhere*: Node
      delReturning*: seq[Node]
    of nkCreateType:
      ctName*: string
      ctBases*: seq[string]
      ctProperties*: seq[Node]
      ctLinks*: seq[Node]
    of nkDropType:
      dtName*: string
    of nkAlterType:
      atName*: string
      atOps*: seq[Node]
    of nkCreateTable:
      crtName*: string
      crtColumns*: seq[Node]
      crtConstraints*: seq[Node]
      crtIfNotExists*: bool
    of nkDropTable:
      drtName*: string
      drtIfExists*: bool
    of nkAlterTable:
      altName*: string
      altOps*: seq[Node]
    of nkColumnDef:
      cdName*: string
      cdType*: string
      cdConstraints*: seq[Node]
    of nkConstraintDef:
      cstName*: string
      cstType*: string
      cstExpr*: Node
      cstColumns*: seq[string]
      cstRefTable*: string
      cstRefColumns*: seq[string]
      cstOnDelete*: string
      cstOnUpdate*: string
      cstCheck*: Node
      cstDefault*: Node
    of nkBeginTxn:
      btxnMode*: string
    of nkCommitTxn:
      ctxnChain*: bool
    of nkRollbackTxn:
      rtxnChain*: bool
    of nkExplainStmt:
      expStmt*: Node
      expAnalyze*: bool
    of nkCreateIndex:
      ciTarget*: string
      ciName*: string
      ciExpr*: Node
      ciKind*: IndexKind
    of nkDropIndex:
      diName*: string
    of nkFrom:
      fromTable*: string
      fromAlias*: string
    of nkWhere:
      whereExpr*: Node
    of nkOrderBy:
      orderByExpr*: Node
      orderByDir*: SortDir
    of nkGroupBy:
      groupExprs*: seq[Node]
    of nkHaving:
      havingExpr*: Node
    of nkLimit:
      limitExpr*: Node
    of nkOffset:
      offsetExpr*: Node
    of nkReturning:
      retExprs*: seq[Node]
    of nkWith:
      withBindings*: seq[(string, Node)]
    of nkBinOp:
      binOp*: BinOpKind
      binLeft*: Node
      binRight*: Node
    of nkUnaryOp:
      unOp*: UnaryOpKind
      unOperand*: Node
    of nkFuncCall:
      funcName*: string
      funcArgs*: seq[Node]
    of nkTypeCast:
      castType*: string
      castExpr*: Node
    of nkPath:
      pathParts*: seq[string]
    of nkIdent:
      identName*: string
    of nkIntLit:
      intVal*: int64
    of nkFloatLit:
      floatVal*: float64
    of nkStringLit:
      strVal*: string
    of nkBoolLit:
      boolVal*: bool
    of nkNullLit:
      discard
    of nkArrayLit:
      arrayElems*: seq[Node]
    of nkVectorLit:
      vecElems*: seq[Node]
    of nkObjectLit:
      objFields*: seq[(string, Node)]
    of nkIfElse:
      ifCond*: Node
      ifThen*: Node
      ifElse*: Node
    of nkCase:
      caseExpr*: Node
      caseWhens*: seq[(Node, Node)]
      caseElse*: Node
    of nkSubquery:
      subQuery*: Node
    of nkExists:
      existsExpr*: Node
    of nkInExpr:
      inLeft*: Node
      inRight*: Node
    of nkBetweenExpr:
      betweenExpr*: Node
      betweenLow*: Node
      betweenHigh*: Node
    of nkLikeExpr:
      likeExpr*: Node
      likePattern*: Node
      likeCaseInsensitive*: bool
    of nkIsExpr:
      isExpr*: Node
      isType*: string
      isNegated*: bool
    of nkGraphTraversal:
      gtStart*: Node
      gtEdge*: string
      gtDirection*: string
      gtEnd*: Node
      gtMaxDepth*: int
    of nkBfsQuery:
      bfsStart*: Node
      bfsTarget*: Node
      bfsEdge*: string
      bfsMaxDepth*: int
      bfsFilter*: Node
    of nkDfsQuery:
      dfsStart*: Node
      dfsTarget*: Node
      dfsEdge*: string
      dfsMaxDepth*: int
      dfsFilter*: Node
    of nkShortestPath:
      spStart*: Node
      spEnd*: Node
      spEdge*: string
      spMaxDepth*: int
    of nkPatternMatch:
      pmPattern*: Node
      pmWhere*: Node
    of nkVectorSimilar:
      vsField*: string
      vsVector*: Node
      vsLimit*: int
      vsMetric*: string
    of nkVectorNearest:
      vnField*: string
      vnVector*: Node
      vnLimit*: int
      vnMetric*: string
    of nkJoin:
      joinKind*: JoinKind
      joinTarget*: Node
      joinOn*: Node
      joinAlias*: string
    of nkPropertyDef:
      pdName*: string
      pdType*: string
      pdRequired*: bool
      pdDefault*: Node
      pdComputed*: bool
      pdExpr*: Node
    of nkLinkDef:
      ldName*: string
      ldTarget*: string
      ldCardinality*: Cardinality
      ldRequired*: bool
    of nkIndexDef:
      idName*: string
      idExpr*: Node
      idKind*: IndexKind
    of nkStatementList:
      stmts*: seq[Node]

proc newNode*(kind: NodeKind, line, col: int = 0): Node =
  result = Node(kind: kind, line: line, col: col)
  case kind
  of nkSelect: result.selResult = @[]
  of nkInsert: result.insFields = @[]; result.insValues = @[]
  of nkUpdate: result.updSet = @[]
  of nkDelete: discard
  of nkCreateTable: result.crtColumns = @[]; result.crtConstraints = @[]
  of nkAlterTable: result.altOps = @[]
  of nkColumnDef: result.cdConstraints = @[]
  of nkConstraintDef: result.cstColumns = @[]; result.cstRefColumns = @[]
  of nkStatementList: result.stmts = @[]
  else: discard
