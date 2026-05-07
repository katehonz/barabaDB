# سیستم طرحواره

BaraDB از طراحی schema-first با وراثت نوع و مهاجرت‌های خودکار استفاده می‌کند.

## تعریف انواع

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## وراثت نوع

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)
```

## عملیات طرحواره

### Diff

```nim
let diff = s.diff(oldSchema, newSchema)
```

## انواع ویژگی

| نوع | توضیح |
|-----|--------|
| `str` | رشته |
| `int32` | عدد صحیح 32 بیتی |
| `int64` | عدد صحیح 64 بیتی |
| `float32` | عدد اعشاری 32 بیتی |
| `float64` | عدد اعشاری 64 بیتی |
| `bool` | بولی |
| `datetime` | تاریخ/زمان |
| `bytes` | داده باینری |