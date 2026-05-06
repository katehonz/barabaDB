# BaraQL - Query Language Reference

BaraQL is a SQL-compatible query language with extensions for graph, vector, and document operations.

## Data Types

| Type | Description | Example |
|------|-------------|---------|
| `null` | Null value | `null` |
| `bool` | Boolean | `true`, `false` |
| `int8` | 8-bit signed integer | `127` |
| `int16` | 16-bit signed integer | `32767` |
| `int32` | 32-bit signed integer | `2147483647` |
| `int64` | 64-bit signed integer | `9223372036854775807` |
| `float32` | 32-bit float | `3.14` |
| `float64` | 64-bit float | `3.14159265359` |
| `str` | UTF-8 string | `'hello'` |
| `bytes` | Raw bytes | `0xDEADBEEF` |
| `array<T>` | Homogeneous array | `[1, 2, 3]` |
| `vector` | Float32 vector | `[0.1, 0.2, 0.3]` |
| `object` | Key-value object | `{"a": 1}` |
| `datetime` | ISO 8601 timestamp | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |
| `json` | JSON document | `{"key": "value"}` |

## Basic Queries

### SELECT

```sql
-- All columns
SELECT * FROM users;

-- Specific columns
SELECT name, age FROM users;

-- Aliases
SELECT name AS full_name, age AS years FROM users;

-- DISTINCT
SELECT DISTINCT department FROM employees;

-- LIMIT and OFFSET
SELECT * FROM users LIMIT 10 OFFSET 20;
```

### WHERE

```sql
-- Comparison operators
SELECT * FROM users WHERE age > 18;
SELECT * FROM users WHERE age >= 18 AND age <= 65;
SELECT * FROM users WHERE name = 'Alice';
SELECT * FROM users WHERE name != 'Bob';

-- Range
SELECT * FROM users WHERE age BETWEEN 18 AND 65;

-- Set membership
SELECT * FROM users WHERE department IN ('Engineering', 'Sales');

-- Pattern matching
SELECT * FROM users WHERE name LIKE 'A%';
SELECT * FROM users WHERE name ILIKE 'alice';  -- Case-insensitive

-- NULL checks
SELECT * FROM users WHERE email IS NOT NULL;

-- Logical operators
SELECT * FROM users WHERE age > 18 AND (department = 'Engineering' OR department = 'Sales');
```

### ORDER BY

```sql
-- Ascending (default)
SELECT * FROM users ORDER BY age;

-- Descending
SELECT * FROM users ORDER BY age DESC;

-- Multiple columns
SELECT * FROM users ORDER BY department ASC, age DESC;
```

### INSERT

```sql
-- Single row
INSERT users { name := 'Alice', age := 30 };

-- With explicit type
INSERT User { name := 'Alice', age := 30 };

-- Multiple rows
INSERT users {
  { name := 'Alice', age := 30 },
  { name := 'Bob', age := 25 }
};
```

### UPDATE

```sql
-- Update all rows
UPDATE users SET status = 'active';

-- Conditional update
UPDATE users SET age = 31 WHERE name = 'Alice';

-- Update multiple columns
UPDATE users SET age = 32, status = 'premium' WHERE name = 'Alice';
```

### DELETE

```sql
-- Delete all rows
DELETE FROM users;

-- Conditional delete
DELETE FROM users WHERE age < 18;
```

## Aggregates and Grouping

### Aggregate Functions

| Function | Description |
|----------|-------------|
| `count(*)` | Count all rows |
| `count(column)` | Count non-NULL values |
| `sum(column)` | Sum of values |
| `avg(column)` | Average |
| `min(column)` | Minimum value |
| `max(column)` | Maximum value |
| `stddev(column)` | Standard deviation |
| `variance(column)` | Variance |

### GROUP BY

```sql
SELECT department, count(*) as emp_count, avg(salary) as avg_salary
FROM employees
GROUP BY department;

-- With HAVING
SELECT department, count(*) as emp_count
FROM employees
GROUP BY department
HAVING count(*) > 5;

-- Multiple groupings
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

-- Multiple JOINs
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
-- Single CTE
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;

-- Multiple CTEs
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

-- Recursive CTE
WITH RECURSIVE subordinates AS (
  SELECT id, name, manager_id FROM employees WHERE name = 'CEO'
  UNION ALL
  SELECT e.id, e.name, e.manager_id
  FROM employees e
  JOIN subordinates s ON e.manager_id = s.id
)
SELECT * FROM subordinates;
```

## Subqueries

```sql
-- Subquery in SELECT
SELECT name, (SELECT count(*) FROM orders WHERE user_id = u.id) as order_count
FROM users u;

-- Subquery in FROM
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- Subquery in WHERE (IN)
SELECT name FROM users WHERE id IN (SELECT user_id FROM orders);

-- Subquery in WHERE (EXISTS)
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);

-- Correlated subquery
SELECT name FROM users u
WHERE age > (SELECT avg(age) FROM users WHERE department = u.department);
```

## CASE Expressions

```sql
SELECT name,
  CASE
    WHEN age < 13 THEN 'child'
    WHEN age < 20 THEN 'teenager'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;

-- Simple CASE
SELECT name,
  CASE department
    WHEN 'Engineering' THEN 'Tech'
    WHEN 'Sales' THEN 'Revenue'
    ELSE 'Other'
  END AS division
FROM employees;
```

## Set Operations

```sql
-- UNION (distinct)
SELECT name FROM customers
UNION
SELECT name FROM suppliers;

-- UNION ALL (with duplicates)
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

## Schema Definition

### CREATE TYPE

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

-- With required fields
CREATE TYPE User {
  email: str REQUIRED,
  name: str,
  age: int32,
  created_at: datetime DEFAULT now()
};

-- With links
CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};

-- With computed properties
CREATE TYPE Employee {
  name: str,
  base_salary: float64,
  bonus: float64,
  total_compensation: float64 COMPUTED (base_salary + bonus)
};
```

### Inheritance

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

### Indexes

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

## Vector Search

```sql
-- Insert with vector
INSERT articles {
  title := 'Nim Programming',
  embedding := [0.1, 0.2, 0.3, 0.4]
};

-- Similarity search (cosine distance)
SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- Euclidean distance
SELECT title FROM articles
ORDER BY l2_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- Dot product
SELECT title FROM articles
ORDER BY dot_product(embedding, [0.1, 0.2, 0.3, 0.4]) DESC
LIMIT 5;

-- With metadata filter
SELECT title FROM articles
WHERE category = 'tech'
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;
```

## Graph Patterns

```sql
-- Find friends of Alice
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;

-- Find shortest path
MATCH path = shortestPath((a:Person)-[:KNOWS*1..5]->(b:Person))
WHERE a.name = 'Alice' AND b.name = 'Bob'
RETURN path;

-- Find all relationships
MATCH (p:Person)-[r]->(other)
WHERE p.name = 'Alice'
RETURN type(r), other.name;

-- Multiple hops
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN c.name;

-- With aggregates
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, count(friend) as friend_count
ORDER BY friend_count DESC;
```

## Full-Text Search

```sql
-- Basic search
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- With relevance score
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- Boolean mode
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- Fuzzy search
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## Transactions

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- With savepoint
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- Oops, rollback to savepoint
ROLLBACK TO sp1;
COMMIT;
```

## User-Defined Functions

```sql
-- Register a UDF
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- Use it
SELECT greet(name) FROM users;

-- Built-in functions
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## Query Hints

```sql
-- Force index usage
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- Force approximate vector search
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- Parallel execution
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## Supported Keywords

| Category | Keywords |
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
| Vector | cosine_distance, l2_distance, dot_product, manhattan_distance |
| Functions | count, sum, avg, min, max, stddev, variance, abs, sqrt, lower, upper, len, trim, substr, now, last_insert_id |
