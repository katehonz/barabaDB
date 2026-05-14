# BaraDB — Дългосрочен план за Advanced SQL + All-in-One Engine

> **Визия**: BaraDB става единният мултимодален backend за vals-trz и други ERP/HR системи. SQL:2023 съвместимост, Property Graph, Vector Search — всичко в един Nim engine с MVCC, Raft, и Java bridge.

---

## Част 1: BaraDB Advanced SQL Engine

### 1.1 Window Functions ✅ ГОТОВО

Нови AST nodes: `nkWindowExpr`, `nkOverClause`, `nkFrameSpec`. Нов IR plan: `irpkWindow`.

| Функция | Описание | Статус |
|---------|----------|--------|
| `ROW_NUMBER()` | Пореден номер в партишъна | ✅ |
| `RANK()` / `DENSE_RANK()` | Класиране с/без gaps | ✅ |
| `LEAD(col, n, default)` / `LAG(col, n, default)` | Достъп до съседни редове | ✅ |
| `FIRST_VALUE(col)` / `LAST_VALUE(col)` | Краен елемент във frame | ✅ |
| `NTILE(n)` | Bucket-ване в n части | ✅ |

Frame поддръжка: `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` ✅

Файлове: `lexer.nim`, `ast.nim`, `ir.nim`, `parser.nim`, `executor.nim`, `codegen.nim`
Тестове: 5 теста в `tests/test_all.nim`, всички зелени.

### 1.2 MERGE / UPSERT ✅ ГОТОВО

```sql
MERGE INTO inventory AS target
USING updates AS source
ON target.sku = source.sku
WHEN MATCHED THEN UPDATE SET qty = target.qty + source.delta
WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (source.sku, source.delta);
```

- Поддържа таблица или subquery като source
- WHEN MATCHED UPDATE с eval на изрази (target.col + source.col)
- WHEN NOT MATCHED INSERT с eval на value изрази
- Trigger support (BEFORE/AFTER UPDATE/INSERT)

Файлове: `lexer.nim`, `ast.nim`, `ir.nim`, `parser.nim`, `executor.nim`, `codegen.nim`
Тестове: 2 теста в `tests/test_all.nim`, всички зелени.

### 1.3 LATERAL JOIN / CROSS APPLY (Приоритет: Висок)

Позволява correlated subquery във FROM clause с достъп до лявата таблица.

```sql
SELECT u.name, recent_orders.*
FROM users u,
LATERAL (
  SELECT order_id, total FROM orders o
  WHERE o.user_id = u.id ORDER BY created_at DESC LIMIT 3
) recent_orders;
```

### 1.4 Advanced Aggregates (Приоритет: Среден)

- `ARRAY_AGG(col ORDER BY ...)`
- `STRING_AGG(col, delimiter)`
- `COUNT(*) FILTER (WHERE ...)`
- `GROUPING SETS`, `CUBE`, `ROLLUP`

### 1.5 PIVOT / UNPIVOT (Приоритет: Среден)

### 1.6 SQL:2023 Property Graph (SQL/PGQ) — Дългосрочен

```sql
CREATE PROPERTY GRAPH org_chart
  VERTEX TABLES (employees LABEL person PROPERTIES (id, name))
  EDGE TABLES (
    employments
      SOURCE KEY (employee_id) REFERENCES employees (id)
      DESTINATION KEY (department_id) REFERENCES departments (id)
      LABEL works_in
  );

SELECT * FROM GRAPH_TABLE(org_chart
  MATCH (e IS person WHERE e.name = 'Иван')-[IS works_in]->(d)
  COLUMNS (d.name AS department)
);
```

---

## Част 2: vals-trz → BaraDB Миграционна стратегия

### Фаза 0: Java REST Bridge ✅ ГОТОВО

```
vals-trz (Spring Boot)
    ↓ HTTP/JSON (BaraDB REST API)
BaraDB Server (Nim)
    ↓ Native execution
Storage (LSM-Tree / B-Tree / HNSW / InvertedIndex)
```

Създадени файлове в `vals-trz/backend/src/main/java/com/valstrz/baradb/`:
- `BaraDbProperties.java` — `@ConfigurationProperties(prefix = "baradb")`
- `BaraDbClient.java` — HTTP клиент към `POST /query`
- `BaraDbTemplate.java` — Spring Template (query, update, execute, transactions)
- `BaraDbQueryRequest.java` / `BaraDbQueryResponse.java` — JSON DTOs
- `BaraDbException.java` — Runtime exception
- `BaraDbConfig.java` — Spring `@Configuration`
- `EmployeeBaraRepository.java` — Пример: Employee entity → SQL MERGE/SELECT
- `README.md` — Документация за bridge

Конфигурация добавена в `application.properties`:
```properties
baradb.enabled=false
baradb.host=localhost
baradb.port=9470
baradb.database=valstrz
```

### Фаза 1: Document Storage (Вместо ArangoDB)

- JSON/JSONB колони за гъвкави документи
- Всеки `BaseEntity` → таблица с `id`, `tenant_id`, `data jsonb`
- Или: full relational mapping (всеки Java field → SQL колона)

### Фаза 2: Graph йерархия (Вместо ArangoDB edges)

- SQL/PGQ `CREATE PROPERTY GRAPH org_chart`
- `MATCH` queries за reporting chain, department structure
- BFS/DFS + shortestPath вградени в SQL планера

### Фаза 3: Vector Search (Вместо Qdrant)

- `vector` тип + HNSW index
- `cosine_distance(embedding, [...])` в WHERE/ORDER BY
- Hybrid: vector similarity + BM25 + relational filters в една транзакция

### Фаза 4: Distributed (Когато трябва scale)

- Raft consensus за HA
- Sharding за multi-tenant isolation (shard by `tenant_id`)

---

## Имплементационен ред (обновен)

1. ✅ **Window Functions** (AST → Parser → IR → Executor → Tests)
2. ✅ **MERGE statement** (Parser → Executor → Tests)
3. ✅ **Java REST Client за vals-trz** (Spring `@Component`, `BaraDbTemplate`)
4. **LATERAL JOIN** (Parser → Executor)
5. **Advanced Aggregates** (FILTER, GROUPING SETS)
6. **SQL/PGQ Property Graph** (DDL parser → Graph engine integration)
7. **vals-trz Entity → BaraDB Schema mapping**
8. **PIVOT/UNPIVOT**

---

## Тестова стратегия

- **Unit**: Всеки нов AST/IR/Parser тест — property-based (генериране на случайни partition/order)
- **Integration**: Testcontainers с BaraDB HTTP server + Java client
- **TLA+**: `windowfunctions.tla` — deterministic partitioning semantics
- **Benchmark**: Window function performance vs PostgreSQL
