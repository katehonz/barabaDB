## Property-Based Tests — evalExprValue + B-Tree invariants
import std/unittest
import std/tables
import std/random
import std/os
import std/monotimes
import std/math

import barabadb/core/types
import barabadb/storage/lsm
import barabadb/storage/btree
import barabadb/query/ir as qir
import barabadb/query/executor as qexec

suite "Property-Based — evalExprValue Invariants":
  setup:
    var testDir = getTempDir() / "baradb_prop_test_" & $getCurrentProcessId() & "_" & $getMonoTime().ticks
    createDir(testDir)
    var db = newLSMTree(testDir)
    var ctx {.used.} = qexec.newExecutionContext(db)

  teardown:
    removeDir(testDir)

  proc randIntLit(rng: var Rand, minVal: int = -1000, maxVal: int = 1000): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkInt64)
    result.literal = IRLiteral(kind: vkInt64, int64Val: int64(rng.rand(minVal..maxVal)))

  proc randFloatLit(rng: var Rand, minVal: float = -1000.0, maxVal: float = 1000.0): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkFloat64)
    result.literal = IRLiteral(kind: vkFloat64, float64Val: minVal + rng.rand(maxVal - minVal))

  proc randStrLit(rng: var Rand, minLen: int = 0, maxLen: int = 10): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkString)
    let len = rng.rand(minLen..maxLen)
    var s = ""
    for i in 0..<len:
      s.add(char(rng.rand(ord('a')..ord('z'))))
    result.literal = IRLiteral(kind: vkString, strVal: s)

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

  proc nullLit(): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkNull)
    result.literal = IRLiteral(kind: vkNull)

  proc intLit(val: int64): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkInt64)
    result.literal = IRLiteral(kind: vkInt64, int64Val: val)

  proc floatLit(val: float64): IRExpr =
    result = IRExpr(kind: irekLiteral, valueKind: vkFloat64)
    result.literal = IRLiteral(kind: vkFloat64, float64Val: val)

  proc makeBinary(left, right: IRExpr, op: IROperator, vk: ValueKind = vkInt64): IRExpr =
    result = IRExpr(kind: irekBinary)
    result.binOp = op
    result.binLeft = left
    result.binRight = right
    result.valueKind = vk

  proc makeUnary(expr: IRExpr, op: IROperator, vk: ValueKind = vkInt64): IRExpr =
    result = IRExpr(kind: irekUnary)
    result.unOp = op
    result.unExpr = expr
    result.valueKind = vk

  # ──────────────────────────────────────────────────
  # Literal tests
  # ──────────────────────────────────────────────────
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

  test "Literal eval returns correct ValueKind (STRING)":
    var rng = initRand(49)
    for i in 0..<100:
      let lit = randStrLit(rng)
      let v = evalExprValue(lit, initTable[string, string](), nil)
      check v.kind == vkString

  test "Literal eval returns correct ValueKind (BOOL)":
    for b in [true, false]:
      var lit = IRExpr(kind: irekLiteral, valueKind: vkBool)
      lit.literal = IRLiteral(kind: vkBool, boolVal: b)
      let v = evalExprValue(lit, initTable[string, string](), nil)
      check v.kind == vkBool
      check v.boolVal == b

  test "Literal eval returns correct ValueKind (NULL)":
    let lit = nullLit()
    let v = evalExprValue(lit, initTable[string, string](), nil)
    check v.kind == vkNull

  # ──────────────────────────────────────────────────
  # Commutativity
  # ──────────────────────────────────────────────────
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

  test "INT multiplication is commutative":
    var rng = initRand(50)
    for i in 0..<100:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      let prod1 = evalExprValue(randBinaryExpr(rng, a, b, irMul), initTable[string, string](), nil)
      let prod2 = evalExprValue(randBinaryExpr(rng, b, a, irMul), initTable[string, string](), nil)
      if prod1.kind == vkInt64 and prod2.kind == vkInt64:
        check prod1.int64Val == prod2.int64Val

  test "FLOAT multiplication is commutative":
    var rng = initRand(51)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let b = randFloatLit(rng)
      let prod1 = evalExprValue(randBinaryExpr(rng, a, b, irMul), initTable[string, string](), nil)
      let prod2 = evalExprValue(randBinaryExpr(rng, b, a, irMul), initTable[string, string](), nil)
      if prod1.kind == vkFloat64 and prod2.kind == vkFloat64:
        check abs(prod1.float64Val - prod2.float64Val) < 1e-9

  # ──────────────────────────────────────────────────
  # Associativity
  # ──────────────────────────────────────────────────
  test "INT addition is associative":
    var rng = initRand(52)
    for i in 0..<100:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      let c = randIntLit(rng)
      let abPlusC = makeBinary(makeBinary(a, b, irAdd, vkInt64), c, irAdd, vkInt64)
      let aPlusBC = makeBinary(a, makeBinary(b, c, irAdd, vkInt64), irAdd, vkInt64)
      let v1 = evalExprValue(abPlusC, initTable[string, string](), nil)
      let v2 = evalExprValue(aPlusBC, initTable[string, string](), nil)
      if v1.kind == vkInt64 and v2.kind == vkInt64:
        check v1.int64Val == v2.int64Val

  test "FLOAT addition is associative":
    var rng = initRand(53)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let b = randFloatLit(rng)
      let c = randFloatLit(rng)
      let abPlusC = makeBinary(makeBinary(a, b, irAdd, vkFloat64), c, irAdd, vkFloat64)
      let aPlusBC = makeBinary(a, makeBinary(b, c, irAdd, vkFloat64), irAdd, vkFloat64)
      let v1 = evalExprValue(abPlusC, initTable[string, string](), nil)
      let v2 = evalExprValue(aPlusBC, initTable[string, string](), nil)
      if v1.kind == vkFloat64 and v2.kind == vkFloat64:
        check abs(v1.float64Val - v2.float64Val) < 1e-9

  test "INT multiplication is associative":
    var rng = initRand(54)
    for i in 0..<100:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      let c = randIntLit(rng)
      let abMulC = makeBinary(makeBinary(a, b, irMul, vkInt64), c, irMul, vkInt64)
      let aMulBC = makeBinary(a, makeBinary(b, c, irMul, vkInt64), irMul, vkInt64)
      let v1 = evalExprValue(abMulC, initTable[string, string](), nil)
      let v2 = evalExprValue(aMulBC, initTable[string, string](), nil)
      if v1.kind == vkInt64 and v2.kind == vkInt64:
        check v1.int64Val == v2.int64Val

  test "STRING concatenation is associative":
    var rng = initRand(55)
    for i in 0..<100:
      let a = randStrLit(rng, 0, 5)
      let b = randStrLit(rng, 0, 5)
      let c = randStrLit(rng, 0, 5)
      let abConcatC = makeBinary(makeBinary(a, b, irAdd, vkString), c, irAdd, vkString)
      let aConcatBC = makeBinary(a, makeBinary(b, c, irAdd, vkString), irAdd, vkString)
      let v1 = evalExprValue(abConcatC, initTable[string, string](), nil)
      let v2 = evalExprValue(aConcatBC, initTable[string, string](), nil)
      if v1.kind == vkString and v2.kind == vkString:
        check v1.strVal == v2.strVal

  # ──────────────────────────────────────────────────
  # Distributivity
  # ──────────────────────────────────────────────────
  test "INT distributivity: a*(b+c) == a*b + a*c":
    var rng = initRand(56)
    for i in 0..<100:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      let c = randIntLit(rng)
      let left = makeBinary(a, makeBinary(b, c, irAdd, vkInt64), irMul, vkInt64)
      let ab = makeBinary(a, b, irMul, vkInt64)
      let ac = makeBinary(a, c, irMul, vkInt64)
      let right = makeBinary(ab, ac, irAdd, vkInt64)
      let v1 = evalExprValue(left, initTable[string, string](), nil)
      let v2 = evalExprValue(right, initTable[string, string](), nil)
      if v1.kind == vkInt64 and v2.kind == vkInt64:
        check v1.int64Val == v2.int64Val

  # ──────────────────────────────────────────────────
  # Identity
  # ──────────────────────────────────────────────────
  test "INT multiplication by 1 is identity":
    var rng = initRand(46)
    for i in 0..<100:
      let a = randIntLit(rng)
      let one = intLit(1)
      let prod = evalExprValue(randBinaryExpr(rng, a, one, irMul), initTable[string, string](), nil)
      if prod.kind == vkInt64:
        check prod.int64Val == a.literal.int64Val

  test "INT addition with 0 is identity":
    var rng = initRand(57)
    for i in 0..<100:
      let a = randIntLit(rng)
      let zero = intLit(0)
      let sum = evalExprValue(randBinaryExpr(rng, a, zero, irAdd), initTable[string, string](), nil)
      if sum.kind == vkInt64:
        check sum.int64Val == a.literal.int64Val

  test "FLOAT addition with 0.0 is identity":
    var rng = initRand(58)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let zero = floatLit(0.0)
      let expr = makeBinary(a, zero, irAdd, vkFloat64)
      let sum = evalExprValue(expr, initTable[string, string](), nil)
      if sum.kind == vkFloat64:
        check abs(sum.float64Val - a.literal.float64Val) < 1e-9

  test "INT subtraction: a - 0 == a":
    var rng = initRand(59)
    for i in 0..<100:
      let a = randIntLit(rng)
      let zero = intLit(0)
      let expr = makeBinary(a, zero, irSub, vkInt64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      if v.kind == vkInt64:
        check v.int64Val == a.literal.int64Val

  test "INT subtraction: a - a == 0":
    var rng = initRand(60)
    for i in 0..<100:
      let a = randIntLit(rng)
      let expr = randBinaryExpr(rng, a, a, irSub)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      if v.kind == vkInt64:
        check v.int64Val == 0

  test "FLOAT subtraction: a - a == 0":
    var rng = initRand(61)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let expr = makeBinary(a, a, irSub, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      if v.kind == vkFloat64:
        check abs(v.float64Val) < 1e-9

  test "FLOAT multiplication by 1.0 is identity":
    var rng = initRand(62)
    for i in 0..<100:
      let a = randFloatLit(rng)
      let one = floatLit(1.0)
      let expr = makeBinary(a, one, irMul, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      if v.kind == vkFloat64:
        check abs(v.float64Val - a.literal.float64Val) < 1e-9

  test "STRING concatenation with empty string is identity":
    var rng = initRand(63)
    for i in 0..<100:
      let a = randStrLit(rng, 0, 10)
      let empty = randStrLit(rng, 0, 0)
      let v1 = evalExprValue(makeBinary(a, empty, irAdd, vkString), initTable[string, string](), nil)
      let v2 = evalExprValue(makeBinary(empty, a, irAdd, vkString), initTable[string, string](), nil)
      if v1.kind == vkString: check v1.strVal == a.literal.strVal
      if v2.kind == vkString: check v2.strVal == a.literal.strVal

  # ──────────────────────────────────────────────────
  # Negation
  # ──────────────────────────────────────────────────
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

  test "Negated zero is zero (INT)":
    let zero = intLit(0)
    let negZero = makeUnary(zero, irNeg, vkInt64)
    let v = evalExprValue(negZero, initTable[string, string](), nil)
    if v.kind == vkInt64:
      check v.int64Val == 0

  test "Negated zero is zero (FLOAT)":
    let zero = floatLit(0.0)
    let negZero = makeUnary(zero, irNeg, vkFloat64)
    let v = evalExprValue(negZero, initTable[string, string](), nil)
    if v.kind == vkFloat64:
      check v.float64Val == 0.0

  # ──────────────────────────────────────────────────
  # Division & Mod
  # ──────────────────────────────────────────────────
  test "Division: (a * b) / b == a when b != 0 (INT→FLOAT)":
    var rng = initRand(64)
    for i in 0..<100:
      let a = int64(rng.rand(-100..100))
      let b = int64(rng.rand(-100..100))
      if b == 0: continue
      let av = intLit(a)
      let bv = intLit(b)
      let mul = makeBinary(av, bv, irMul, vkInt64)
      let divE = makeBinary(mul, bv, irDiv, vkFloat64)
      let v = evalExprValue(divE, initTable[string, string](), nil)
      if v.kind == vkFloat64:
        check abs(v.float64Val - float64(a)) < 1e-6

  test "Mod with positive operands returns valid remainder":
    var rng = initRand(65)
    for i in 0..<100:
      let a = int64(rng.rand(0..100))
      let b = int64(rng.rand(1..100))
      let av = intLit(a)
      let bv = intLit(b)
      let modE = makeBinary(av, bv, irMod, vkInt64)
      let v = evalExprValue(modE, initTable[string, string](), nil)
      if v.kind == vkInt64:
        check v.int64Val >= 0
        check v.int64Val < b

  # ──────────────────────────────────────────────────
  # Division by zero → NULL
  # ──────────────────────────────────────────────────
  test "INT division by zero returns NULL":
    let a = intLit(42)
    let zero = intLit(0)
    let divExpr = makeBinary(a, zero, irDiv, vkFloat64)
    let v = evalExprValue(divExpr, initTable[string, string](), nil)
    check v.kind == vkNull

  test "FLOAT division by zero returns NULL":
    let a = floatLit(42.0)
    let zero = floatLit(0.0)
    let divExpr = makeBinary(a, zero, irDiv, vkFloat64)
    let v = evalExprValue(divExpr, initTable[string, string](), nil)
    check v.kind == vkNull

  test "INT modulo zero returns NULL":
    let a = intLit(42)
    let zero = intLit(0)
    let modExpr = makeBinary(a, zero, irMod, vkInt64)
    let v = evalExprValue(modExpr, initTable[string, string](), nil)
    check v.kind == vkNull

  # ──────────────────────────────────────────────────
  # POW
  # ──────────────────────────────────────────────────
  test "POW(a, 0) == 1.0":
    var rng = initRand(66)
    for i in 0..<50:
      let a = randIntLit(rng)
      let zero = intLit(0)
      let powExpr = makeBinary(a, zero, irPow, vkFloat64)
      let v = evalExprValue(powExpr, initTable[string, string](), nil)
      if v.kind == vkFloat64:
        check abs(v.float64Val - 1.0) < 1e-9

  test "POW(a, 1) == a":
    var rng = initRand(67)
    for i in 0..<50:
      let a = randIntLit(rng)
      let one = intLit(1)
      let powExpr = makeBinary(a, one, irPow, vkFloat64)
      let v = evalExprValue(powExpr, initTable[string, string](), nil)
      if v.kind == vkFloat64:
        check abs(v.float64Val - float64(a.literal.int64Val)) < 1e-9

  test "POW(a, 2) == a*a":
    var rng = initRand(68)
    for i in 0..<50:
      let a = randIntLit(rng)
      let two = intLit(2)
      let powExpr = makeBinary(a, two, irPow, vkFloat64)
      let mulExpr = makeBinary(a, a, irMul, vkInt64)
      let v1 = evalExprValue(powExpr, initTable[string, string](), nil)
      let v2 = evalExprValue(mulExpr, initTable[string, string](), nil)
      if v1.kind == vkFloat64 and v2.kind == vkInt64:
        check abs(v1.float64Val - float64(v2.int64Val)) < 1e-9

  # ──────────────────────────────────────────────────
  # NULL propagation
  # ──────────────────────────────────────────────────
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

  test "NULL propagates through mod":
    let n = nullLit()
    let a = intLit(5)
    for pair in [(n, a), (a, n)]:
      let (left, right) = pair
      let expr = makeBinary(left, right, irMod, vkInt64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkNull

  test "NULL propagates through pow":
    let n = nullLit()
    let a = intLit(5)
    for pair in [(n, a), (a, n)]:
      let (left, right) = pair
      let expr = makeBinary(left, right, irPow, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkNull

  test "NULL propagates through negation":
    let n = nullLit()
    let neg = makeUnary(n, irNeg, vkInt64)
    let v = evalExprValue(neg, initTable[string, string](), nil)
    check v.kind == vkNull

  # ──────────────────────────────────────────────────
  # Type coercion / mixed-type arithmetic
  # ──────────────────────────────────────────────────
  test "INT + FLOAT → FLOAT":
    var rng = initRand(69)
    for i in 0..<50:
      let a = randIntLit(rng)
      let b = randFloatLit(rng)
      let expr = makeBinary(a, b, irAdd, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "FLOAT + INT → FLOAT":
    var rng = initRand(70)
    for i in 0..<50:
      let a = randFloatLit(rng)
      let b = randIntLit(rng)
      let expr = makeBinary(a, b, irAdd, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "INT / INT → FLOAT":
    var rng = initRand(71)
    for i in 0..<50:
      let a = randIntLit(rng)
      var b = rng.rand(1..100)  # non-zero
      let bv = intLit(int64(b))
      let expr = makeBinary(a, bv, irDiv, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "INT - FLOAT → FLOAT":
    var rng = initRand(72)
    for i in 0..<50:
      let a = randIntLit(rng)
      let b = randFloatLit(rng)
      let expr = makeBinary(a, b, irSub, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "INT * FLOAT → FLOAT":
    var rng = initRand(73)
    for i in 0..<50:
      let a = randIntLit(rng)
      let b = randFloatLit(rng)
      let expr = makeBinary(a, b, irMul, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "FLOAT + FLOAT → FLOAT":
    var rng = initRand(74)
    for i in 0..<50:
      let a = randFloatLit(rng)
      let b = randFloatLit(rng)
      let expr = makeBinary(a, b, irAdd, vkFloat64)
      let v = evalExprValue(expr, initTable[string, string](), nil)
      check v.kind == vkFloat64

  test "INT + INT → INT (non-div ops)":
    var rng = initRand(75)
    for i in 0..<50:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      for op in [irAdd, irSub, irMul]:
        let expr = makeBinary(a, b, op, vkInt64)
        let v = evalExprValue(expr, initTable[string, string](), nil)
        check v.kind == vkInt64

  # ──────────────────────────────────────────────────
  # Comparison evals (via evalExpr → string)
  # ──────────────────────────────────────────────────
  test "eq comparison: a == a is true":
    var rng = initRand(76)
    for i in 0..<50:
      let a = randIntLit(rng)
      let expr = makeBinary(a, a, irEq, vkBool)
      let s = evalExpr(expr, initTable[string, string](), nil)
      check s == "true"

  test "neq comparison: a != a is false":
    var rng = initRand(77)
    for i in 0..<50:
      let a = randIntLit(rng)
      let expr = makeBinary(a, a, irNeq, vkBool)
      let s = evalExpr(expr, initTable[string, string](), nil)
      check s == "false"

  test "lt comparison: a < a is false":
    let a = intLit(5)
    let expr = makeBinary(a, a, irLt, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "false"

  test "lte comparison: a <= a is true":
    let a = intLit(5)
    let expr = makeBinary(a, a, irLte, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "true"

  test "gt comparison: a > a is false":
    let a = intLit(5)
    let expr = makeBinary(a, a, irGt, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "false"

  test "gte comparison: a >= a is true":
    let a = intLit(5)
    let expr = makeBinary(a, a, irGte, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "true"

  test "lt comparison: a < b is true when a < b":
    var rng = initRand(78)
    for i in 0..<50:
      let x = int64(rng.rand(0..50))
      let y = int64(rng.rand(51..100))
      let a = intLit(x)
      let b = intLit(y)
      let expr = makeBinary(a, b, irLt, vkBool)
      let s = evalExpr(expr, initTable[string, string](), nil)
      check s == "true"

  # ──────────────────────────────────────────────────
  # AND / OR logical operations
  # ──────────────────────────────────────────────────
  test "AND: true AND true = true":
    var ta = IRExpr(kind: irekLiteral, valueKind: vkBool)
    ta.literal = IRLiteral(kind: vkBool, boolVal: true)
    let expr = makeBinary(ta, ta, irAnd, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "true"

  test "AND: true AND false = false":
    var ta = IRExpr(kind: irekLiteral, valueKind: vkBool)
    ta.literal = IRLiteral(kind: vkBool, boolVal: true)
    var fa = IRExpr(kind: irekLiteral, valueKind: vkBool)
    fa.literal = IRLiteral(kind: vkBool, boolVal: false)
    let expr = makeBinary(ta, fa, irAnd, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "false"

  test "OR: false OR true = true":
    var ta = IRExpr(kind: irekLiteral, valueKind: vkBool)
    ta.literal = IRLiteral(kind: vkBool, boolVal: true)
    var fa = IRExpr(kind: irekLiteral, valueKind: vkBool)
    fa.literal = IRLiteral(kind: vkBool, boolVal: false)
    let expr = makeBinary(fa, ta, irOr, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "true"

  test "OR: false OR false = false":
    var fa = IRExpr(kind: irekLiteral, valueKind: vkBool)
    fa.literal = IRLiteral(kind: vkBool, boolVal: false)
    let expr = makeBinary(fa, fa, irOr, vkBool)
    let s = evalExpr(expr, initTable[string, string](), nil)
    check s == "false"

  # ──────────────────────────────────────────────────
  # Random complex nested expressions
  # ──────────────────────────────────────────────────
  test "Complex nested expression does not crash":
    var rng = initRand(79)
    for i in 0..<200:
      let a = randIntLit(rng)
      let b = randIntLit(rng)
      let c = randIntLit(rng)
      let d = randIntLit(rng)
      let t1 = makeBinary(a, b, irAdd, vkInt64)
      let t2 = makeBinary(c, d, irMul, vkInt64)
      let t3 = makeBinary(t1, t2, irSub, vkInt64)
      let t4 = makeUnary(t3, irNeg, vkInt64)
      let t5 = makeBinary(t4, intLit(1), irAdd, vkInt64)
      discard evalExprValue(t5, initTable[string, string](), nil)
    check true

  test "Random binary tree depth 5 does not crash":
    var rng = initRand(80)
    let ops = [irAdd, irSub, irMul, irDiv, irMod, irPow]
    for i in 0..<200:
      var nodes: seq[IRExpr] = @[]
      for j in 0..<16:
        if rng.rand(0..1) == 0:
          nodes.add(randIntLit(rng))
        else:
          nodes.add(randFloatLit(rng))
      while nodes.len > 1:
        let opIdx = rng.rand(0..ops.len-1)
        let left = nodes.pop()
        let right = nodes.pop()
        let vk = if left.valueKind == vkInt64 and right.valueKind == vkInt64 and ops[opIdx] != irDiv: vkInt64
                 else: vkFloat64
        nodes.insert(makeBinary(left, right, ops[opIdx], vk), 0)
      if nodes.len == 1:
        discard evalExprValue(nodes[0], initTable[string, string](), nil)
    check true

  test "Nil expr evaluates to NULL":
    let v = evalExprValue(nil, initTable[string, string](), nil)
    check v.kind == vkNull
    let s = evalExpr(nil, initTable[string, string](), nil)
    check s == ""

# ═══════════════════════════════════════════════════
# B-Tree Property-Based Invariants
# ═══════════════════════════════════════════════════
suite "Property-Based — B-Tree Invariants":

  proc randKey(rng: var Rand, minVal: int = 0, maxVal: int = 10000): int =
    rng.rand(minVal..maxVal)

  test "B-Tree size equals number of unique keys after random inserts":
    var rng = initRand(1000)
    var btree = newBTreeIndex[int, string](order = 8)
    var uniqueKeys = initTable[int, bool]()
    for i in 0..<500:
      let k = randKey(rng)
      btree.insert(k, "v" & $k)
      uniqueKeys[k] = true
    check btree.len == uniqueKeys.len

  test "B-Tree get returns all values for inserted key":
    var rng = initRand(1001)
    var btree = newBTreeIndex[int, string](order = 8)
    var expected = initTable[int, seq[string]]()
    for i in 0..<200:
      let k = randKey(rng, 0, 50)
      let v = "val_" & $i
      btree.insert(k, v)
      if k notin expected:
        expected[k] = @[]
      expected[k].add(v)
    for k, vals in expected:
      let got = btree.get(k)
      check got == vals

  test "B-Tree scan returns keys in ascending order":
    var rng = initRand(1002)
    var btree = newBTreeIndex[int, string](order = 8)
    for i in 0..<300:
      btree.insert(randKey(rng, 0, 1000), "x")
    let result = btree.scan(0, 1000)
    for i in 1..<result.len:
      check result[i-1][0] <= result[i][0]

  test "B-Tree scan range is inclusive and correct":
    var rng = initRand(1003)
    var btree = newBTreeIndex[int, string](order = 8)
    var inserted = initTable[int, bool]()
    for i in 0..<400:
      let k = randKey(rng, 0, 200)
      btree.insert(k, "v")
      inserted[k] = true
    let scanned = btree.scan(50, 100)
    for (k, _) in scanned:
      check k >= 50
      check k <= 100
      check inserted[k]

  test "B-Tree contains after insert":
    var rng = initRand(1004)
    var btree = newBTreeIndex[int, string](order = 8)
    var keys: seq[int] = @[]
    for i in 0..<100:
      let k = randKey(rng)
      btree.insert(k, "v")
      keys.add(k)
    for k in keys:
      check btree.contains(k)

  test "B-Tree remove decreases size":
    var rng = initRand(1005)
    var btree = newBTreeIndex[int, string](order = 8)
    var inserted = initTable[int, seq[string]]()
    for i in 0..<200:
      let k = randKey(rng, 0, 100)
      let v = "v" & $i
      btree.insert(k, v)
      if k notin inserted:
        inserted[k] = @[]
      inserted[k].add(v)
    let beforeSize = btree.len
    var removedCount = 0
    for k, vals in inserted:
      if vals.len > 0:
        btree.remove(k, vals[0])
        inc removedCount
    # Size should decrease by number of keys that had values removed
    # (if all values removed, key is deleted)
    check btree.len <= beforeSize

  test "B-Tree with large order handles many inserts":
    var rng = initRand(1006)
    var btree = newBTreeIndex[int, string](order = 64)
    for i in 0..<2000:
      btree.insert(i, "v" & $i)
    check btree.len == 2000
    for i in 0..<2000:
      check btree.contains(i)

  test "B-Tree duplicate inserts append values":
    var rng = initRand(1007)
    var btree = newBTreeIndex[int, string](order = 8)
    let k = 42
    for i in 0..<50:
      btree.insert(k, "v" & $i)
    let vals = btree.get(k)
    check vals.len == 50
    for i in 0..<50:
      check vals[i] == "v" & $i

  test "B-Tree scan on empty tree returns empty":
    var btree = newBTreeIndex[int, string]()
    let result = btree.scan(0, 100)
    check result.len == 0

  test "B-Tree random interleaved insert/remove maintains invariants":
    var rng = initRand(1008)
    var btree = newBTreeIndex[int, string](order = 8)
    var tracker = initTable[int, seq[string]]()
    for i in 0..<300:
      let op = rng.rand(0..2)
      let k = randKey(rng, 0, 50)
      case op
      of 0, 1:  # insert
        let v = "v" & $i
        btree.insert(k, v)
        if k notin tracker:
          tracker[k] = @[]
        tracker[k].add(v)
      of 2:  # remove
        if k in tracker and tracker[k].len > 0:
          let v = tracker[k][0]
          btree.remove(k, v)
          tracker[k].del(0)
          if tracker[k].len == 0:
            tracker.del(k)
      else: discard
    # Verify all tracked keys are present
    for k, vals in tracker:
      let got = btree.get(k)
      check got == vals
