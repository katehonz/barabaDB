## BaraQL IR — Intermediate Representation for compilation
import std/tables
import std/strutils
import ../core/types

type
  IRTypeKind* = enum
    itkScalar
    itkObject
    itkArray
    itkSet
    itkOptional
    itkFunction

  IRType* = ref object
    name*: string
    kind*: IRTypeKind
    fields*: Table[string, IRType]
    isNullable*: bool
    elementType*: IRType

  IROperator* = enum
    irAdd, irSub, irMul, irDiv, irMod, irPow
    irEq, irNeq, irLt, irLte, irGt, irGte
    irAnd, irOr, irNot, irNeg
    irIn, irNotIn
    irLike, irILike
    irBetween
    irIsNull, irIsNotNull
    irFtsMatch

  IRAggregate* = enum
    irCount, irSum, irAvg, irMin, irMax
    irArrayAgg, irStringAgg

  IRLiteral* = object
    case kind*: ValueKind
    of vkNull: discard
    of vkBool: boolVal*: bool
    of vkInt64: int64Val*: int64
    of vkFloat64: float64Val*: float64
    of vkString: strVal*: string
    else: discard

  IRExprKind* = enum
    irekLiteral
    irekField
    irekUnary
    irekBinary
    irekAggregate
    irekFuncCall
    irekCast
    irekConditional
    irekExists
    irekStar
    irekJsonPath
    irekWindowFunc

  IRJoinKind* = enum
    irjkInner
    irjkLeft
    irjkRight
    irjkFull
    irjkCross

  IRPlanKind* = enum
    irpkScan
    irpkFilter
    irpkProject
    irpkGroupBy
    irpkJoin
    irpkSort
    irpkLimit
    irpkInsert
    irpkUpdate
    irpkDelete
    irpkMerge
    irpkCreateType
    irpkUnion
    irpkCTE
    irpkValues
    irpkExplain
    irpkWindow
    irpkPivot
    irpkUnpivot
    irpkGraphTraversal

  IRGroupingSetsKind* = enum
    irgskNone
    irgskGroupingSets
    irgskRollup
    irgskCube

  IRPlan* = ref object
    case kind*: IRPlanKind
    of irpkScan:
      scanTable*: string
      scanAlias*: string
    of irpkFilter:
      filterSource*: IRPlan
      filterCond*: IRExpr
    of irpkProject:
      projectSource*: IRPlan
      projectExprs*: seq[IRExpr]
      projectAliases*: seq[string]
    of irpkGroupBy:
      groupSource*: IRPlan
      groupKeys*: seq[IRExpr]
      groupAggs*: seq[IRExpr]
      groupHaving*: IRExpr
      groupingSetsKind*: IRGroupingSetsKind
      groupingSets*: seq[seq[IRExpr]]
    of irpkJoin:
      joinKind*: IRJoinKind
      joinLeft*: IRPlan
      joinRight*: IRPlan
      joinCond*: IRExpr
      joinAlias*: string
      joinLateral*: bool
    of irpkSort:
      sortSource*: IRPlan
      sortExprs*: seq[IRExpr]
      sortDirs*: seq[bool]
    of irpkLimit:
      limitSource*: IRPlan
      limitCount*: int64
      limitOffset*: int64
    of irpkInsert:
      insertTable*: string
      insertFields*: seq[string]
      insertValues*: seq[seq[IRExpr]]
    of irpkUpdate:
      updateTable*: string
      updateAlias*: string
      updateSets*: seq[(string, IRExpr)]
      updateSource*: IRPlan
    of irpkDelete:
      deleteTable*: string
      deleteAlias*: string
      deleteSource*: IRPlan
    of irpkMerge:
      mergeTarget*: string
      mergeTargetAlias*: string
      mergeSourcePlan*: IRPlan
      mergeOnCond*: IRExpr
      mergeUpdateSets*: seq[(string, IRExpr)]
      mergeInsertFields*: seq[string]
      mergeInsertValues*: seq[seq[IRExpr]]
    of irpkCreateType:
      createTypeName*: string
      createTypeDef*: IRType
    of irpkUnion:
      unionLeft*: IRPlan
      unionRight*: IRPlan
      unionAll*: bool
    of irpkCTE:
      cteName*: string
      cteQuery*: IRPlan
      cteMain*: IRPlan
    of irpkValues:
      valuesRows*: seq[seq[IRExpr]]
    of irpkExplain:
      explainPlan*: IRPlan
    of irpkWindow:
      winSource*: IRPlan
      winFuncs*: seq[IRExpr]
      winPartition*: seq[IRExpr]
      winOrderBy*: seq[IRExpr]
      winOrderDirs*: seq[bool]
      winFrameMode*: string
      winFrameStart*: string
      winFrameEnd*: string
    of irpkPivot:
      pivotSource*: IRPlan
      pivotAgg*: IRExpr
      pivotForCol*: string
      pivotInValues*: seq[string]
    of irpkUnpivot:
      unpivotSource*: IRPlan
      unpivotValueCol*: string
      unpivotForCol*: string
      unpivotInCols*: seq[string]
    of irpkGraphTraversal:
      graphName*: string
      graphAlgo*: string       # "bfs", "dfs", "shortest", "pagerank"
      graphStartNode*: string
      graphEndNode*: string
      graphEdgeLabel*: string
      graphMaxDepth*: int
      graphFilter*: IRExpr
      graphReturnCols*: seq[string]

  IRExpr* = ref object
    case kind*: IRExprKind
    of irekLiteral:
      literal*: IRLiteral
    of irekField:
      fieldPath*: seq[string]
    of irekUnary:
      unOp*: IROperator
      unExpr*: IRExpr
    of irekBinary:
      binOp*: IROperator
      binLeft*: IRExpr
      binRight*: IRExpr
    of irekAggregate:
      aggOp*: IRAggregate
      aggArgs*: seq[IRExpr]
      aggDistinct*: bool
      aggFilter*: IRExpr
    of irekFuncCall:
      irFunc*: string
      irFuncArgs*: seq[IRExpr]
    of irekCast:
      irCastType*: IRType
      irCastExpr*: IRExpr
    of irekConditional:
      cond*: IRExpr
      thenExpr*: IRExpr
      elseExpr*: IRExpr
    of irekExists:
      existsSubquery*: IRPlan
    of irekStar:
      discard
    of irekJsonPath:
      jpExpr*: IRExpr
      jpKey*: string
      jpAsText*: bool
    of irekWindowFunc:
      wfName*: string
      wfArgs*: seq[IRExpr]
      wfPartition*: seq[IRExpr]
      wfOrderBy*: seq[IRExpr]
      wfOrderDirs*: seq[bool]
      wfFrameMode*: string
      wfFrameStart*: string
      wfFrameEnd*: string

type
  TypeChecker* = ref object
    schemas: Table[string, IRType]

proc newTypeChecker*(): TypeChecker =
  TypeChecker(schemas: initTable[string, IRType]())

proc registerType*(tc: TypeChecker, name: string, typ: IRType) =
  tc.schemas[name] = typ

proc getType*(tc: TypeChecker, name: string): IRType =
  tc.schemas.getOrDefault(name, nil)

proc inferExpr*(tc: TypeChecker, expr: IRExpr, context: Table[string, IRType]): IRType =
  case expr.kind
  of irekLiteral:
    case expr.literal.kind
    of vkBool: return IRType(name: "bool", kind: itkScalar)
    of vkInt64: return IRType(name: "int64", kind: itkScalar)
    of vkFloat64: return IRType(name: "float64", kind: itkScalar)
    of vkString: return IRType(name: "str", kind: itkScalar)
    of vkNull: return IRType(name: "null", kind: itkScalar, isNullable: true)
    else: return IRType(name: "unknown", kind: itkScalar)
  of irekField:
    if expr.fieldPath.len == 0:
      return nil
    let rootName = expr.fieldPath[0]
    if rootName in context:
      var current = context[rootName]
      for i in 1..<expr.fieldPath.len:
        if expr.fieldPath[i] in current.fields:
          current = current.fields[expr.fieldPath[i]]
        else:
          return nil
      return current
    return nil
  of irekUnary:
    let operandType = tc.inferExpr(expr.unExpr, context)
    if operandType == nil:
      return nil
    case expr.unOp
    of irEq, irNeq, irLt, irLte, irGt, irGte, irAnd, irOr, irNot,
       irIsNull, irIsNotNull, irIn, irNotIn, irLike, irILike, irBetween,
       irFtsMatch:
      return IRType(name: "bool", kind: itkScalar)
    else:
      return nil
  of irekBinary:
    let leftType = tc.inferExpr(expr.binLeft, context)
    let rightType = tc.inferExpr(expr.binRight, context)
    if leftType == nil or rightType == nil:
      return nil
    case expr.binOp
    of irAdd, irSub, irMul, irDiv, irMod, irPow:
      return leftType
    of irEq, irNeq, irLt, irLte, irGt, irGte, irAnd, irOr,
       irIn, irNotIn, irLike, irILike, irBetween:
      return IRType(name: "bool", kind: itkScalar)
    else:
      return nil
  of irekAggregate:
    case expr.aggOp
    of irCount: return IRType(name: "int64", kind: itkScalar)
    of irSum, irAvg: return IRType(name: "float64", kind: itkScalar)
    of irMin, irMax:
      if expr.aggArgs.len > 0:
        return tc.inferExpr(expr.aggArgs[0], context)
      return nil
    of irArrayAgg:
      return IRType(name: "array", kind: itkArray)
    of irStringAgg:
      return IRType(name: "text", kind: itkScalar)
  of irekFuncCall:
    return IRType(name: "unknown", kind: itkScalar)
  of irekCast:
    return expr.irCastType
  of irekConditional:
    let thenType = tc.inferExpr(expr.thenExpr, context)
    return thenType
  of irekExists:
    return IRType(name: "bool", kind: itkScalar)
  of irekStar:
    return IRType(name: "star", kind: itkScalar)
  of irekJsonPath:
    if expr.jpAsText: return IRType(name: "str", kind: itkScalar)
    return IRType(name: "json", kind: itkScalar)
  of irekWindowFunc:
    # Window functions return int64 for ranking, or the type of the argument for value functions
    case expr.wfName.toLower()
    of "row_number", "rank", "dense_rank", "ntile":
      return IRType(name: "int64", kind: itkScalar)
    of "lead", "lag", "first_value", "last_value":
      if expr.wfArgs.len > 0:
        return tc.inferExpr(expr.wfArgs[0], context)
      return nil
    else:
      return IRType(name: "unknown", kind: itkScalar)
