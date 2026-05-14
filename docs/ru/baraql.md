# Справочник по языку запросов BaraQL

BaraQL — это совместимый с SQL язык запросов с расширениями для графовых, векторных и документных операций.

## Типы данных

| Тип | Описание | Пример |
|------|----------|--------|
| `null` | Null значение | `null` |
| `bool` | Булевый | `true`, `false` |
| `int8` | 8-битное знаковое целое | `127` |
| `int16` | 16-битное знаковое целое | `32767` |
| `int32` | 32-битное знаковое целое | `2147483647` |
| `int64` | 64-битное знаковое целое | `9223372036854775807` |
| `float32` | 32-битное с плавающей точкой | `3.14` |
| `float64` | 64-битное с плавающей точкой | `3.14159265359` |
| `str` | UTF-8 строка | `'hello'` |
| `bytes` | Сырые байты | `0xDEADBEEF` |
| `array<T>` | Однородный массив | `[1, 2, 3]` |
| `vector` | Вектор float32 | `[0.1, 0.2, 0.3]` |
| `object` | Объект ключ-значение | `{"a": 1}` |
| `datetime` | timestamp ISO 8601 | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |
| `json` | JSON документ | `{"key": "value"}` |
| `jsonb` | Бинарный JSON (проверенный) | `{"key": "value"}` |

## Базовые запросы

### SELECT

```sql
-- Все столбцы
SELECT * FROM users;

-- Конкретные столбцы
SELECT name, age FROM users;

-- Псевдонимы
SELECT name AS full_name, age AS years FROM users;

-- DISTINCT
SELECT DISTINCT department FROM employees;

-- LIMIT и OFFSET
SELECT * FROM users LIMIT 10 OFFSET 20;
```

### WHERE

```sql
-- Операторы сравнения
SELECT * FROM users WHERE age > 18;
SELECT * FROM users WHERE age >= 18 AND age <= 65;
SELECT * FROM users WHERE name = 'Alice';
SELECT * FROM users WHERE name != 'Bob';

-- Диапазон
SELECT * FROM users WHERE age BETWEEN 18 AND 65;

-- Проверка принадлежности
SELECT * FROM users WHERE department IN ('Engineering', 'Sales');

-- Поиск по шаблону
SELECT * FROM users WHERE name LIKE 'A%';
SELECT * FROM users WHERE name ILIKE 'alice';  -- Без учёта регистра

-- Проверка на NULL
SELECT * FROM users WHERE email IS NOT NULL;

-- Логические операторы
SELECT * FROM users WHERE age > 18 AND (department = 'Engineering' OR department = 'Sales');
```

### ORDER BY

```sql
-- По возрастанию (по умолчанию)
SELECT * FROM users ORDER BY age;

-- По убыванию
SELECT * FROM users ORDER BY age DESC;

-- Несколько столбцов
SELECT * FROM users ORDER BY department ASC, age DESC;
```

### INSERT

```sql
-- Одна строка
INSERT users { name := 'Alice', age := 30 };

-- С явным типом
INSERT User { name := 'Alice', age := 30 };

-- Несколько строк
INSERT users {
  { name := 'Alice', age := 30 },
  { name := 'Bob', age := 25 }
};
```

### UPDATE

```sql
-- Обновить все строки
UPDATE users SET status = 'active';

-- Условное обновление
UPDATE users SET age = 31 WHERE name = 'Alice';

-- Обновить несколько столбцов
UPDATE users SET age = 32, status = 'premium' WHERE name = 'Alice';
```

### DELETE

```sql
-- Удалить все строки
DELETE FROM users;

-- Условное удаление
DELETE FROM users WHERE age < 18;
```

## Агрегация и группировка

### Агрегатные функции

| Функция | Описание |
|---------|----------|
| `count(*)` | Подсчёт всех строк |
| `count(column)` | Подсчёт не-NULL значений |
| `sum(column)` | Сумма значений |
| `avg(column)` | Среднее значение |
| `min(column)` | Минимальное значение |
| `max(column)` | Максимальное значение |
| `stddev(column)` | Стандартное отклонение |
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

-- Несколько группировок
SELECT department, role, count(*), avg(salary)
FROM employees
GROUP BY department, role;
```

## JOIN

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

-- Несколько JOIN
SELECT u.name, o.id, p.name
FROM orders o
JOIN users u ON o.user_id = u.id
JOIN products p ON o.product_id = p.id;

-- Self JOIN
SELECT e.name, m.name as manager
FROM employees e
JOIN employees m ON e.manager_id = m.id;
```

## CTE (Common Table Expressions)

```sql
-- Один CTE
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;

-- Несколько CTE
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

-- Рекурсивный CTE
WITH RECURSIVE subordinates AS (
  SELECT id, name, manager_id FROM employees WHERE name = 'CEO'
  UNION ALL
  SELECT e.id, e.name, e.manager_id
  FROM employees e
  JOIN subordinates s ON e.manager_id = s.id
)
SELECT * FROM subordinates;
```

## Подзапросы

```sql
-- Подзапрос в SELECT
SELECT name, (SELECT count(*) FROM orders WHERE user_id = u.id) as order_count
FROM users u;

-- Подзапрос в FROM
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- Подзапрос в WHERE (IN)
SELECT name FROM users WHERE id IN (SELECT user_id FROM orders);

-- Подзапрос в WHERE (EXISTS)
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);

-- Коррелированный подзапрос
SELECT name FROM users u
WHERE age > (SELECT avg(age) FROM users WHERE department = u.department);
```

## CASE выражения

```sql
SELECT name,
  CASE
    WHEN age < 13 THEN 'child'
    WHEN age < 20 THEN 'teenager'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;

-- Простой CASE
SELECT name,
  CASE department
    WHEN 'Engineering' THEN 'Tech'
    WHEN 'Sales' THEN 'Revenue'
    ELSE 'Other'
  END AS division
FROM employees;
```

## Операции над множествами

```sql
-- UNION (уникальные)
SELECT name FROM customers
UNION
SELECT name FROM suppliers;

-- UNION ALL (с дубликатами)
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

## Определение схемы

### CREATE TYPE

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

-- С обязательными полями
CREATE TYPE User {
  email: str REQUIRED,
  name: str,
  age: int32,
  created_at: datetime DEFAULT now()
};

-- Со связями
CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};

-- С вычисляемыми свойствами
CREATE TYPE Employee {
  name: str,
  base_salary: float64,
  bonus: float64,
  total_compensation: float64 COMPUTED (base_salary + bonus)
};
```

### Наследование

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

### Индексы

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

## Векторный поиск

```sql
-- Вставка с вектором
INSERT articles {
  title := 'Nim Programming',
  embedding := [0.1, 0.2, 0.3, 0.4]
};

-- Поиск по сходству (косинусное расстояние)
SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- Евклидово расстояние
SELECT title FROM articles
ORDER BY l2_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- Скалярное произведение
SELECT title FROM articles
ORDER BY dot_product(embedding, [0.1, 0.2, 0.3, 0.4]) DESC
LIMIT 5;

-- С фильтрацией по метаданным
SELECT title FROM articles
WHERE category = 'tech'
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;
```

## Графовые шаблоны

```sql
-- Найти друзей Alice
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;

-- Найти кратчайший путь
MATCH path = shortestPath((a:Person)-[:KNOWS*1..5]->(b:Person))
WHERE a.name = 'Alice' AND b.name = 'Bob'
RETURN path;

-- Найти все связи
MATCH (p:Person)-[r]->(other)
WHERE p.name = 'Alice'
RETURN type(r), other.name;

-- Несколько прыжков
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN c.name;

-- С агрегатами
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, count(friend) as friend_count
ORDER BY friend_count DESC;
```

## Полнотекстовый поиск

```sql
-- Базовый поиск
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- С оценкой релевантности
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- Булев режим
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- Нечёткий поиск
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## Транзакции

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- С точкой сохранения
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- Ой, откатываемся к точке сохранения
ROLLBACK TO sp1;
COMMIT;
```

## Пользовательские функции

```sql
-- Зарегистрировать UDF
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- Использовать
SELECT greet(name) FROM users;

-- Встроенные функции
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## Подсказки запросов

```sql
-- Принудительно использовать индекс
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- Принудительно приближённый векторный поиск
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- Параллельное выполнение
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## Оконные функции

```sql
-- Функции ранжирования
SELECT
  name,
  department,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
  RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS r,
  DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dr
FROM employees;

-- Функции значения
SELECT
  name,
  salary,
  LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_salary,
  LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_salary,
  FIRST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS cheapest,
  LAST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS most_expensive
FROM employees;

-- Функции распределения
SELECT name, NTILE(4) OVER (ORDER BY salary) AS quartile FROM employees;
```

### Спецификации фрейма

```sql
-- ROWS фрейм
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
)

-- RANGE фрейм
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## Мультитенантный ERP

BaraDB поддерживает работу нескольких компаний (арендаторов) в одной базе данных, используя **безопасность на уровне строк (RLS)** в сочетании с **переменными сессии**.

### Переменные сессии

```sql
SET app.tenant_id = 'company-123';
SELECT current_setting('app.tenant_id') AS tenant;
```

### Текущий пользователь / роль

```sql
SELECT current_user AS me, current_role AS my_role;
```

### Изоляция арендаторов через RLS

```sql
-- Включить RLS на таблице
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- Создать политику фильтрации по арендатору
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- Каждая сессия видит только свои данные
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- только строки company-a
```

### Зачем мультитенантность?

- **Один экземпляр, много арендаторов** — не нужно запускать 100 отдельных баз данных
- **JSONB документы** — гибкая схема, легко добавлять поля для каждого арендатора
- **RLS гарантирует изоляцию** — база данных обеспечивает границы арендаторов, а не только приложение

## Поддерживаемые ключевые слова

| Категория | Ключевые слова |
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