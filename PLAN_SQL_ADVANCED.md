# BaraDB — Универсален план за Advanced SQL Engine

> **Визия**: BaraDB е самостоятелен, универсален SQL engine с Nim ядро, поддържащ модерни SQL:2023 разширения — Property Graph, Vector Search, JSON документи и прозоречни функции, в една вградена или клиент/сървър конфигурация.
> 
> **Принцип**: Само основи. Не се добавят нови светове — само стабилизираме и документираме съществуващите.
>
> **Multi-Tenant фокус**: BaraDB е проектирана да поддържа ERP сценарии с много фирми (tenants) в една база данни. Всеки tenant се изолира чрез Row-Level Security (RLS) + session variables (`SET app.tenant_id = 'X'`), а не чрез отделни бази.

---

## История на разработката

- **Фаза 1 (Base SQL + MVCC + Raft)**: BaraDB core engine
- **Фаза 2 (Advanced SQL)**: Разработена с **Xiaomi Mimo** (`mimo-v2.5-pro`) — Window Functions, MERGE, LATERAL JOIN, Advanced Aggregates, PIVOT/UNPIVOT, SQL/PGQ Property Graph
- **Фаза 3 (Stabilization + Multi-Tenant)**: Текуща — Vector SQL Integration, Session Variables, `current_user`/`current_role`, RLS tenant isolation, тестове, документация

---

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

### 1.4 Advanced Aggregates ✅ ГОТОВО

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

## Част 1.5: Multi-Tenant ERP Support ✅ ГОТОВО

BaraDB поддържа multi-tenant архитектура, при която множество фирми (tenants) работят в една физическа база данни. Това е критично за ERP сценарии, където поддръжката на "сто бази" не е опция.

### Механизъм

| Компонент | Описание |
|-----------|----------|
| **Session Variables** | `SET app.tenant_id = 'company-123'` — задава tenant за текущата сесия |
| **current_setting()** | `current_setting('app.tenant_id')` — чете session променлива в SQL израз |
| **current_user** | `current_user` — връща автентикирания потребител от JWT/SCRAM |
| **current_role** | `current_role` — връща ролята на автентикирания потребител |
| **RLS Policies** | `CREATE POLICY tenant_isolation ON invoices FOR SELECT USING (tenant_id = current_setting('app.tenant_id'))` |
| **Auth Bridge** | `server.nim` и `httpserver.nim` попълват `ExecutionContext.currentUser`/`currentRole` след верификация |

### Пример

```sql
-- Една таблица за всички фирми
CREATE TABLE invoices (
  id SERIAL PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  data JSONB
);

-- Изолация чрез RLS
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- Всяка сесия вижда само своя tenant
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- → само фактури на company-a
```

### Архитектурни предимства

- **JSONB документи** — schema-flexible, лесно се добавят нови полета без миграции (като ArangoDB)
- **RLS изолация** — базата данни гарантира, че всеки tenant вижда само своите данни
- **Един instance** — един BaraDB сървър обслужва всички tenants, вместо сто отделни бази
- **Auth integration** — JWT/SCRAM токените носят `sub` (user) и `role`, които се пропагират до executor-а

---

## Част 2: Мултимодални Възможности (Core Only)

### 2.1 JSON / JSONB Документи ✅ ГОТОВО

```sql
SELECT data->>'name' FROM users WHERE data->'tags' @> '["admin"]';
```

- Типове: `JSON`, `JSONB` колони в таблици
- Оператори: `->`, `->>`, `#>`, `#>>`, `@>`, `<@`, `?`, `?&`, `?|`
- Функции: `jsonb_array_elements`, `jsonb_object_keys`, `jsonb_extract_path`
- Съхранение: двоично parsed tree (не plain text)

### 2.2 Vector Search ⚠️ ЧАСТИЧНО (Engine ✅, SQL Integration 🔄)

**Вектор Engine (готов):**
- `src/barabadb/vector/engine.nim` — HNSW index с cosine/euclidean distance
- `src/barabadb/vector/quant.nim` — IVF-PQ quantization
- `src/barabadb/vector/simd.nim` — SIMD оптимизации
- `src/barabadb/core/crossmodal.nim` — CrossModalEngine за хибридно търсене (vector + text)

**Липсваща SQL интеграция (базова — за стабилизация):**
```sql
-- Тип и колона
CREATE TABLE items (id INT PRIMARY KEY, embedding VECTOR(768));

-- Index
CREATE VECTOR INDEX idx_items_vec ON items(embedding) 
  USING hnsw WITH (m = 16, ef_construction = 200, metric = 'cosine');

-- Query functions
SELECT id, cosine_distance(embedding, '[0.1, 0.2, ...]') AS dist
FROM items
ORDER BY dist ASC
LIMIT 10;
```

**Задачи за стабилизация (всички изпълнени):**
- [x] `VECTOR(n)` тип в CREATE TABLE (parser + storage)
- [x] `CREATE VECTOR INDEX ... USING hnsw` (DDL)
- [x] `cosine_distance()`, `euclidean_distance()`, `inner_product()` в SQL expression evaluator
- [x] `<->` nearest-neighbor оператор в ORDER BY / WHERE
- [x] Executor integration: HNSW index population при CREATE INDEX и DML

**Статус:** ✅ ГОТОВО. 8 SQL-level vector теста зелени.

### 2.3 Full-Text Search ✅ ГОТОВО

- Inverted Index в `src/barabadb/fts/`
- `MATCH(column, query)` функция
- BM25 scoring
- Интеграция с CrossModalEngine за hybrid search

---

## Част 3: Транзакции и Протоколи ✅ ГОТОВО

- MVCC с snapshot isolation
- WAL + checkpoint
- Distributed transactions (2PC) — `txn.addParticipant("vector")`
- Wire protocol: binary за vectors, JSON за queries

---

## Имплементационен ред (финален статус)

1. ✅ **Window Functions** (AST → Parser → IR → Executor → Tests)
2. ✅ **MERGE statement** (Parser → Executor → Tests)
3. ✅ **LATERAL JOIN** (Parser → Executor, correlated subquery strategy)
4. ✅ **GROUP BY + HAVING** (SUM/AVG/MIN/MAX, HAVING filter)
5. ✅ **FILTER clause** (COUNT/SUM/AVG FILTER (WHERE ...))
6. ✅ **ARRAY_AGG / STRING_AGG** (multi-arg aggregates)
7. ✅ **GROUPING SETS / ROLLUP / CUBE** (powerset generation)
8. ✅ **PIVOT / UNPIVOT** (row-to-column transformation)
9. ✅ **SQL/PGQ Property Graph** (GRAPH_TABLE MATCH parser)
10. ✅ **JSON/JSONB** (operators + functions)
11. ✅ **Full-Text Search** (inverted index + BM25)
12. ✅ **Vector Engine** (HNSW + IVF-PQ + SIMD)
13. ✅ **Vector SQL Integration** (тип, index, distance functions, <-> operator, ORDER BY)

---

## Крайно състояние

**340+ теста зелени.** Всички фундаментални SQL:2023 features имплементирани.

**Четирите свята:**

| Свят | Features | Статус |
|------|----------|--------|
| **SQL** | Window, MERGE, LATERAL, GROUP BY/HAVING, FILTER, ARRAY_AGG, STRING_AGG, GROUPING SETS/ROLLUP/CUBE, PIVOT/UNPIVOT | ✅ |
| **JSON** | JSON/JSONB колони, `->` / `->>` оператори | ✅ |
| **Graph** | BFS/DFS/PageRank/Dijkstra engine + SQL/PGQ GRAPH_TABLE | ✅ |
| **Vector** | HNSW index, cosine/euclidean distance, IVF-PQ, SIMD | ✅ Engine<br>🔄 SQL glue |
| **FTS** | Inverted index, BM25, hybrid search | ✅ |

**Файлове модифицирани:**
- `lexer.nim` — tkLateral, tkFilter, tkPivot, tkUnpivot, tkVertex, tkEdge, tkGraphTable, tkMatch, tkColumns, tkArrayAgg, tkStringAgg, tkGrouping, tkSets, tkRollup, tkCube, tkVector
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
- **Integration**: HTTP server + клиент тестове
- **TLA+**: `windowfunctions.tla` — deterministic partitioning semantics
- **Benchmark**: Window function performance vs PostgreSQL (опционално)

---

## Поправени грешки при тази сесия

- **Vector SQL Integration** — имплементиран пълен SQL glue за вектори (тип, индекс, функции, оператор)
- **MERGE тестове** — поправени чрез изолиране на тестовата директория (unique temp dir per suite)
- **Row storage escape** — `escapeRowVal()` в `execInsert` за стойности със запетай (vector literals)
- **ORDER BY + projection** — `irpkSort` сега е преди `irpkProject` в `lowerSelect`, което позволява `ORDER BY` по колони извън `SELECT`
- **GROUPING SETS execution** — `lowerSelect` сега проверява `selGroupingSetsKind != gskNone` освен `selGroupBy.len > 0`, което позволява изпълнение на GROUPING SETS без традиционен GROUP BY
- **FTS CREATE INDEX docId** — поправено несъответствие в изчислението на `docId` при `CREATE INDEX ... USING FTS` (сега използва хеш на `tableName.$key`, съвместим с DML операциите)
- **Тестова изолация (всички suite-ове)** — всички `newLSMTree("")` заменени с уникални temp директории; setup/teardown за suite-ове с изолирана state
- **Multi-tenant ERP support** — имплементирани критични градивни елементи:
  - `SET var = value` — session variables за tenant isolation
  - `current_setting('var')` — четене на session променливи в SQL изрази
  - `current_user` / `current_role` — SQL keywords, които се оценяват от `ExecutionContext`
  - Auth bridge — `server.nim` и `httpserver.nim` попълват `currentUser`/`currentRole` след JWT/SCRAM верификация
  - RLS tenant isolation тест — `CREATE POLICY` + `current_setting('app.tenant_id')` работи за multi-tenant филтрация
  - `evalExpr` вече предава `ctx` рекурсивно — поправен бъг, при който `current_user`/`current_setting` връщаха празни стойности в под-изрази

---

> **Бележка**: Този план е *замразен* за нови светове. Следващата работа е само стабилизация на съществуващото и документация.
