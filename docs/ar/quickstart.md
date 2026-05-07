# دليل البداية السريعة لـ BaraDB

## تشغيل الخادم

```bash
./build/baradadb
```

الخادم يبدأ افتراضياً على `localhost:9470`.

## الاتصال عبر CLI

```bash
./build/baradadb --shell
```

## العمليات الأساسية

### إنشاء المخطط

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};
```

### إدراج البيانات

```sql
INSERT Person { name := 'Alice', age := 30 };
```

### استعلام البيانات

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### تحديث البيانات

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### حذف البيانات

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## الاستعلامات المتقدمة

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### CTE

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## البحث المتجهي

```sql
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## عمليات الرسم البياني

```sql
MATCH (p:Person)-[:KNOWS]->(other:Person)
WHERE p.name = 'Alice'
RETURN other.name;
```

## HTTP/REST API

```bash
curl http://localhost:9470/api/users
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## الخطوات التالية

- [مرجع BaraQL](baraql.md)
- [محركات التخزين](storage.md)
- [نظرة عامة على البنية](architecture.md)