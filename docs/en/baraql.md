# BaraQL - Query Language Reference

BaraQL is a SQL-compatible query language with extensions for graph, vector, and document operations.

## Basic Queries

### SELECT

```sql
SELECT name, age FROM users WHERE age > 18 ORDER BY name LIMIT 10;
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
DELETE FROM users WHERE name = 'Alice';
```

## Aggregates and Grouping

```sql
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;

SELECT count(*), sum(amount), avg(price) FROM orders;
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

-- Multiple JOINs
SELECT *
FROM orders o
JOIN users u ON o.user_id = u.id
JOIN products p ON o.product_id = p.id;
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
  recent AS (SELECT * FROM orders WHERE date > '2025-01-01'),
  totals AS (SELECT user_id, sum(amount) as total FROM recent GROUP BY user_id)
SELECT u.name, t.total FROM users u JOIN totals t ON u.id = t.user_id;
```

## Subqueries

```sql
-- Subquery in FROM
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- EXISTS subquery
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);
```

## CASE Expressions

```sql
SELECT name,
  CASE
    WHEN age < 18 THEN 'minor'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;
```

## Schema Definition

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

CREATE TYPE Movie {
  title: str,
  director: Person
};
```

## Vector Search

```sql
-- Insert with vector
INSERT articles {
  title := 'Nim Programming',
  embedding := [0.1, 0.2, 0.3, ...]
};

-- Similarity search
SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, ...])
LIMIT 5;
```

## Graph Patterns

```sql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;
```

## Full-Text Search

```sql
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');
```

## Supported Keywords

| Category | Keywords |
|----------|----------|
| DQL | SELECT, FROM, WHERE, ORDER BY, GROUP BY, HAVING, LIMIT, OFFSET |
| DML | INSERT, UPDATE, DELETE, SET |
| DDL | CREATE TYPE, DROP TYPE, CREATE INDEX |
| Join | INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN |
| Set | UNION, INTERSECT, EXCEPT |
| CTEs | WITH, AS |
| Case | CASE, WHEN, THEN, ELSE, END |
| Graph | MATCH, RETURN, WHERE |
| FTS | MATCH, AGAINST |