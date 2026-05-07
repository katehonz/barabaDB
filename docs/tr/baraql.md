# BaraQL - Sorgu Dili Referansı

BaraQL, grafik, vektör ve doküman operasyonları için uzantılarla SQL uyumlu bir sorgu dilidir.

## Veri Tipleri

| Tip | Açıklama | Örnek |
|-----|----------|-------|
| `null` | Boş değer | `null` |
| `bool` | Boolean | `true`, `false` |
| `int8` | 8-bit işaretli tamsayı | `127` |
| `int16` | 16-bit işaretli tamsayı | `32767` |
| `int32` | 32-bit işaretli tamsayı | `2147483647` |
| `int64` | 64-bit işaretli tamsayı | `9223372036854775807` |
| `float32` | 32-bit kayan nokta | `3.14` |
| `float64` | 64-bit kayan nokta | `3.14159265359` |
| `str` | UTF-8 string | `'hello'` |
| `vector` | Float32 vektör | `[0.1, 0.2, 0.3]` |
| `datetime` | ISO 8601 zaman damgası | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |

## Temel Sorgular

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
INSERT users { { name := 'Alice', age := 30 }, { name := 'Bob', age := 25 } };
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

## CTE (Common Table Expressions)

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## Vektör Arama

```sql
INSERT articles { title := 'Nim Programming', embedding := [0.1, 0.2, 0.3, 0.4] };

SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;
```

## Grafik Kalıpları

```sql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;
```

## İşlemler

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
COMMIT;
```

## Grafik Kalıpları

```sql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;
```