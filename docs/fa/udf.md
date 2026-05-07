# توابع تعریف‌شده کاربر

گسترش BaraQL با توابع سفارشی.

## استفاده

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

reg.registerStdlib()

reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## توابع استاندارد

| تابع | توضیح | مثال |
|------|--------|------|
| `abs(n)` | قدر مطلق | `abs(-5)` → 5 |
| `sqrt(n)` | ریشه دوم | `sqrt(16)` → 4 |
| `pow(n, e)` | توان | `pow(2, 3)` → 8 |
| `lower(s)` | حروف کوچک | `lower('ABC')` → 'abc' |
| `upper(s)` | حروف بزرگ | `upper('abc')` → 'ABC' |
| `len(s)` | طول | `len('hello')` → 5 |

## ثبت تابع

```nim
reg.register(
  name: "my_function",
  params: @[UDFParam(name: "arg1", typeName: "str")],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    result = Value(kind: vkString, strVal: "")
)
```

## استفاده در کوئری

```sql
SELECT greet(name) FROM users;
```