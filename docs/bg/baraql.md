# BaraQL - Референция на Езика

BaraQL е SQL-съвместим език за заявки с разширения за графи, вектори и документи.

## Основни Заявки

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
DELETE FROM users WHERE name = 'Bob';
```

## Агрегати и Групиране

```sql
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;
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
```

## CTEs (Common Table Expressions)

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## CASE Изрази

```sql
SELECT name,
  CASE
    WHEN age < 18 THEN 'minor'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;
```

## Схема

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};
```

## Векторно Търсене

```sql
INSERT articles {
  title := 'Nim Programming',
  embedding := [0.1, 0.2, 0.3, ...]
};

SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, ...])
LIMIT 5;
```

## Графични Шаблони

```sql
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;
```

## Пълнотекстово Търсене

```sql
-- Създаване на FTS индекс
CREATE INDEX idx_fts ON articles(body) USING FTS;

-- Търсене с BM25 ранжиране
SELECT * FROM articles WHERE body @@ 'database programming';
```

## JSON Оператори

```sql
-- Извличане на JSON поле като JSON
SELECT data->'name' FROM users;

-- Извличане на JSON поле като текст
SELECT data->>'name' FROM users;
```

## Set Операции

```sql
SELECT name FROM customers
UNION ALL
SELECT name FROM suppliers;
```

## Възстановяване до Момент във Времето

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
```