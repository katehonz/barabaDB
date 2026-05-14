# Потребителски Функции (UDF)

Разширете BaraQL с персонализирани функции.

## Употреба

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

# Регистриране на стандартна библиотека
reg.registerStdlib()  # abs, sqrt, pow, lower, upper, len, trim, substr, toString, toInt

# Персонализирана функция
reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## Функции от Стандартната Библиотека

| Функция | Описание | Пример |
|----------|----------|--------|
| `abs(n)` | Абсолютна стойност | `abs(-5)` → 5 |
| `sqrt(n)` | Квадратен корен | `sqrt(16)` → 4 |
| `pow(n, e)` | Степенуване | `pow(2, 3)` → 8 |
| `lower(s)` | Малки букви | `lower('ABC')` → 'abc' |
| `upper(s)` | Главни букви | `upper('abc')` → 'ABC' |
| `len(s)` | Дължина | `len('hello')` → 5 |
| `trim(s)` | Премахване на интервали | `trim(' hello ')` → 'hello' |
| `substr(s, start, len)` | Подниз | `substr('hello', 0, 3)` → 'hel' |
| `toString(n)` | Конвертиране в низ | `toString(123)` → '123' |
| `toInt(s)` | Конвертиране в integer | `toInt('123')` → 123 |

## Регистриране на Функции

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

## Използване на UDF в Заявки

```sql
SELECT greet(name) FROM users;
```
