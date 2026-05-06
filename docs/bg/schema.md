# Схема на BaraDB

BaraDB използва схема с типове, наследяване и автоматични миграции.

## Дефиниране на Типове

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## Наследяване на Типове

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)

let resolved = s.resolveInheritance(employee)
```

## Типове Полета

| Тип | Описание |
|-----|---------|
| `str` | Низ |
| `int32` | 32-битово цяло число |
| `int64` | 64-битово цяло число |
| `float32` | 32-битов float |
| `float64` | 64-битов float |
| `bool` | Булева стойност |
| `datetime` | Дата/час |
| `bytes` | Двоични данни |