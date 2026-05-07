# Пользовательские функции

Расширение BaraQL пользовательскими функциями.

## Использование

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

reg.registerStdlib()

reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## Стандартные функции

| Функция | Описание | Пример |
|---------|----------|--------|
| `abs(n)` | Абсолютное значение | `abs(-5)` → 5 |
| `sqrt(n)` | Квадратный корень | `sqrt(16)` → 4 |
| `pow(n, e)` | Степень | `pow(2, 3)` → 8 |
| `lower(s)` | Нижний регистр | `lower('ABC')` → 'abc' |
| `upper(s)` | Верхний регистр | `upper('abc')` → 'ABC' |
| `len(s)` | Длина | `len('hello')` → 5 |
| `trim(s)` | Обрезка пробелов | `trim(' hello ')` → 'hello' |
| `substr(s, start, len)` | Подстрока | `substr('hello', 0, 3)` → 'hel' |

## Регистрация функции

```nim
reg.register(
  name: "my_function",
  params: @[
    UDFParam(name: "arg1", typeName: "str"),
    UDFParam(name: "arg2", typeName: "int32")
  ],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    result = Value(kind: vkString, strVal: "")
)
```

## Использование UDF в запросах

```sql
SELECT greet(name) FROM users;
```