# الدوال المحددة من المستخدم

توسيع BaraQL بالدوال المخصصة.

## الاستخدام

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

reg.registerStdlib()

reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## دوال المكتبة القياسية

| الدالة | الوصف | مثال |
|--------|-------|------|
| `abs(n)` | القيمة المطلقة | `abs(-5)` → 5 |
| `sqrt(n)` | الجذر التربيعي | `sqrt(16)` → 4 |
| `pow(n, e)` | الأس | `pow(2, 3)` → 8 |
| `lower(s)` | حروف صغيرة | `lower('ABC')` → 'abc' |
| `upper(s)` | حروف كبيرة | `upper('abc')` → 'ABC' |
| `len(s)` | الطول | `len('hello')` → 5 |
| `trim(s)` | إزالة المسافات | `trim(' hello ')` → 'hello' |

## تسجيل الدالة

```nim
reg.register(
  name: "my_function",
  params: @[UDFParam(name: "arg1", typeName: "str")],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    result = Value(kind: vkString, strVal: "")
)
```

## استخدام UDF في الاستعلامات

```sql
SELECT greet(name) FROM users;
```