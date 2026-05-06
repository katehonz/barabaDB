# BaraDB - Бързо Стартиране

## Стартиране на Сървъра

След компилация, стартирайте сървъра:

```bash
./build/baradadb
```

Сървърът ще стартира на `localhost:8080` по подразбиране.

## Свързване чрез CLI

BaraDB включва интерактивна конзола:

```bash
./build/baradadb --shell
```

## Основни Операции

### Създаване на Схема

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

### Вмъкване на Данни

```sql
INSERT Person { name := 'Alice', age := 30 };
INSERT Person { name := 'Bob', age := 25 };
```

### Заявки

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### Обновяване

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### Изтриване

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## Разширени Заявки

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### Агрегати

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

## Търсене на Вектори

```sql
-- Вмъкване с вектор
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };

-- Търсене на подобни
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## HTTP/REST API

```bash
# GET заявка
curl http://localhost:8080/api/users

# POST заявка
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## Следващи Стъпки

- [BaraQL Референция](bg/baraql.md)
- [Схема](bg/schema.md)
- [Архитектура](bg/architecture.md)