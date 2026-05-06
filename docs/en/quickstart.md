# BaraDB - Quick Start Guide

## Starting the Server

After building BaraDB, start the server:

```bash
./build/baradadb
```

The server will start on `localhost:9470` by default.

## Connecting via CLI

BaraDB includes an interactive shell:

```bash
./build/baradadb --shell
```

## Basic Operations

### Create Schema

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

### Insert Data

```sql
INSERT Person { name := 'Alice', age := 30 };
INSERT Person { name := 'Bob', age := 25 };
```

### Query Data

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### Update Data

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### Delete Data

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## Advanced Queries

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### Aggregates

```sql
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;
```

### CTEs

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## Vector Search

```sql
-- Insert vector
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };

-- Search similar
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## Graph Operations

```sql
-- Match graph pattern
MATCH (p:Person)-[:KNOWS]->(other:Person)
WHERE p.name = 'Alice'
RETURN other.name;
```

## Full-Text Search

```sql
-- Search documents
SELECT * FROM articles WHERE MATCH(title, body) AGAINST('database');
```

## HTTP/REST API

```bash
# GET request
curl http://localhost:9470/api/users

# POST request
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## Next Steps

- [BaraQL Reference](en/baraql.md)
- [Storage Engines](en/storage.md)
- [Architecture Overview](en/architecture.md)
- [Protocol Reference](en/protocol.md)