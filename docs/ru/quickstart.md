# BaraDB - Руководство по быстрому старту

## Запуск сервера

После сборки BaraDB запустите сервер:

```bash
./build/baradadb
```

Сервер запустится на `localhost:9470` по умолчанию.

## Подключение через CLI

BaraDB включает интерактивную оболочку:

```bash
./build/baradadb --shell
```

## Основные операции

### Создание схемы

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

### Вставка данных

```sql
INSERT Person { name := 'Alice', age := 30 };
INSERT Person { name := 'Bob', age := 25 };
```

### Запрос данных

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### Обновление данных

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### Удаление данных

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## Продвинутые запросы

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### Агрегатные функции

```sql
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;
```

### CTE (Common Table Expressions)

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## Векторный поиск

```sql
-- Вставка вектора
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };

-- Поиск похожих
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## Графовые операции

```sql
-- Сопоставление графового шаблона
MATCH (p:Person)-[:KNOWS]->(other:Person)
WHERE p.name = 'Alice'
RETURN other.name;
```

## Полнотекстовый поиск

```sql
-- Поиск в документах
SELECT * FROM articles WHERE MATCH(title, body) AGAINST('database');
```

## HTTP/REST API

```bash
# GET запрос
curl http://localhost:9470/api/users

# POST запрос
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## Следующие шаги

- [Справочник по BaraQL](baraql.md)
- [Хранилища данных](storage.md)
- [Обзор архитектуры](architecture.md)
- [Справочник по протоколу](protocol.md)