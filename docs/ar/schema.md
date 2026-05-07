# نظام المخطط

يستخدم BaraDB تصميم schema-first مع وراثة النوع والهجرة التلقائية.

## تحديد الأنواع

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## وراثة النوع

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)
```

## عمليات المخطط

### Diff

```nim
let diff = s.diff(oldSchema, newSchema)
```

## أنواع الخصائص

| النوع | الوصف |
|-------|-------|
| `str` | سلسلة |
| `int32` | عدد صحيح 32 بت |
| `int64` | عدد صحيح 64 بت |
| `float32` | فاصلة عائمة 32 بت |
| `float64` | فاصلة عائمة 64 بت |
| `bool` | منطقي |
| `datetime` | تاريخ/وقت |
| `bytes` | بيانات ثنائية |