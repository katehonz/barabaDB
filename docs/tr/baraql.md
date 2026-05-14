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
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- Savepoint ile
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- Hata, savepoint'e geri al
ROLLBACK TO sp1;
COMMIT;
```

## Tam Metin Arama

```sql
-- Temel arama
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- İlgi puanı ile
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- Boolean modu
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- Fuzzy arama
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## Kullanıcı Tanımlı Fonksiyonlar

```sql
-- UDF kaydet
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- Kullan
SELECT greet(name) FROM users;

-- Dahili fonksiyonlar
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## Sorgu İpuçları

```sql
-- İndeks kullanımını zorla
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- Approximate vektör araması zorla
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- Paralel çalıştırma
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## Pencere Fonksiyonları

```sql
-- Sıralama fonksiyonları
SELECT
  name,
  department,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
  RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS r,
  DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dr
FROM employees;

-- Değer fonksiyonları
SELECT
  name,
  salary,
  LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_salary,
  LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_salary,
  FIRST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS cheapest,
  LAST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS most_expensive
FROM employees;

-- Dağılım fonksiyonları
SELECT name, NTILE(4) OVER (ORDER BY salary) AS quartile FROM employees;
```

### Çerçeve Spesifikasyonları

```sql
-- ROWS çerçevesi
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
)

-- RANGE çerçevesi
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## Çok Kiracılı ERP

BaraDB, **Satır Düzeyinde Güvenlik (RLS)** ve **oturum değişkenlerini** birleştirerek tek bir veritabanı örneğinde birden fazla şirketi (kiracı) çalıştırmayı destekler.

### Oturum Değişkenleri

```sql
SET app.tenant_id = 'company-123';
SELECT current_setting('app.tenant_id') AS tenant;
```

### Mevcut Kullanıcı / Rol

```sql
SELECT current_user AS me, current_role AS my_role;
```

### RLS Kiracı İzolasyonu

```sql
-- Tabloda RLS etkinleştir
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- Kiracıya göre filtreleme ilkesi oluştur
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- Her oturum yalnızca kendi verilerini görür
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- yalnızca company-a satırları
```

### Neden Çok Kiracılı?

- **Bir örnek, çok kiracı** — 100 ayrı veritabanı çalıştırmaya gerek yok
- **JSONB belgeleri** — Esnek şema depolama, her kiracı için kolayca alan ekleme
- **RLS izolasyonu garanti eder** — Veritabanı kiracı sınırlarını uygular, yalnızca uygulama değil

## Desteklenen Anahtar Kelimeler

| Kategori | Anahtar Kelimeler |
|----------|----------|
| DQL | SELECT, FROM, WHERE, ORDER BY, GROUP BY, HAVING, LIMIT, OFFSET, DISTINCT |
| DML | INSERT, UPDATE, DELETE, SET, VALUES |
| DDL | CREATE TYPE, DROP TYPE, CREATE INDEX, DROP INDEX, ALTER TYPE |
| Join | INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN, ON |
| Set | UNION, UNION ALL, INTERSECT, EXCEPT |
| CTEs | WITH, RECURSIVE, AS |
| Case | CASE, WHEN, THEN, ELSE, END |
| Transaction | BEGIN, COMMIT, ROLLBACK, SAVEPOINT |
| Graph | MATCH, RETURN, WHERE, shortestPath, type |
| FTS | MATCH, AGAINST, relevance, IN BOOLEAN MODE, WITH FUZZINESS |
| Vector | cosine_distance, euclidean_distance, inner_product, l1_distance, l2_distance, <-> |
| JSON | ->, ->> |
| FTS | @@ (BM25 eşleşme) |
| Recovery | RECOVER TO TIMESTAMP |
| Functions | count, sum, avg, min, max, stddev, variance, abs, sqrt, lower, upper, len, trim, substr, now, last_insert_id, current_setting |
| Session | SET, current_setting, current_user, current_role |
| Window | OVER, PARTITION BY, ROWS, RANGE, UNBOUNDED PRECEDING, CURRENT ROW, FOLLOWING |
| Window Functions | ROW_NUMBER, RANK, DENSE_RANK, LEAD, LAG, FIRST_VALUE, LAST_VALUE, NTILE |