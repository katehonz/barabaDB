# Schema System

BaraDB uses a schema-first design with type inheritance and automatic migrations.

## Defining Types

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## Type Inheritance

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)

# Resolve inheritance — Employee gets name, age, department
let resolved = s.resolveInheritance(employee)
```

## Schema Operations

### Diff

Compare two schemas:

```nim
let diff = s.diff(oldSchema, newSchema)
```

### Migrations

Schema changes are tracked and can generate migration scripts.

## Property Types

| Type | Description |
|------|-------------|
| `str` | String |
| `int32` | 32-bit integer |
| `int64` | 64-bit integer |
| `float32` | 32-bit float |
| `float64` | 64-bit float |
| `bool` | Boolean |
| `datetime` | Date/time value |
| `bytes` | Binary data |