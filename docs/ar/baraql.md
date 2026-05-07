# مرجع لغة استعلام BaraQL

BaraQL هي لغة استعلام متوافقة مع SQL مع امتدادات لعمليات الرسم البياني والمتجة والمستندات.

## أنواع البيانات

| النوع | الوصف | مثال |
|-------|-------|------|
| `null` | قيمة فارغة | `null` |
| `bool` | منطقي | `true`, `false` |
| `int8` | عدد صحيح 8 بت | `127` |
| `int16` | عدد صحيح 16 بت | `32767` |
| `int32` | عدد صحيح 32 بت | `2147483647` |
| `int64` | عدد صحيح 64 بت | `9223372036854775807` |
| `float32` | فاصلة عائمة 32 بت | `3.14` |
| `float64` | فاصلة عائمة 64 بت | `3.14159265359` |
| `str` | سلسلة UTF-8 | `'hello'` |
| `vector` | متجه float32 | `[0.1, 0.2, 0.3]` |
| `datetime` | طابع زمني ISO 8601 | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |

## الاستعلامات الأساسية

### SELECT

```sql
SELECT * FROM users;
SELECT name, age FROM users;
SELECT name AS full_name FROM users;
SELECT * FROM users LIMIT 10 OFFSET 20;
```

### WHERE

```sql
SELECT * FROM users WHERE age > 18;
SELECT * FROM users WHERE age BETWEEN 18 AND 65;
SELECT * FROM users WHERE department IN ('Engineering', 'Sales');
SELECT * FROM users WHERE name LIKE 'A%';
```

### INSERT

```sql
INSERT users { name := 'Alice', age := 30 };
```

### UPDATE

```sql
UPDATE users SET age = 31 WHERE name = 'Alice';
```

### DELETE

```sql
DELETE FROM users WHERE name = 'Bob';
```

## JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

## CTE (تعبيرات الجدول المشترك)

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## البحث المتجهي

```sql
INSERT articles { title := 'Nim Programming', embedding := [0.1, 0.2, 0.3, 0.4] };

SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;
```

## أنماط الرسم البياني

```sql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;
```

## المعاملات

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
COMMIT;
```