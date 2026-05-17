## Property-Based Tests — evalExprValue invariants
import std/unittest
import std/tables
import std/random
import std/os
import std/monotimes
import std/math

import barabadb/core/types
import barabadb/storage/lsm
import barabadb/query/ir as qir
import barabadb/query/executor as qexec

suite "Property-Based — evalExprValue Invariants":
  setup:
    var testDir = getTempDir() / "baradb_prop_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
    var ctx = qexec.newExecutionContext(db)

  teardown:
    removeDir(testDir)

  proc randIntLit(rng: var Rand, minVal: int = -1000, maxVal: int = 1000): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkInt64)
    result.literal = IRLiteral(kind: vkInt64, int64Val: int64(rng.rand(minVal..maxVal)))

  proc randFloatLit(rng: var Rand, minVal: float = -1000.0, maxVal: float = 1000.0): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkFloat64)
    result.literal = IRLiteral(kind: vkFloat64, float64Val: minVal + rng.rand(maxVal - minVal))

  proc randBinaryExpr(rng: var Rand, left, right: IRExpr, op: IROperator): IRExpr =
    result = IRExpr(kind: irekBinary)
    result.binOp = op
    result.binLeft = left
    result.binRight = right
    if left.valueKind == vkInt64 and right.valueKind == vkInt64 and op != irDiv:
      result.valueKind = vkInt64
    else:
      result.valueKind = vkFloat64

  proc randUnaryExpr(rng: var Rand, expr: IRExpr, op: IROperator): IRExpr =
    result = IRExpr(kind: irekUnary)
    result.unOp = op
    result.unExpr = expr
    result.valueKind = expr.valueKind

  test "Literal eval returns correct ValueKind (INT)":
    var rng = initRand(42)
    for i in 0..<100:
      let lit = randIntLit(rng)
      let v = evalExprValue(lit, initTable[string, string](), nil)
      check v.kind == vkInt64

  test "Literal eval returns correct ValueKind (FLOAT)":
    var rng = initRand(43)
    for i in 0..<100:
      let lit = randFloatLit(rng)
      let v = evalExprValue(lit, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "INT addition is commutative":
    var rng = initRand(44)
    for i in 0..<100:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      let sum1 = evalExprValue(randBinaryExpr(rng, a, b, irAdd), initTable[string, string](), nil)
      let sum2 = evalExprValue(randBinaryExpr(rng, b, a, irAdd), initTable[string, string](), nil)
      if sum1.kind == vkInt64 and sum2.kind == vkInt64:
        check sum1.int64Val == sum2.int64Val

  test "FLOAT addition is commutative":
    var rng = initRand(45)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let b = randFloatLit(rng)
      let sum1 = evalExprValue(randBinaryExpr(rng, a, b, irAdd), initTable[string, string](), nil)
      let sum2 = evalExprValue(randBinaryExpr(rng, b, a, irAdd), initTable[string, string](), nil)
      if sum1.kind == vkFloat64 and sum2.kind == vkFloat64:
        check abs(sum1.float64Val - sum2.float64Val) < 1e-9

  test "INT multiplication by 1 is identity":
    var rng = initRand(46)
    for i in 0..<100:
      let a = randIntLit(rng)
      let one = IRExpr(kind: irekLiteral, valueKind: vkInt64)
      one.literal = IRLiteral(kind: vkInt64, int64Val: 1)
      let prod = evalExprValue(randBinaryExpr(rng, a, one, irMul), initTable[string, string](), nil)
      if prod.kind == vkInt64:
        check prod.int64Val == a.literal.int64Val

  test "Double negation of INT is identity":
    var rng = initRand(47)
    for i in 0..<100:
      let a = randIntLit(rng)
      let neg = randUnaryExpr(rng, a, irNeg)
      let negNeg = randUnaryExpr(rng, neg, irNeg)
      let v = evalExprValue(negNeg, initTable[string, string](), nil)
      if v.kind == vkInt64:
        check v.int64Val == a.literal.int64Val

  test "Double negation of FLOAT is identity":
    var rng = initRand(48)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let neg = randUnaryExpr(rng, a, irNeg)
      let negNeg = randUnaryExpr(rng, neg, irNeg)
      let v = evalExprValue(negNeg, initTable[string, string](), nil)
      if v.kind == vkFloat64:
        check abs(v.float64Val - a.literal.float64Val) < 1e-9

  test "NULL literal propagates through arithmetic":
    let nullLit = IRExpr(kind: irekLiteral, valueKind: vkNull)
    nullLit.literal = IRLiteral(kind: vkNull)
    let intLit = IRExpr(kind: irekLiteral, valueKind: vkInt64)
    intLit.literal = IRLiteral(kind: vkInt64, int64Val: 5)
    for op in [irAdd, irSub, irMul, irDiv]:
      let expr = IRExpr(kind: irekBinary)
      expr.binOp = op
      expr.binLeft = nullLit
      expr.binRight = intLit
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkNull
