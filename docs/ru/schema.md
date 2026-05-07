# Система схем

BaraDB использует проектирование сначала схему с наследованием типов и автоматическими миграциями.

## Определение типов

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## Наследование типов

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)

let resolved = s.resolveInheritance(employee)
```

## Операции со схемой

### Diff

```nim
let diff = s.diff(oldSchema, newSchema)
```

### Миграции

Изменения схемы отслеживаются и могут генерировать скрипты миграции.

## Типы свойств

| Тип | Описание |
|-----|---------|
| `str` | Строка |
| `int32` | 32-битное целое |
| `int64` | 64-битное целое |
| `float32` | 32-битное с плавающей точкой |
| `float64` | 64-битное с плавающей точкой |
| `bool` | Булевый |
| `datetime` | Дата/время |
| `bytes` | Двоичные данные |