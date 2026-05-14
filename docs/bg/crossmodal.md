# Cross-Modal Заявки

Уникалната способност на BaraDB да изпълнява заявки, обхващащи множество storage двигатели в една унифицирана BaraQL заявка.

## Преглед

Традиционните бази данни изискват отделни заявки и join-ове на ниво приложение при работа с различни модели на данни. Cross-modal query planner-ът на BaraDB оптимизира изпълнението през:

- **Документи/KV** (LSM-Tree) — структурирани записи
- **Графи** (Adjacency List) — връзки
- **Вектори** (HNSW/IVF-PQ) — търсене на прилика
- **Пълен текст** (Inverted Index) — текстово търсене
- **Колонково** — аналитични агрегати

## Примери за Заявки

### Векторно + Пълнотекстово (Семантично + Ключово Търсене)

```sql
SELECT title, score
FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, ...])
LIMIT 10;
```

### Графово + Векторно (Социални Препоръки)

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name, friend.age;
```

### Документно + Графово (Обогатяване на Същности)

```sql
SELECT o.id, o.total, c.name,
       (SELECT count(*) FROM orders WHERE customer_id = c.id) as order_count
FROM orders o
MATCH (c:Customer)-[:PLACED]->(o)
WHERE o.date > '2025-01-01';
```

## Cross-Modal Engine API

```nim
import barabadb/core/crossmodal

var engine = newCrossModalEngine("/tmp/baradb")

# Документни операции
engine.put("key1", cast[seq[byte]]("value1"))
let (found, val) = engine.get("key1")

# Векторни операции
engine.insertVector(1, @[1.0'f32, 0.0'f32, ...], {"cat": "A"}.toTable)
let results = engine.searchVector(@[1.0'f32, 0.1'f32, ...], 2)

# Графови операции
let n1 = engine.addNode("Person")
let n2 = engine.addNode("Person")
discard engine.addEdge(n1, n2, "knows")
let traversal = engine.traverseGraph(n1, "bfs")

# FTS операции
engine.indexText(1, "Nim programming language")
let ftsResults = engine.searchText("programming")

# Хибридно търсене
var query = newCrossModalQuery(qmHybrid)
query.vector = @[1.0'f32, 0.0'f32]
query.searchQuery = "fast"
query.vecWeight = 1.0
query.ftsWeight = 1.0
let hybridResult = engine.hybridSearch(query)
```

## 2PC Транзакции

Cross-modal engine-ът поддържа two-phase commit за атомарни операции през множество storage системи:

```nim
var txn = newTPCTransaction(1)
txn.addParticipant("storage")
txn.addParticipant("vector")
txn.addParticipant("graph")

txn.prepare()   # Всички участници потвърждават, че могат да комитнат
txn.commit()    # Атомарен commit през всички участници
```

## Формална Верификация

Cross-modal консистентността е формално специфицирана в TLA+:

- **Спецификация:** `formal-verification/crossmodal.tla`
- **Проверени свойства:**
  - `MetadataVectorConsistency` — insertVector обновява метаданни за филтрирано търсене
  - `CrossModalAtomicity` — всички участници комитват или всички абортират
