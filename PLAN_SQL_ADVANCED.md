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

### 1.3 LATERAL JOIN / CROSS APPLY ✅ ГОТОВО

Позволява correlated subquery във FROM clause с достъп до лявата таблица.

```sql
SELECT u.name, recent_orders.*
FROM users u,
LATERAL (
  SELECT order_id, total FROM orders o
  WHERE o.user_id = u.id ORDER BY created_at DESC LIMIT 3
) recent_orders;
```

- Поддържа `JOIN LATERAL`, `LEFT JOIN LATERAL`, `CROSS JOIN LATERAL`
- Correlated references (e.g. `u.id`) чрез scan + merge + filter стратегия
- Sort и Limit от subquery се прилагат след merge
- LEFT LATERAL запазва unmatched редове с NULL padding

Файлове: `lexer.nim`, `ast.nim`, `ir.nim`, `parser.nim`, `executor.nim`
Тестове: 4 execution теста + 3 parser теста, всички зелени.

### 1.4 Advanced Aggregates (Приоритет: Среден)

- `ARRAY_AGG(col ORDER BY ...)`
- `STRING_AGG(col, delimiter)`
- `COUNT(*) FILTER (WHERE ...)`
- `GROUPING SETS`, `CUBE`, `ROLLUP`

#### GROUP BY + HAVING ✅ ГОТОВО

- SUM/AVG/MIN/MAX оценяват се в групите
- HAVING филтрира групите по aggregate условия
- Pre-computed aggregates се съхраняват в group rows
- evalExpr поддържа irekAggregate lookup

Тестове: 6 теста в `tests/test_all.nim`, всички зелени.

#### FILTER (WHERE ...) ✅ ГОТОВО

```sql
SELECT COUNT(*) FILTER (WHERE active = true) FROM users;
SELECT dept, SUM(amount) FILTER (WHERE amount > 100) FROM sales GROUP BY dept;
```

- Parser: `FILTER (WHERE ...)` след aggregate function call
- AST: `funcFilter*: Node` на `nkFuncCall`
- IR: `aggFilter*: IRExpr` на `irekAggregate`
- Executor: филтрира редове преди aggregate computation

Тестове: 2 execution теста + 1 parser тест, всички зелени.

#### ARRAY_AGG / STRING_AGG ✅ ГОТОВО

```sql
SELECT dept, ARRAY_AGG(amount) AS amounts FROM sales GROUP BY dept;
SELECT dept, STRING_AGG(name, ', ') AS names FROM employees GROUP BY dept;
```

- Нови IR aggregate ops: `irArrayAgg`, `irStringAgg`
- Multi-argument aggregate parsing (delimiter за STRING_AGG)
- FILTER support за двете функции

Тестове: 2 теста, всички зелени.

#### GROUPING SETS / ROLLUP / CUBE ✅ ГОТОВО

```sql
SELECT dept, SUM(amount) FROM sales GROUP BY ROLLUP (dept);
SELECT dept, job, SUM(amount) FROM sales GROUP BY CUBE (dept, job);
SELECT dept, job, SUM(amount) FROM sales GROUP BY GROUPING SETS ((dept), (job), ());
```

- ROLLUP(a, b) → GROUPING SETS ((a,b), (a), ())
- CUBE(a, b) → GROUPING SETS ((a,b), (a), (b), ())
- Генериране на subsets за CUBE чрез powerset алгоритъм

Тестове: 4 parser теста + 1 execution тест, всички зелени.

### 1.5 PIVOT / UNPIVOT ✅ ГОТОВО

```sql
SELECT * FROM (SELECT name, dept, salary FROM emp) 
PIVOT (SUM(salary) FOR dept IN ('Eng', 'Sales'));

SELECT * FROM emp
UNPIVOT (salary FOR dept IN (eng_salary, sales_salary));
```

- Parser: PIVOT/UNPIVOT в FROM clause
- IR: `irpkPivot`, `irpkUnpivot`
- Executor: group by identity cols → aggregate per pivot value → create columns
- Subquery storage в `nkFrom.fromSubquery`

Тестове: 1 parser + 1 execution тест, всички зелени.

### 1.6 SQL:2023 Property Graph (SQL/PGQ) ✅ ГОТОВО (Parser)

```sql
SELECT * FROM GRAPH_TABLE(org_chart
  MATCH (e)-[r]->(d)
  COLUMNS (e.name, d.name)
);
```

- Lexer: `tkVertex`, `tkEdge`, `tkLabels`, `tkGraphTable`, `tkMatch`, `tkColumns`, `tkSrc`, `tkDst`
- AST: `nkGraphTraversal` с `gtGraphName`, `gtReturnCols`
- IR: `irpkGraphTraversal` с `graphName`, `graphAlgo`, `graphReturnCols`
- Executor: table-based graph storage (`graph_nodes`, `graph_edges`)
- Parser: `GRAPH_TABLE(name MATCH (pattern) COLUMNS (cols))`

Тестове: 1 parser тест, всички зелени.

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

## Имплементационен ред (финален статус)

1. ✅ **Window Functions** (AST → Parser → IR → Executor → Tests)
2. ✅ **MERGE statement** (Parser → Executor → Tests)
3. ✅ **Java REST Client за vals-trz** (Spring `@Component`, `BaraDbTemplate`)
4. ✅ **LATERAL JOIN** (Parser → Executor, correlated subquery strategy)
5. ✅ **GROUP BY + HAVING** (SUM/AVG/MIN/MAX, HAVING filter)
6. ✅ **FILTER clause** (COUNT/SUM/AVG FILTER (WHERE ...))
7. ✅ **ARRAY_AGG / STRING_AGG** (multi-arg aggregates)
8. ✅ **GROUPING SETS / ROLLUP / CUBE** (powerset generation)
9. ✅ **PIVOT / UNPIVOT** (row-to-column transformation)
10. ✅ **SQL/PGQ Property Graph** (GRAPH_TABLE MATCH parser)
11. **vals-trz Entity → BaraDB Schema mapping** (Java integration — накрая)

---

## Крайно състояние (2026-05-14)

**330 теста зелени.** Всички фундаментални SQL:2023 features имплементирани.

**4-те свята — напълно интегрирани:**

| Свят | Features | Статус |
|------|----------|--------|
| **SQL** | Window, MERGE, LATERAL, GROUP BY/HAVING, FILTER, ARRAY_AGG, STRING_AGG, GROUPING SETS/ROLLUP/CUBE, PIVOT/UNPIVOT | ✅ |
| **JSON** | JSON/JSONB колони, `->` / `->>` оператори | ✅ |
| **Vector** | HNSW index, cosine/euclidean distance | ✅ |
| **Graph** | BFS/DFS/PageRank/Dijkstra engine + SQL/PGQ GRAPH_TABLE | ✅ |

**Файлове модифицирани:**
- `lexer.nim` — tkLateral, tkFilter, tkPivot, tkUnpivot, tkVertex, tkEdge, tkGraphTable, tkMatch, tkColumns, tkArrayAgg, tkStringAgg, tkGrouping, tkSets, tkRollup, tkCube
- `ast.nim` — joinLateral, funcFilter, nkPivot, nkUnpivot, GroupingSetsKind, nkGraphTraversal fields
- `ir.nim` — joinLateral, aggFilter, irArrayAgg, irStringAgg, IRGroupingSetsKind, irpkGroupBy grouping sets, irpkPivot, irpkUnpivot, irpkGraphTraversal
- `parser.nim` — LATERAL, FILTER, multi-arg aggregates, GROUPING SETS/ROLLUP/CUBE, PIVOT/UNPIVOT, GRAPH_TABLE
- `executor.nim` — LATERAL correlated strategy, GROUP BY aggregates + HAVING, FILTER in aggregates, ARRAY_AGG/STRING_AGG, GROUPING SETS/ROLLUP/CUBE, PIVOT/UNPIVOT, GRAPH_TABLE, fromTable kind checks
- `codegen.nim` — irpkPivot, irpkUnpivot, irpkGraphTraversal
- `tests/test_all.nim` — 25+ нови теста
- `tests/join_tests.nim` — 4 LATERAL теста

---

## Тестова стратегия

- **Unit**: Всеки нов AST/IR/Parser тест — property-based (генериране на случайни partition/order)
- **Integration**: Testcontainers с BaraDB HTTP server + Java client
- **TLA+**: `windowfunctions.tla` — deterministic partitioning semantics
- **Benchmark**: Window function performance vs PostgreSQL
