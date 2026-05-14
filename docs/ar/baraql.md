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
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- مع نقطة حفظ
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- خطأ، التراجع إلى نقطة الحفظ
ROLLBACK TO sp1;
COMMIT;
```

## البحث النصي الكامل

```sql
-- بحث أساسي
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- مع درجة الصلة
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- الوضع المنطقي
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- البحث الضبابي
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## الدوال المحددة من المستخدم

```sql
-- تسجيل UDF
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- استخدامها
SELECT greet(name) FROM users;

-- الدوال المدمجة
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## تلميحات الاستعلام

```sql
-- فرض استخدام الفهرس
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- فرض البحث المتجهي التقريبي
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- التنفيذ المتوازي
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## دوال النوافذ

```sql
-- دوال الترتيب
SELECT
  name,
  department,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
  RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS r,
  DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dr
FROM employees;

-- دوال القيمة
SELECT
  name,
  salary,
  LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_salary,
  LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_salary,
  FIRST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS cheapest,
  LAST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS most_expensive
FROM employees;

-- دوال التوزيع
SELECT name, NTILE(4) OVER (ORDER BY salary) AS quartile FROM employees;
```

### مواصفات الإطار

```sql
-- إطار ROWS
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
)

-- إطار RANGE
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## ERP متعدد المستأجرين

يدعم BaraDB تشغيل عدة شركات (مستأجرين) في مثيل قاعدة بيانات واحد، باستخدام **أمان مستوى الصف (RLS)** مع **متغيرات الجلسة**.

### متغيرات الجلسة

```sql
SET app.tenant_id = 'company-123';
SELECT current_setting('app.tenant_id') AS tenant;
```

### المستخدم / الدور الحالي

```sql
SELECT current_user AS me, current_role AS my_role;
```

### عزل المستأجر عبر RLS

```sql
-- تمكين RLS على جدول
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- إنشاء سياسة تصفية حسب المستأجر
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- كل جلسة ترى فقط بياناتها
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- صفوف company-a فقط
```

### لماذا متعدد المستأجرين؟

- **مثيل واحد، مستأجرون كثيرون** — لا حاجة لتشغيل 100 قاعدة بيانات منفصلة
- **مستندات JSONB** — تخزين مخطط مرن، سهل إضافة حقول لكل مستأجر
- **RLS يضمن العزل** — قاعدة البيانات تفرض حدود المستأجر، وليس فقط التطبيق

## الكلمات المفتاحية المدعومة

| الفئة | الكلمات المفتاحية |
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
| FTS | @@ (تطابق BM25) |
| Recovery | RECOVER TO TIMESTAMP |
| Functions | count, sum, avg, min, max, stddev, variance, abs, sqrt, lower, upper, len, trim, substr, now, last_insert_id, current_setting |
| Session | SET, current_setting, current_user, current_role |
| Window | OVER, PARTITION BY, ROWS, RANGE, UNBOUNDED PRECEDING, CURRENT ROW, FOLLOWING |
| Window Functions | ROW_NUMBER, RANK, DENSE_RANK, LEAD, LAG, FIRST_VALUE, LAST_VALUE, NTILE |