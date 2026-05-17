# BaraDB — AI-Native Data Platform Roadmap

> **Визия**: BaraDB не е "релационна база + векторна добавка", а единна AI-native база данни, където релационни, векторни, граф и текстови данни живеят в един engine. Както MariaDB интегрира vectors в ядрото, така и BaraDB прави vector/graph/fts първокласни граждани в SQL execution layer-а.
>
> **Принцип**: Универсалност + Multi-Tenancy. Всяка AI функция работи с Row-Level Security (RLS) и session variables (`app.tenant_id`). Няма отделни "AI таблици" — всичко е SQL.

---

## Текущо състояние (май 2026)

| Компонент | Статус |
|-----------|--------|
| SQL:2023 Engine | ✅ Window, MERGE, LATERAL, GROUPING SETS, PIVOT, SQL/PGQ |
| Vector Engine | ✅ HNSW + IVF-PQ + SIMD (ядро) |
| Vector SQL | ✅ `VECTOR(n)` тип, `CREATE VECTOR INDEX`, distance функции, `<->` оператор |
| Graph Engine | ✅ BFS/DFS/PageRank/Dijkstra + SQL/PGQ `GRAPH_TABLE` |
| Full-Text Search | ✅ Inverted Index + BM25 + Hybrid Search |
| JSON/JSONB | ✅ Колони, оператори, функции |
| Multi-Tenant | ✅ Session vars, `current_setting()`, `current_user`, RLS Policies |
| Foreign Keys | ✅ CASCADE/SET NULL/RESTRICT за ON DELETE и ON UPDATE |
| Formal Verification | ✅ 10 TLA+ спецификации |
| MCP Server | ✅ STDIO JSON-RPC, 3 tools (query, vector_search, schema_inspect), multi-tenant |

---

## Сесия 10: Vector AI Native Integration

> **Цел**: Да превърнем vector search от "engine feature" в "AI-native SQL experience" — RAG-ready, LangChain-compatible, MCP-enabled.

### Фаза 10.1: Hybrid RAG Search

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 10.1.1 | `hybrid_search()` SQL функция | Комбинира vector similarity + BM25 FTS + релационни филтри в една заявка. Reranking с RRF (Reciprocal Rank Fusion). | 6-8ч |
| 10.1.2 | `rerank()` SQL функция | Cross-encoder reranking — приема query text + резултати, връща преподредени по relevance. | 4ч |
| 10.1.3 | Metadata filtering в vector search | `WHERE` клауза върху JSONB/релационни колони ДО vector index scan-а (pre-filtering). | 6ч |
| 10.1.4 | Chunking + embedding pipeline | `INSERT INTO docs (text)` → автоматично chunk-ване + embedding generation чрез външен embedder. | 8ч |

**Метрика**: `SELECT hybrid_search('AI query', embedding, content, k => 10)` връща релевантни резултати за under 50ms с 1M vectors.

### Фаза 10.2: LangChain Vector Store Interface

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 10.2.1 | `BaraDBStore` за Python LangChain | Имплементира `VectorStore` интерфейса — `add_texts()`, `similarity_search()`, `max_marginal_relevance_search()`. | 4ч |
| 10.2.2 | `BaraDBStore` за JS LangChain | Същото за LangChain.js. | 4ч |
| 10.2.3 | Conversation buffer в BaraDB | `ChatMessageHistory` имплементация — съхранява message threads в релационна таблица с RLS. | 3ч |
| 10.2.4 | RAG pipeline example | End-to-end пример: ingest PDF → chunks → embeddings → hybrid search → LLM context. | 3ч |

**Метрика**: LangChain RAG tutorial работи с BaraDB без промяна на кода (swap-in replacement за PostgreSQL/pgvector).

### Фаза 10.3: MCP Server (Model Context Protocol) ✅

| # | Задача | Описание | Оценка | Статус |
|---|--------|----------|--------|--------|
| 10.3.1 | MCP Server scaffolding | STDIO/SSE transport, tool definitions, capability negotiation. | 4ч | ✅ |
| 10.3.2 | `query` tool — SQL execution | AI агент изпраща SQL, получава резултати. Parameterized queries за сигурност. | 3ч | ✅ |
| 10.3.3 | `vector_search` tool | Semantic search tool с tenant isolation чрез `app.tenant_id` session var. | 3ч | ✅ |
| 10.3.4 | `schema_inspect` tool | AI агент разглежда таблици, колони, индекси, RLS policies. | 2ч | ✅ |
| 10.3.5 | Multi-tenant MCP | Всяка MCP сесия носи `tenant_id` + `user_id` — RLS филтрира автоматично. | 2ч | ✅ |

**Метрика**: Claude/Cursor can connect to BaraDB via MCP и изпълнява `SELECT hybrid_search(...) WHERE tenant_id = current_setting('app.tenant_id')`.
✅ Проверено: `baramcp --data-dir ./data` стартира STDIO MCP сървър с 3 tools-a. Тествани с JSON-RPC 2.0 клиент: query, vector_search, schema_inspect — всички работят.

---

## Сесия 11: Graph Engine Deep Integration

> **Цел**: SQL/PGQ парсерът е готов, но execution-ът е table-based. Да го направим първокласен citizen с native graph storage и Cypher compatibility.

### Фаза 11.1: Native Graph Storage

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 11.1.1 | Property Graph DDL | `CREATE GRAPH g`, `CREATE NODE TABLE`, `CREATE EDGE TABLE` — native graph schema. | 4ч |
| 11.1.2 | Adjacency list storage | Ребрата се пазят като adjacency lists (не като отделни LSM редове) за O(1) neighbors access. | 6ч |
| 11.1.3 | Graph indexes | Index на `source→targets` и `target→sources` за bidirectional traversal. | 4ч |
| 11.1.4 | Graph + RLS integration | `CREATE POLICY` върху graph nodes/edges — tenant isolation за граф данни. | 3ч |

### Фаза 11.2: Advanced Graph Algorithms

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 11.2.1 | `shortest_path()` SQL функция | Dijkstra/A* между два node-а, връща path като JSON array. | 3ч |
| 11.2.2 | `community_detection()` SQL функция | Louvain algorithm, връща community ID за всеки node. | 6ч |
| 11.2.3 | `similarity_nodes()` SQL функция | Jaccard/Adamic-Adar similarity между neighbors. | 3ч |
| 11.2.4 | Vector + Graph hybrid | Node embeddings + graph structure: `node2vec` или `graph neural network` inference. | 8ч |

### Фаза 11.3: Cypher Compatibility Layer

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 11.3.1 | Cypher parser (subset) | `MATCH (a)-[r]->(b) WHERE a.name = 'X' RETURN b` → BaraQL AST. | 6ч |
| 11.3.2 | Cypher → SQL/PGQ translation | `MATCH` → `GRAPH_TABLE(... MATCH ...)` за съвместимост със съществуващ executor. | 4ч |
| 11.3.3 | APOC-style functions | `apoc.path.expand()`, `apoc.coll.*` — полезни utility функции. | 4ч |

**Метрика**: Neo4j `movies` example работи с BaraDB Cypher layer без промяна.

---

## Сесия 12: AI Agents & Natural Language → SQL

> **Цел**: No-code / low-code AI агенти, които работят директно с BaraDB.

### Фаза 12.1: NL → SQL Agent

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 12.1.1 | Schema-aware prompt template | Prompt който вкарва `CREATE TABLE` дефиниции + sample data + RLS policies. | 2ч |
| 12.1.2 | `nl_to_sql()` SQL функция | `SELECT nl_to_sql('Show me top 5 customers by revenue')` → generated SQL string. | 4ч |
| 12.1.3 | Query validation layer | Генерираният SQL минава през sandbox execution с `LIMIT 1` + explain plan. | 3ч |
| 12.1.4 | Self-correction loop | Ако SQL-ът фейлва, агентът получава error message и генерира fix. | 3ч |

### Фаза 12.2: Multi-Tenant AI Agent

| # | Задача | Описание | Оценка |
|---|--------|----------|--------|
| 12.2.1 | Per-tenant schema views | AI агентът вижда само таблици/колони, достъпни за текущия tenant. | 2ч |
| 12.2.2 | Tenant-aware NL → SQL | `app.tenant_id` се инжектира автоматично в генерирания SQL. | 2ч |
| 12.2.3 | Agent memory per tenant | Conversation history се изолира по tenant_id + user_id. | 2ч |

---

## Приоритети и зависимости

```
Сесия 10 (Vector AI) ──→ Сесия 12 (AI Agents)
       │                      │
       ↓                      ↓
Сесия 11 (Graph) ──────→ Hybrid Vector+Graph
```

**Препоръчителен ред:**
1. **Сесия 10.1** — Hybrid RAG Search (най-висок business value)
2. **Сесия 10.2** — LangChain интеграция (екосистемна съвместимост)
3. **Сесия 10.3** — MCP Server (AI агенти могат да работят веднага)
4. **Сесия 11.1** — Native Graph Storage (performance foundation)
5. **Сесия 11.2** — Advanced Graph Algorithms (feature completeness)
6. **Сесия 12** — NL → SQL (user-facing wow factor)

---

## Какво остава от старите планове

| Стар план | Статус |
|-----------|--------|
| `PLAN_old_1.md` — Base SQL + MVCC + Raft | ✅ Завършен |
| `PLAN_old_2.md` — Production Roadmap | ✅ Завършен |
| `PLAN_old_3.md` — Stabilization Sprint (сесия 9) | ✅ Завършен |
| `PLAN_SQL_ADVANCED.md` — Window Functions, MERGE, etc. | ✅ Завършен |
| `PLAN_ID_GENERATORS.md` — AUTO_INCREMENT, Sequences, FK | ✅ Завършен |

---

## Философия

> BaraDB не добавя "AI модули" — BaraDB става AI-native като вгради embeddings, similarity search, graph traversal и natural language интерфейси в съществуващия SQL engine. Всяка нова функция работи с:
> - **MVCC транзакции**
> - **RLS + Multi-tenancy**
> - **WAL + Replication**
> - **Nim performance**

---

*План версия: 2026-05-17*
