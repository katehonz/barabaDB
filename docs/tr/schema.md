# Şema Sistemi

BaraDB tip mirası ve otomatik geçişlerle schema-first tasarımı kullanır.

## Tipleri Tanımlama

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## Tip Mirası

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)
```

## Şema İşlemleri

### Diff

```nim
let diff = s.diff(oldSchema, newSchema)
```

## Özellik Tipleri

| Tip | Açıklama |
|-----|----------|
| `str` | Dize |
| `int32` | 32-bit tamsayı |
| `int64` | 64-bit tamsayı |
| `float32` | 32-bit kayan nokta |
| `float64` | 64-bit kayan nokta |
| `bool` | Mantıksal |
| `datetime` | Tarih/zaman |
| `bytes` | İkili veri |