# 用户定义函数

使用自定义函数扩展 BaraQL。

## 用法

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

reg.registerStdlib()

reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## 标准库函数

| 函数 | 描述 | 示例 |
|------|------|------|
| `abs(n)` | 绝对值 | `abs(-5)` → 5 |
| `sqrt(n)` | 平方根 | `sqrt(16)` → 4 |
| `pow(n, e)` | 幂 | `pow(2, 3)` → 8 |
| `lower(s)` | 小写 | `lower('ABC')` → 'abc' |
| `upper(s)` | 大写 | `upper('abc')` → 'ABC' |
| `len(s)` | 长度 | `len('hello')` → 5 |
| `trim(s)` | 去空格 | `trim(' hello ')` → 'hello' |

## 注册函数

```nim
reg.register(
  name: "my_function",
  params: @[UDFParam(name: "arg1", typeName: "str")],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    result = Value(kind: vkString, strVal: "")
)
```

## 在查询中使用 UDF

```sql
SELECT greet(name) FROM users;
```