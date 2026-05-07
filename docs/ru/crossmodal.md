# Кросс-модальные запросы

Уникальная возможность BaraDB — выполнение запросов, охватывающих несколько хранилищ в одном унифицированном операторе BaraQL.

## Обзор

Традиционные базы данных требуют отдельных запросов и соединений на уровне приложения при работе с разными моделями данных. BaraDB оптимизирует выполнение:

- **Документ/KV** (LSM-Tree) — структурированные записи
- **Граф** (Список смежности) — связи
- **Вектор** (HNSW/IVF-PQ) — поиск по сходству
- **Полнотекстовый** (Инвертированный индекс) — текстовый поиск
- **Колоночный** — аналитические агрегаты

## Паттерны запросов

### Вектор + Полнотекстовый

```sql
SELECT title, score
FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, ...])
LIMIT 10;
```

### Граф + Вектор

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name, friend.age;
```

### Документ + Граф

```sql
SELECT o.id, o.total, c.name
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE c.id IN (
  SELECT node_id FROM graph
  WHERE MATCH pattern (c:Customer)-[:REFERRED]->(:Customer)
);
```

## Оптимизация

### Кросс-модальный планировщик

1. Наиболее селективный фильтр первым
2. Предикаты проталкиваются в каждый движок
3. Bloom фильтры для KV поисков
4. Параллельное выполнение независимых ветвей

## Производительность

| Тип запроса | Латентность (10K строк) |
|-------------|--------------------------|
| FTS + Vector | 15 ms |
| Graph + Vector | 25 ms |
| FTS + Aggregate | 12 ms |