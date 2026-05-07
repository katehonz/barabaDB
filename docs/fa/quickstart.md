# راهنمای شروع سریع BaraDB

## شروع سرور

پس از ساخت BaraDB، سرور را_START کنید:

```bash
./build/baradadb
```

سرور به‌صورت پیش‌فرض روی `localhost:9470` شروع می‌شود.

## اتصال از طریق CLI

BaraDB شامل یک شل تعاملی است:

```bash
./build/baradadb --shell
```

## عملیات پایه

### ایجاد طرحواره

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};
```

### درج داده

```sql
INSERT Person { name := 'Alice', age := 30 };
INSERT Person { name := 'Bob', age := 25 };
```

### پرس‌وجوی داده

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### به‌روزرسانی داده

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### حذف داده

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## پرس‌وجوهای پیشرفته

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### تجمیع‌ها

```sql
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;
```

### CTEها

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## جستجوی برداری

```sql
-- درج بردار
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };

-- جستجوی مشابه
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## عملیات گراف

```sql
-- تطبیق الگوی گراف
MATCH (p:Person)-[:KNOWS]->(other:Person)
WHERE p.name = 'Alice'
RETURN other.name;
```

## جستجوی تمام‌متن

```sql
-- جستجوی اسناد
SELECT * FROM articles WHERE MATCH(title, body) AGAINST('database');
```

## HTTP/REST API

```bash
# درخواست GET
curl http://localhost:9470/api/users

# درخواست POST
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## مراحل بعدی

- [مرجع BaraQL](baraql.md)
- [موتورهای ذخیره‌سازی](storage.md)
- [بررسی معماری](architecture.md)
- [مرجع پروتکل](protocol.md)