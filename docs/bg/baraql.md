# BaraQL - Референция на Езика

BaraQL е SQL-съвместим език за заявки с разширения за графи, вектори и документи.

## Типове Данни

| Тип | Описание | Пример |
|------|----------|--------|
| `null` | Null стойност | `null` |
| `bool` | Булев | `true`, `false` |
| `int8` | 8-битов signed integer | `127` |
| `int16` | 16-битов signed integer | `32767` |
| `int32` | 32-битов signed integer | `2147483647` |
| `int64` | 64-битов signed integer | `9223372036854775807` |
| `float32` | 32-битов float | `3.14` |
| `float64` | 64-битов float | `3.14159265359` |
| `str` | UTF-8 низ | `'hello'` |
| `bytes` | Сурови байтове | `0xDEADBEEF` |
| `array<T>` | Хомогенен масив | `[1, 2, 3]` |
| `vector` | Float32 вектор | `[0.1, 0.2, 0.3]` |
| `vector(n)` | Float32 вектор с фиксирана размерност (SQL) | `VECTOR(768)` |
| `object` | Ключ-стойност обект | `{"a": 1}` |
| `datetime` | ISO 8601 времеви печат | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |
| `json` | JSON документ | `{"key": "value"}` |
| `jsonb` | Бинарен JSON (валидиран) | `{"key": "value"}` |

## Основни Заявки

### SELECT

```sql
-- Всички колони
SELECT * FROM users;

-- Конкретни колони
SELECT name, age FROM users;

-- Псевдоними
SELECT name AS full_name, age AS years FROM users;

-- DISTINCT
SELECT DISTINCT department FROM employees;

-- LIMIT и OFFSET
SELECT * FROM users LIMIT 10 OFFSET 20;
```

### WHERE

```sql
-- Оператори за сравнение
SELECT * FROM users WHERE age > 18;
SELECT * FROM users WHERE age >= 18 AND age <= 65;
SELECT * FROM users WHERE name = 'Alice';
SELECT * FROM users WHERE name != 'Bob';

-- Диапазон
SELECT * FROM users WHERE age BETWEEN 18 AND 65;

-- Принадлежност към множество
SELECT * FROM users WHERE department IN ('Engineering', 'Sales');

-- Търсене по шаблон
SELECT * FROM users WHERE name LIKE 'A%';
SELECT * FROM users WHERE name ILIKE 'alice';  -- Case-insensitive

-- NULL проверки
SELECT * FROM users WHERE email IS NOT NULL;

-- Логически оператори
SELECT * FROM users WHERE age > 18 AND (department = 'Engineering' OR department = 'Sales');
```

### ORDER BY

```sql
-- Възходящ (по подразбиране)
SELECT * FROM users ORDER BY age;

-- Низходящ
SELECT * FROM users ORDER BY age DESC;

-- Множество колони
SELECT * FROM users ORDER BY department ASC, age DESC;
```

### INSERT

```sql
-- Един ред
INSERT users { name := 'Alice', age := 30 };

-- С явен тип
INSERT User { name := 'Alice', age := 30 };

-- Множество редове
INSERT users {
  { name := 'Alice', age := 30 },
  { name := 'Bob', age := 25 }
};
```

### UPDATE

```sql
-- Обнови всички редове
UPDATE users SET status = 'active';

-- Условно обновяване
UPDATE users SET age = 31 WHERE name = 'Alice';

-- Обновяване на няколко колони
UPDATE users SET age = 32, status = 'premium' WHERE name = 'Alice';
```

### DELETE

```sql
-- Изтрий всички редове
DELETE FROM users;

-- Условно изтриване
DELETE FROM users WHERE age < 18;
```

## Агрегати и Групиране

### Агрегатни Функции

| Функция | Описание |
|----------|-----------|
| `count(*)` | Брой на всички редове |
| `count(column)` | Брой на не-NULL стойности |
| `sum(column)` | Сума на стойностите |
| `avg(column)` | Средно аритметично |
| `min(column)` | Минимална стойност |
| `max(column)` | Максимална стойност |
| `stddev(column)` | Стандартно отклонение |
| `variance(column)` | Дисперсия |

### GROUP BY

```sql
SELECT department, count(*) as emp_count, avg(salary) as avg_salary
FROM employees
GROUP BY department;

-- С HAVING
SELECT department, count(*) as emp_count
FROM employees
GROUP BY department
HAVING count(*) > 5;

-- Множествено групиране
SELECT department, role, count(*), avg(salary)
FROM employees
GROUP BY department, role;
```

## JOINs

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

-- Множество JOINs
SELECT u.name, o.id, p.name
FROM orders o
JOIN users u ON o.user_id = u.id
JOIN products p ON o.product_id = p.id;

-- Self JOIN
SELECT e.name, m.name as manager
FROM employees e
JOIN employees m ON e.manager_id = m.id;
```

## CTEs (Common Table Expressions)

```sql
-- Единичен CTE
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;

-- Множество CTEs
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

-- Рекурсивен CTE
WITH RECURSIVE subordinates AS (
  SELECT id, name, manager_id FROM employees WHERE name = 'CEO'
  UNION ALL
  SELECT e.id, e.name, e.manager_id
  FROM employees e
  JOIN subordinates s ON e.manager_id = s.id
)
SELECT * FROM subordinates;
```

## Подзаявки

```sql
-- Подзаявка в SELECT
SELECT name, (SELECT count(*) FROM orders WHERE user_id = u.id) as order_count
FROM users u;

-- Подзаявка в FROM
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- Подзаявка в WHERE (IN)
SELECT name FROM users WHERE id IN (SELECT user_id FROM orders);

-- Подзаявка в WHERE (EXISTS)
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);

-- Корелирана подзаявка
SELECT name FROM users u
WHERE age > (SELECT avg(age) FROM users WHERE department = u.department);
```

## CASE Изрази

```sql
SELECT name,
  CASE
    WHEN age < 13 THEN 'child'
    WHEN age < 20 THEN 'teenager'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;

-- Прост CASE
SELECT name,
  CASE department
    WHEN 'Engineering' THEN 'Tech'
    WHEN 'Sales' THEN 'Revenue'
    ELSE 'Other'
  END AS division
FROM employees;
```

## Set Операции

```sql
-- UNION (различни)
SELECT name FROM customers
UNION
SELECT name FROM suppliers;

-- UNION ALL (с дубликати)
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

## Дефиниране на Схема

### CREATE TYPE

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

-- Със задължителни полета
CREATE TYPE User {
  email: str REQUIRED,
  name: str,
  age: int32,
  created_at: datetime DEFAULT now()
};

-- С връзки
CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};

-- С изчислими свойства
CREATE TYPE Employee {
  name: str,
  base_salary: float64,
  bonus: float64,
  total_compensation: float64 COMPUTED (base_salary + bonus)
};
```

### Наследяване

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

### Индекси

```sql
CREATE INDEX idx_users_name ON users(name);
CREATE UNIQUE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_age ON users(age) USING btree;
CREATE INDEX idx_vectors ON items(embedding) USING hnsw;
```

### DROP

```sql
DROP TYPE User;
DROP INDEX idx_users_name;
```

### JSON Оператори за Път

```sql
-- Извличане на JSON поле като JSON
SELECT data->'name' FROM users;

-- Извличане на JSON поле като текст
SELECT data->>'name' FROM users;
```

### Пълнотекстово Търсене (SQL)

```sql
-- Създаване на FTS индекс с BM25
CREATE INDEX idx_fts ON articles(body) USING FTS;

-- Търсене с BM25 ранжиране
SELECT * FROM articles WHERE body @@ 'machine learning';
```

### Възстановяване до Момент във Времето

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```

## Векторно Търсене (SQL)

### Създаване на Векторни Колони

```sql
CREATE TABLE items (
  id INT PRIMARY KEY,
  embedding VECTOR(768)
);
```

### Вмъкване на Вектори

```sql
INSERT INTO items (id, embedding) VALUES (1, '[0.1, 0.2, 0.3, 0.4]');
```

### Функции за Разстояние

```sql
-- Косинусово разстояние (0 = идентични, 2 = противоположни)
SELECT id, cosine_distance(embedding, '[0.1, 0.2, 0.3, 0.4]') AS dist
FROM items;

-- Евклидово / L2 разстояние
SELECT id, euclidean_distance(embedding, '[0.1, 0.2, 0.3, 0.4]') AS dist
FROM items;

-- L2 разстояние с <-> оператор
SELECT id, embedding <-> '[0.1, 0.2, 0.3, 0.4]' AS dist
FROM items;

-- Скаларно произведение (отрицателно dot product)
SELECT id, inner_product(embedding, '[0.1, 0.2, 0.3, 0.4]') AS dist
FROM items;

-- Манхатън / L1 разстояние
SELECT id, l1_distance(embedding, '[0.1, 0.2, 0.3, 0.4]') AS dist
FROM items;
```

### Търсене на Най-близки Съседи

```sql
-- Топ-10 най-близки съседи по косинусово разстояние
SELECT id FROM items
ORDER BY cosine_distance(embedding, '[0.1, 0.2, 0.3, 0.4]') ASC
LIMIT 10;

-- Топ-5 най-близки съседи по евклидово разстояние
SELECT id FROM items
ORDER BY embedding <-> '[0.1, 0.2, 0.3, 0.4]'
LIMIT 5;

-- С филтър по метаданни
SELECT id FROM items
WHERE category = 'tech'
ORDER BY cosine_distance(embedding, '[0.1, 0.2, 0.3, 0.4]')
LIMIT 5;
```

### Векторни Индекси

```sql
-- Създаване на HNSW индекс за приблизително търсене на най-близки съседи
CREATE INDEX idx_items_vec ON items(embedding) USING hnsw;

-- Поддържани индекс методи: hnsw, ivfpq
```

## Графични Шаблони

```sql
-- Намиране на приятели на Alice
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;

-- Намиране на най-кратък път
MATCH path = shortestPath((a:Person)-[:KNOWS*1..5]->(b:Person))
WHERE a.name = 'Alice' AND b.name = 'Bob'
RETURN path;

-- Намиране на всички връзки
MATCH (p:Person)-[r]->(other)
WHERE p.name = 'Alice'
RETURN type(r), other.name;

-- Множество преходи
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN c.name;

-- С агрегати
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, count(friend) as friend_count
ORDER BY friend_count DESC;
```

## Пълнотекстово Търсене

```sql
-- Основно търсене
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- С релевантност
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- Булев режим
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- Fuzzy търсене
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## Транзакции

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- С savepoint
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- Грешка, връщане до savepoint
ROLLBACK TO sp1;
COMMIT;
```

## Потребителски Функции (UDF)

```sql
-- Регистриране на UDF
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- Използване
SELECT greet(name) FROM users;

-- Вградени функции
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## Подсказки за Заявки (Query Hints)

```sql
-- Форсиране на индекс
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- Форсиране на приблизително векторно търсене
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- Паралелно изпълнение
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## Window Функции

```sql
-- Функции за ранжиране
SELECT
  name,
  department,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
  RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS r,
  DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dr
FROM employees;

-- Стойностни функции
SELECT
  name,
  salary,
  LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_salary,
  LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_salary,
  FIRST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS cheapest,
  LAST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS most_expensive
FROM employees;

-- Функции за разпределение
SELECT name, NTILE(4) OVER (ORDER BY salary) AS quartile FROM employees;
```

### Рамкови Спецификации

```sql
-- ROWS рамка
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
)

-- RANGE рамка
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## Multi-Tenant ERP

BaraDB поддържа множество компании (тенанти) в една инстанция чрез **Row-Level Security (RLS)** и **сесийни променливи**.

### Сесийни Променливи

```sql
SET app.tenant_id = 'company-123';
SELECT current_setting('app.tenant_id') AS tenant;
```

### Текущ Потребител / Роля

```sql
SELECT current_user AS me, current_role AS my_role;
```

### RLS Изолация на Тенанти

```sql
-- Включване на RLS за таблица
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- Създаване на политика за филтриране по тенант
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- Всяка сесия вижда само своите данни
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- само редове на company-a
```

### Защо Multi-Tenant?

- **Една инстанция, много тенанти** — няма нужда от 100 отделни бази данни
- **JSONB документи** — гъвкаво съхранение без схема, лесно добавяне на полета за всеки тенант
- **RLS гарантира изолация** — базата данни налага границите между тенанти, не само приложението

## Поддържани Ключови Думи

| Категория | Ключови думи |
|-----------|-------------|
| DQL | SELECT, FROM, WHERE, ORDER BY, GROUP BY, HAVING, LIMIT, OFFSET, DISTINCT |
| DML | INSERT, UPDATE, DELETE, SET, VALUES |
| DDL | CREATE TYPE, DROP TYPE, CREATE INDEX, DROP INDEX, ALTER TYPE |
| Join | INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN, ON |
| Set | UNION, UNION ALL, INTERSECT, EXCEPT |
| CTEs | WITH, RECURSIVE, AS |
| Case | CASE, WHEN, THEN, ELSE, END |
| Транзакции | BEGIN, COMMIT, ROLLBACK, SAVEPOINT |
| Графи | MATCH, RETURN, WHERE, shortestPath, type |
| FTS | MATCH, AGAINST, relevance, IN BOOLEAN MODE, WITH FUZZINESS |
| Вектори | cosine_distance, euclidean_distance, inner_product, l1_distance, l2_distance, <-> |
| JSON | ->, ->> |
| FTS | @@ (BM25 съвпадение) |
| Recovery | RECOVER TO TIMESTAMP |
| Функции | count, sum, avg, min, max, stddev, variance, abs, sqrt, lower, upper, len, trim, substr, now, last_insert_id, current_setting |
| Сесийни | SET, current_setting, current_user, current_role |
| Window | OVER, PARTITION BY, ROWS, RANGE, UNBOUNDED PRECEDING, CURRENT ROW, FOLLOWING |
| Window Функции | ROW_NUMBER, RANK, DENSE_RANK, LEAD, LAG, FIRST_VALUE, LAST_VALUE, NTILE |
