# 模式系统

BaraDB 使用 schema-first 设计，支持类型继承和自动迁移。

## 定义类型

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)
```

## 类型继承

```nim
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)
```

## 模式操作

### Diff

```nim
let diff = s.diff(oldSchema, newSchema)
```

## 属性类型

| 类型 | 描述 |
|------|------|
| `str` | 字符串 |
| `int32` | 32 位整数 |
| `int64` | 64 位整数 |
| `float32` | 32 位浮点数 |
| `float64` | 64 位浮点数 |
| `bool` | 布尔值 |
| `datetime` | 日期/时间 |
| `bytes` | 二进制数据 |