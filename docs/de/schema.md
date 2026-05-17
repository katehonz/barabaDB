# Schema-System

BaraDB verwendet ein Schema-first Design mit Typvererbung und automatischen Migrationen.

## Typen definieren

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## Typvererbung

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)

# Vererbung auflösen — Employee erhält name, age, department
let resolved = s.resolveInheritance(employee)
```

## Schema-Operationen

### Diff

Zwei Schemata vergleichen:

```nim
let diff = s.diff(oldSchema, newSchema)
```

### Migrationen

Schema-Änderungen werden verfolgt und können Migrationsskripte generieren.

## Eigenschaftstypen

| Typ | Beschreibung |
|------|-------------|
| `str` | String |
| `int32` | 32-Bit Integer |
| `int64` | 64-Bit Integer |
| `float32` | 32-Bit Float |
| `float64` | 64-Bit Float |
| `bool` | Boolean |
| `datetime` | Datums-/Zeitwert |
| `bytes` | Binärdaten |
