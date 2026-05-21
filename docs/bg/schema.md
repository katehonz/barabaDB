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

## SQL Миграции

BaraDB поддържа SQL миграции, изпълнявани чрез BaraQL:

```sql
-- Създаване на миграционна таблица
CREATE MIGRATION TABLE my_migration;

-- Прилагане на чакащи миграции
MIGRATION UP;

-- Rollback на последната миграция
MIGRATION DOWN;

-- Прилагане на всички чакащи миграции наведнъж
MIGRATION UP BATCH;

-- Dry-run за преглед на промените
MIGRATION DRYRUN;

-- Проверка на статуса
MIGRATION STATUS;
```

Миграционните скриптове се съхраняват вътре в LSMTree на всяка база данни и са изолирани per database. При използване на множество бази, изпълнете `USE DATABASE <име>` преди миграционните команди.

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