# مرجع زبان پرس‌وجو BaraQL

BaraQL یک زبان پرس‌وجو سازگار با SQL با افزونه‌هایی برای عملیات گراف، بردار و سند است.

## انواع داده

| نوع | توضیح | مثال |
|------|--------|------|
| `null` | مقدار تهی | `null` |
| `bool` | بولی | `true`, `false` |
| `int8` | عدد صحیح 8 بیتی علامت‌دار | `127` |
| `int16` | عدد صحیح 16 بیتی علامت‌دار | `32767` |
| `int32` | عدد صحیح 32 بیتی علامت‌دار | `2147483647` |
| `int64` | عدد صحیح 64 بیتی علامت‌دار | `9223372036854775807` |
| `float32` | عدد اعشاری 32 بیتی | `3.14` |
| `float64` | عدد اعشاری 64 بیتی | `3.14159265359` |
| `str` | رشته UTF-8 | `'hello'` |
| `bytes` | بایت‌های خام | `0xDEADBEEF` |
| `array<T>` | آرایه همگن | `[1, 2, 3]` |
| `vector` | بردار float32 | `[0.1, 0.2, 0.3]` |
| `object` | شیء کلید-مقدار | `{"a": 1}` |
| `datetime` | timestamp ISO 8601 | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |
| `json` | سند JSON | `{"key": "value"}` |
| `jsonb` | JSON باینری (تأیید‌شده) | `{"key": "value"}` |

## پرس‌وجوهای پایه

### SELECT

```sql
-- همه ستون‌ها
SELECT * FROM users;

-- ستون‌های خاص
SELECT name, age FROM users;

-- نام‌های مستعار
SELECT name AS full_name, age AS years FROM users;

-- DISTINCT
SELECT DISTINCT department FROM employees;

-- LIMIT و OFFSET
SELECT * FROM users LIMIT 10 OFFSET 20;
```

### WHERE

```sql
-- عملگرهای مقایسه‌ای
SELECT * FROM users WHERE age > 18;
SELECT * FROM users WHERE age >= 18 AND age <= 65;
SELECT * FROM users WHERE name = 'Alice';
SELECT * FROM users WHERE name != 'Bob';

-- بازه
SELECT * FROM users WHERE age BETWEEN 18 AND 65;

-- عضویت مجموعه
SELECT * FROM users WHERE department IN ('Engineering', 'Sales');

-- تطبیق الگو
SELECT * FROM users WHERE name LIKE 'A%';
SELECT * FROM users WHERE name ILIKE 'alice';  -- بدون حساسیت به حروف

-- بررسی NULL
SELECT * FROM users WHERE email IS NOT NULL;

-- عملگرهای منطقی
SELECT * FROM users WHERE age > 18 AND (department = 'Engineering' OR department = 'Sales');
```

### ORDER BY

```sql
-- صعودی (پیش‌فرض)
SELECT * FROM users ORDER BY age;

-- نزولی
SELECT * FROM users ORDER BY age DESC;

-- چند ستون
SELECT * FROM users ORDER BY department ASC, age DESC;
```

### INSERT

```sql
-- یک ردیف
INSERT users { name := 'Alice', age := 30 };

-- با نوع صریح
INSERT User { name := 'Alice', age := 30 };

-- چند ردیف
INSERT users {
  { name := 'Alice', age := 30 },
  { name := 'Bob', age := 25 }
};
```

### UPDATE

```sql
-- به‌روزرسانی همه ردیف‌ها
UPDATE users SET status = 'active';

-- به‌روزرسانی شرطی
UPDATE users SET age = 31 WHERE name = 'Alice';

-- به‌روزرسانی چند ستون
UPDATE users SET age = 32, status = 'premium' WHERE name = 'Alice';
```

### DELETE

```sql
-- حذف همه ردیف‌ها
DELETE FROM users;

-- حذف شرطی
DELETE FROM users WHERE age < 18;
```

## تجمیع و گروه‌بندی

### توابع تجمیعی

| تابع | توضیح |
|------|--------|
| `count(*)` | شمارش همه ردیف‌ها |
| `count(column)` | شمارش مقادیر غیر-NULL |
| `sum(column)` | مجموع مقادیر |
| `avg(column)` | میانگین |
| `min(column)` | کمینه |
| `max(column)` | بیشینه |
| `stddev(column)` | انحراف معیار |
| `variance(column)` | واریانس |

### GROUP BY

```sql
SELECT department, count(*) as emp_count, avg(salary) as avg_salary
FROM employees
GROUP BY department;

-- با HAVING
SELECT department, count(*) as emp_count
FROM employees
GROUP BY department
HAVING count(*) > 5;

-- گروه‌بندی چندگانه
SELECT department, role, count(*), avg(salary)
FROM employees
GROUP BY department, role;
```

## JOINها

```sql
-- INNER JOIN
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;

-- LEFT JOIN
SELECT u.name, o.total
FROM users u
LEFT JOIN orders o ON u.id = o.user_id;

-- RIGHT JOIN
SELECT u.name, o.total
FROM users u
RIGHT JOIN orders o ON u.id = o.user_id;

-- FULL JOIN
SELECT u.name, o.total
FROM users u
FULL JOIN orders o ON u.id = o.user_id;

-- CROSS JOIN
SELECT u.name, p.name
FROM users u
CROSS JOIN products p;

-- JOINهای چندگانه
SELECT u.name, o.id, p.name
FROM orders o
JOIN users u ON o.user_id = u.id
JOIN products p ON o.product_id = p.id;

-- Self JOIN
SELECT e.name, m.name as manager
FROM employees e
JOIN employees m ON e.manager_id = m.id;
```

## CTEها (عبارات جدول مشترک)

```sql
-- CTE واحد
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;

-- CTEهای چندگانه
WITH
  recent AS (
    SELECT * FROM orders WHERE date > '2025-01-01'
  ),
  totals AS (
    SELECT user_id, sum(amount) as total FROM recent GROUP BY user_id
  )
SELECT u.name, t.total
FROM users u
JOIN totals t ON u.id = t.user_id;

-- CTE بازگشتی
WITH RECURSIVE subordinates AS (
  SELECT id, name, manager_id FROM employees WHERE name = 'CEO'
  UNION ALL
  SELECT e.id, e.name, e.manager_id
  FROM employees e
  JOIN subordinates s ON e.manager_id = s.id
)
SELECT * FROM subordinates;
```

## زیرپرس‌وجوها

```sql
-- زیرپرس‌وجو در SELECT
SELECT name, (SELECT count(*) FROM orders WHERE user_id = u.id) as order_count
FROM users u;

-- زیرپرس‌وجو در FROM
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- زیرپرس‌وجو در WHERE (IN)
SELECT name FROM users WHERE id IN (SELECT user_id FROM orders);

-- زیرپرس‌وجو در WHERE (EXISTS)
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);

-- زیرپرس‌وجوی همبسته
SELECT name FROM users u
WHERE age > (SELECT avg(age) FROM users WHERE department = u.department);
```

## عبارات CASE

```sql
SELECT name,
  CASE
    WHEN age < 13 THEN 'child'
    WHEN age < 20 THEN 'teenager'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;

-- CASE ساده
SELECT name,
  CASE department
    WHEN 'Engineering' THEN 'Tech'
    WHEN 'Sales' THEN 'Revenue'
    ELSE 'Other'
  END AS division
FROM employees;
```

## عملیات مجموعه‌ای

```sql
-- UNION (متفاوت)
SELECT name FROM customers
UNION
SELECT name FROM suppliers;

-- UNION ALL (با تکرار)
SELECT name FROM customers
UNION ALL
SELECT name FROM suppliers;

-- INTERSECT
SELECT name FROM customers
INTERSECT
SELECT name FROM suppliers;

-- EXCEPT
SELECT name FROM customers
EXCEPT
SELECT name FROM suppliers;
```

## تعریف طرحواره

### CREATE TYPE

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

-- با فیلدهای الزامی
CREATE TYPE User {
  email: str REQUIRED,
  name: str,
  age: int32,
  created_at: datetime DEFAULT now()
};

-- با لینک‌ها
CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};

-- با ویژگی‌های محاسباتی
CREATE TYPE Employee {
  name: str,
  base_salary: float64,
  bonus: float64,
  total_compensation: float64 COMPUTED (base_salary + bonus)
};
```

### وراثت

```sql
CREATE TYPE Animal {
  name: str
};

CREATE TYPE Dog EXTENDING Animal {
  breed: str
};

CREATE TYPE Cat EXTENDING Animal {
  indoor: bool
};
```

### اندیس‌ها

```sql
CREATE INDEX idx_users_name ON users(name);
CREATE UNIQUE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_age ON users(age) USING btree;
```

### DROP

```sql
DROP TYPE User;
DROP INDEX idx_users_name;
```

## جستجوی برداری

```sql
-- درج با بردار
INSERT articles {
  title := 'Nim Programming',
  embedding := [0.1, 0.2, 0.3, 0.4]
};

-- جستجوی شباهت (فاصله کسینوسی)
SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- فاصله اقلیدسی
SELECT title FROM articles
ORDER BY l2_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- ضرب نقطه‌ای
SELECT title FROM articles
ORDER BY dot_product(embedding, [0.1, 0.2, 0.3, 0.4]) DESC
LIMIT 5;

-- با فیلتر ابرداده
SELECT title FROM articles
WHERE category = 'tech'
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;
```

## الگوهای گراف

```sql
-- یافتن دوستان Alice
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;

-- یافتن کوتاه‌ترین مسیر
MATCH path = shortestPath((a:Person)-[:KNOWS*1..5]->(b:Person))
WHERE a.name = 'Alice' AND b.name = 'Bob'
RETURN path;

-- یافتن همه روابط
MATCH (p:Person)-[r]->(other)
WHERE p.name = 'Alice'
RETURN type(r), other.name;

-- جهش‌های چندگانه
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN c.name;

-- با تجمیع‌ها
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, count(friend) as friend_count
ORDER BY friend_count DESC;
```

## جستجوی تمام‌متن

```sql
-- جستجوی پایه
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- با امتیاز ارتباط
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- حالت بولی
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- جستجوی تقریبی
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## تراکنش‌ها

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- با savepoint
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- اوپس، برگشت به savepoint
ROLLBACK TO sp1;
COMMIT;
```

## توابع تعریف‌شده کاربر

```sql
-- ثبت یک UDF
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- استفاده
SELECT greet(name) FROM users;

-- توابع داخلی
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## اشاره‌های پرس‌وجو

```sql
-- اجبار استفاده از اندیس
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- اجبار جستجوی برداری تقریبی
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- اجرای موازی
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## توابع پنجره‌ای

```sql
-- توابع رتبه‌بندی
SELECT
  name,
  department,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
  RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS r,
  DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dr
FROM employees;

-- توابع مقدار
SELECT
  name,
  salary,
  LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_salary,
  LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_salary,
  FIRST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS cheapest,
  LAST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS most_expensive
FROM employees;

-- توابع توزیع
SELECT name, NTILE(4) OVER (ORDER BY salary) AS quartile FROM employees;
```

### مشخصات فریم

```sql
-- فریم ROWS
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
)

-- فریم RANGE
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## ERP چند مستأجری

BaraDB از اجرای چندین شرکت (tenant) در یک نمونه پایگاه داده پشتیبانی می‌کند، با استفاده از **امنیت سطح سطر (RLS)** همراه با **متغیرهای جلسه**.

### متغیرهای جلسه

```sql
SET app.tenant_id = 'company-123';
SELECT current_setting('app.tenant_id') AS tenant;
```

### کاربر / نقش فعلی

```sql
SELECT current_user AS me, current_role AS my_role;
```

### جداسازی مستأجر با RLS

```sql
-- فعال کردن RLS روی جدول
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- ایجاد سیاست فیلترینگ بر اساس مستأجر
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- هر جلسه فقط داده‌های خود را می‌بیند
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- فقط ردیف‌های company-a
```

### چرا چند مستأجری؟

- **یک نمونه، مستأجران زیاد** — نیازی به اجرای ۱۰۰ پایگاه داده جداگانه نیست
- **اسناد JSONB** — ذخیره‌سازی با طرح انعطاف‌پذیر، افزودن آسان فیلدها برای هر مستأجر
- **RLS تضمین می‌کند** — پایگاه داده مرزهای مستأجر را اعمال می‌کند، نه فقط برنامه

## کلمات کلیدی پشتیبانی‌شده

| دسته | کلمات کلیدی |
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
| FTS | @@ (BM25 match) |
| Recovery | RECOVER TO TIMESTAMP |
| Functions | count, sum, avg, min, max, stddev, variance, abs, sqrt, lower, upper, len, trim, substr, now, last_insert_id, current_setting |
| Session | SET, current_setting, current_user, current_role |
| Window | OVER, PARTITION BY, ROWS, RANGE, UNBOUNDED PRECEDING, CURRENT ROW, FOLLOWING |
| Window Functions | ROW_NUMBER, RANK, DENSE_RANK, LEAD, LAG, FIRST_VALUE, LAST_VALUE, NTILE |