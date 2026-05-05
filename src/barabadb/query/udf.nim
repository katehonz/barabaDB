## UDF — User Defined Functions runtime
import std/tables
import std/strutils
import std/math
import ../core/types

type
  UDFParam* = object
    name*: string
    typeName*: string
    required*: bool
    default*: Value

  UDFBody* = proc(args: seq[Value]): Value {.gcsafe.}

  UDFlanguage* = enum
    udlNim
    udlExpr    # expression-based (BaraQL expression)
    udlSQL     # SQL passthrough

  UserFunction* = ref object
    name*: string
    module*: string
    params*: seq[UDFParam]
    returnType*: string
    body*: UDFBody
    expr*: string
    language*: UDFlanguage
    volatility*: string  # immutable, stable, volatile
    cached*: bool
    cacheExpiry*: int64
    callCount*: int64

  UDFRegistry* = ref object
    functions*: Table[string, UserFunction]
    modules*: Table[string, seq[string]]

proc newUDFRegistry*(): UDFRegistry =
  UDFRegistry(
    functions: initTable[string, UserFunction](),
    modules: initTable[string, seq[string]](),
  )

proc register*(reg: UDFRegistry, name: string, params: seq[UDFParam],
               returnType: string, body: UDFBody,
               language: UDFlanguage = udlNim, module: string = "default",
               volatility: string = "volatile") =
  let udf = UserFunction(
    name: name, module: module, params: params,
    returnType: returnType, body: body, expr: "",
    language: language, volatility: volatility,
    cached: false, cacheExpiry: 0, callCount: 0,
  )
  reg.functions[name] = udf
  if module notin reg.modules:
    reg.modules[module] = @[]
  reg.modules[module].add(name)

proc registerExpr*(reg: UDFRegistry, name: string, params: seq[UDFParam],
                   returnType: string, expr: string,
                   module: string = "default", volatility: string = "stable") =
  let udf = UserFunction(
    name: name, module: module, params: params,
    returnType: returnType, body: nil, expr: expr,
    language: udlExpr, volatility: volatility,
    cached: false, cacheExpiry: 0, callCount: 0,
  )
  reg.functions[name] = udf
  if module notin reg.modules:
    reg.modules[module] = @[]
  reg.modules[module].add(name)

proc call*(reg: UDFRegistry, name: string, args: seq[Value]): Value =
  if name notin reg.functions:
    return Value(kind: vkNull)
  let udf = reg.functions[name]
  inc udf.callCount
  if udf.body != nil:
    return udf.body(args)
  return Value(kind: vkNull)

proc hasFunction*(reg: UDFRegistry, name: string): bool =
  return name in reg.functions

proc getFunction*(reg: UDFRegistry, name: string): UserFunction =
  reg.functions.getOrDefault(name, nil)

proc getFunctions*(reg: UDFRegistry, module: string): seq[UserFunction] =
  result = @[]
  for fname in reg.modules.getOrDefault(module, @[]):
    if fname in reg.functions:
      result.add(reg.functions[fname])

proc allFunctions*(reg: UDFRegistry): seq[UserFunction] =
  result = @[]
  for name, udf in reg.functions:
    result.add(udf)

proc validateArgs*(udf: UserFunction, args: seq[Value]): seq[string] =
  result = @[]
  if args.len > udf.params.len:
    result.add("Too many arguments: expected " & $udf.params.len & ", got " & $args.len)
  for i in 0..<udf.params.len:
    if i >= args.len:
      if udf.params[i].required and udf.params[i].default.kind == vkNull:
        result.add("Missing required argument: " & udf.params[i].name)
    # Type checking would go here

proc callCount*(udf: UserFunction): int64 = udf.callCount

proc deregister*(reg: UDFRegistry, name: string) =
  if name in reg.functions:
    let module = reg.functions[name].module
    reg.functions.del(name)
    if module in reg.modules:
      var newNames: seq[string] = @[]
      for n in reg.modules[module]:
        if n != name:
          newNames.add(n)
      reg.modules[module] = newNames

proc functionCount*(reg: UDFRegistry): int = reg.functions.len

# Standard library functions
proc registerStdlib*(reg: UDFRegistry) =
  # Math
  reg.register("abs", @[UDFParam(name: "x", typeName: "float64", required: true)],
    "float64", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: abs(args[0].float64Val))
      if args.len > 0 and args[0].kind == vkInt64:
        return Value(kind: vkInt64, int64Val: abs(args[0].int64Val))
      return Value(kind: vkNull))

  reg.register("sqrt", @[UDFParam(name: "x", typeName: "float64", required: true)],
    "float64", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: sqrt(args[0].float64Val))
      return Value(kind: vkNull))

  reg.register("pow", @[
    UDFParam(name: "base", typeName: "float64", required: true),
    UDFParam(name: "exponent", typeName: "float64", required: true)],
    "float64", proc(args: seq[Value]): Value =
      if args.len >= 2 and args[0].kind == vkFloat64 and args[1].kind == vkFloat64:
        return Value(kind: vkFloat64, float64Val: pow(args[0].float64Val, args[1].float64Val))
      return Value(kind: vkNull))

  # String
  reg.register("lower", @[UDFParam(name: "s", typeName: "str", required: true)],
    "str", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkString:
        return Value(kind: vkString, strVal: args[0].strVal.toLower())
      return Value(kind: vkNull))

  reg.register("upper", @[UDFParam(name: "s", typeName: "str", required: true)],
    "str", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkString:
        return Value(kind: vkString, strVal: args[0].strVal.toUpper())
      return Value(kind: vkNull))

  reg.register("len", @[UDFParam(name: "s", typeName: "str", required: true)],
    "int64", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkString:
        return Value(kind: vkInt64, int64Val: int64(args[0].strVal.len))
      if args.len > 0 and args[0].kind == vkArray:
        return Value(kind: vkInt64, int64Val: int64(args[0].arrayVal.len))
      return Value(kind: vkNull))

  reg.register("trim", @[UDFParam(name: "s", typeName: "str", required: true)],
    "str", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkString:
        return Value(kind: vkString, strVal: args[0].strVal.strip())
      return Value(kind: vkNull))

  reg.register("substr", @[
    UDFParam(name: "s", typeName: "str", required: true),
    UDFParam(name: "start", typeName: "int64", required: true),
    UDFParam(name: "length", typeName: "int64", required: false)],
    "str", proc(args: seq[Value]): Value =
      if args.len >= 2 and args[0].kind == vkString and args[1].kind == vkInt64:
        let s = args[0].strVal
        let start = int(args[1].int64Val)
        if args.len >= 3 and args[2].kind == vkInt64:
          let length = int(args[2].int64Val)
          return Value(kind: vkString, strVal: s[start ..< min(start + length, s.len)])
        return Value(kind: vkString, strVal: s[start .. ^1])
      return Value(kind: vkNull))

  # Type conversion
  reg.register("toString", @[UDFParam(name: "x", typeName: "any", required: true)],
    "str", proc(args: seq[Value]): Value =
      if args.len > 0:
        case args[0].kind
        of vkString: return args[0]
        of vkInt64: return Value(kind: vkString, strVal: $args[0].int64Val)
        of vkFloat64: return Value(kind: vkString, strVal: $args[0].float64Val)
        of vkBool: return Value(kind: vkString, strVal: $args[0].boolVal)
        else: discard
      return Value(kind: vkNull))

  reg.register("toInt", @[UDFParam(name: "s", typeName: "str", required: true)],
    "int64", proc(args: seq[Value]): Value =
      if args.len > 0 and args[0].kind == vkString:
        try:
          return Value(kind: vkInt64, int64Val: parseInt(args[0].strVal))
        except:
          discard
      return Value(kind: vkNull))

  # Array
  reg.register("contains", @[
    UDFParam(name: "arr", typeName: "array", required: true),
    UDFParam(name: "value", typeName: "any", required: true)],
    "bool", proc(args: seq[Value]): Value =
      if args.len >= 2 and args[0].kind == vkArray:
        for item in args[0].arrayVal:
          if item.kind == args[1].kind:
            case item.kind
            of vkString:
              if item.strVal == args[1].strVal:
                return Value(kind: vkBool, boolVal: true)
            of vkInt64:
              if item.int64Val == args[1].int64Val:
                return Value(kind: vkBool, boolVal: true)
            of vkFloat64:
              if item.float64Val == args[1].float64Val:
                return Value(kind: vkBool, boolVal: true)
            of vkBool:
              if item.boolVal == args[1].boolVal:
                return Value(kind: vkBool, boolVal: true)
            else: discard
        return Value(kind: vkBool, boolVal: false)
      return Value(kind: vkNull))
