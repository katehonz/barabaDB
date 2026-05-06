# BaraDB — План към Production (Web & ERP)

## Визия
BaraDB да стане production-ready база данни, с която да се изграждат:
- **Web приложения** (блогове, е-магазини, SaaS продукти)
- **Малки ERP системи** (CRM, склад, счетоводство, invoicing)

> Целеви потребител: solo-dev / малък екип, който иска лесна за deploy и бърза локална база, без зависимост от PostgreSQL/MySQL.

---

## Текущо състояние (база)

| Компонент | Статус |
|-----------|--------|
| LSM-Tree KV store | ✅ Стабилен, thread-safe, persistent |
| HNSW векторен search | ✅ Работи с recall > 0.9 |
| TCP wire protocol | ✅ Бинарен, SELECT/INSERT/DELETE |
| Raft consensus | ✅ TCP transport, leader election |
| Graph engine | ✅ In-memory + persistence |
| Thread-safety | ✅ Coarse-grained locks |
| CI/CD | ✅ GitHub Actions |

**Липсва за Web/ERP:** SQL съвместимост, ACID транзакции, HTTP API, auth, ORM, миграции, backup.

---

## Фаза 1: Релационен engine + SQL (4–6 седмици)

### 1.1 SQL парсър и AST
- Имплементирай ANSI SQL подмножество (CREATE TABLE, ALTER TABLE, DROP TABLE)
- INSERT с column list: `INSERT INTO users (name, email) VALUES ('...', '...')`
- UPDATE: `UPDATE users SET name = '...' WHERE id = 1`
- SELECT с JOIN, GROUP BY, HAVING, ORDER BY, LIMIT/OFFSET
- DELETE с WHERE
- Поддръжка на `RETURNING` клауза

### 1.2 Типова система и constraints
- `INTEGER`, `BIGINT`, `SERIAL` (auto-increment)
- `VARCHAR(n)`, `TEXT`
- `BOOLEAN`
- `TIMESTAMP`, `DATE` (ISO 8601)
- `JSON`, `JSONB` (in-memory + компресия)
- `UUID` (v4)
- Constraints: `PRIMARY KEY`, `FOREIGN KEY`, `UNIQUE`, `NOT NULL`, `CHECK`, `DEFAULT`
- Foreign key каскади: `ON DELETE CASCADE/SET NULL`

### 1.3 B-Tree индекси + интеграция с query planner
- `CREATE INDEX idx_name ON table(column)`
- `CREATE UNIQUE INDEX`
- Покриващ индекс (covering index) за чести колони
- Query planner да избира индекс вместо full scan
- `EXPLAIN` за анализ на заявки

### 1.4 Транзакции (ACID)
- `BEGIN`, `COMMIT`, `ROLLBACK`
- Isolation level: `READ COMMITTED` (първа фаза), `REPEATABLE READ` (втора)
- Deadlock detection и timeout
- MVCC интеграция с LSM-Tree (versioned reads)
- WAL за crash recovery при транзакции

---

## Фаза 2: Web API & Authentication (3–4 седмици)

### 2.1 HTTP REST API
- `POST /query` — изпълнява SQL, връща JSON
- `GET /health` — readiness/liveness probe
- `GET /metrics` — брой заявки, latency, errors (Prometheus формат)
- JSON request/response body:
  ```json
  { "query": "SELECT * FROM users WHERE id = 1", "params": [] }
  ```
- Batch queries: `POST /batch` — множество заявки в едно тяло
- Content-Type: `application/json`

### 2.2 Authentication & Authorization
- JWT bearer token в HTTP header `Authorization`
- `CREATE USER` / `DROP USER` / `ALTER USER`
- `GRANT` / `REVOKE` за права на таблици
- Row-Level Security (RLS): `CREATE POLICY`
- Хеширане на пароли с bcrypt/argon2
- Rate limiting per API key / IP

### 2.3 WebSocket за real-time
- `ws://host:port/live` — subscribe към таблица/ред
- `NOTIFY` / `LISTEN` аналог
- Пуш нотификации при INSERT/UPDATE/DELETE

### 2.4 CORS и HTTP hardening
- CORS headers за browser достъп
- TLS termination (reuse `ssl.nim`)
- Request size limits (10MB default)
- Connection keep-alive и HTTP/2 readiness

---

## Фаза 3: ERP фичове (4–5 седмици)

### 3.1 Schema migrations
- `CREATE MIGRATION` / `APPLY MIGRATION`
- Версиониране на схемата в `__schema_version` таблица
- Up/down скриптове
- Dry-run режим
- CLI: `baradadb migrate status`, `baradadb migrate up`, `baradadb migrate down`

### 3.2 Views и materialized views
- `CREATE VIEW` — read-only virtual table
- `CREATE MATERIALIZED VIEW` — кеширана snapshot + `REFRESH`
- Поддръжка в query planner

### 3.3 Triggers и stored functions
- `CREATE TRIGGER` — `BEFORE`/`AFTER` INSERT/UPDATE/DELETE
- Stored functions in Nim (compiled to UDF):
  ```sql
  CREATE FUNCTION total_price(quantity INT, price DECIMAL) RETURNS DECIMAL
  AS 'quantity * price';
  ```
- Функции за ERP: `vat_calc`, `currency_convert`, `invoice_number_next`

### 3.4 Full-text search за ERP документи
- `CREATE FULLTEXT INDEX ON invoices(content)`
- `WHERE content @@ 'търсене'`
- Bulgarian stemming (reuse `fts/multilang.nim`)

### 3.5 Partitioning
- `CREATE TABLE orders (...) PARTITION BY RANGE (created_at)`
- Автоматичен partition pruning в query planner
- Полезно за ERP: архивиране на стари данни

---

## Фаза 4: Production readiness & DevEx (3–4 седмици)

### 4.1 Backup & Restore
- `baradadb backup --output backup.tar.gz`
- `baradadb restore --input backup.tar.gz`
- Incremental backup чрез WAL archiving
- Point-in-time recovery (PITR)
- Scheduled backups (cron integration)

### 4.2 Docker и deployment
- `Dockerfile` — multi-stage build с Nim
- `docker-compose.yml` — single node + volume
- `docker-compose.raft.yml` — 3-node cluster
- Helm chart за Kubernetes (statefulset + PVC)
- Environment-based config (`BARADB_PORT`, `BARADB_DATA_DIR`, `BARADB_RAFT_PEERS`)

### 4.3 Monitoring и observability
- Structured logging (JSON format)
- Prometheus `/metrics` endpoint:
  - `baradb_queries_total`, `baradb_query_duration_seconds`
  - `baradb_connections_active`, `baradb_storage_size_bytes`
  - `baradb_replication_lag_seconds`
- OpenTelemetry tracing integration
- Slow query log (threshold configurable)

### 4.4 ORM / Client SDK
- **Nim**: `baradb` nimble пакет — fluent query builder + миграции
  ```nim
  let users = db.table("users")
    .where("active", "=", true)
    .orderBy("created_at", "DESC")
    .limit(10)
    .all()
  ```
- **Python**: `pip install baradb` — async/sync client
- **JavaScript/TypeScript**: `npm install baradb` — promise-based client
- **Go**: `go get github.com/baradb/go-client`
- Connection pooling във всички клиенти

### 4.5 Admin Dashboard (Web UI)
- Лек вграден админ панел на `http://host:port/admin`
- SQL playground с резултати в таблица
- Schema browser (таблици, колони, индекси)
- Metrics charts (latency, throughput, storage)
- User management UI

### 4.6 Performance tuning
- Prepared statements кеш
- Query result cache (LRU, TTL-based)
- Connection pool в сървъра (max 1000 конекции)
- Auto-compaction scheduling
- Configurable cache size за page cache

---

## Приоритетна матрица

| Задача | Влияние | Трудност | Приоритет |
|--------|---------|----------|-----------|
| SQL парсър + AST | Критично | Висока | P0 |
| ACID транзакции | Критично | Висока | P0 |
| HTTP REST API | Критично | Средна | P0 |
| B-Tree индекси | Високо | Средна | P1 |
| JWT Auth + RLS | Високо | Средна | P1 |
| Schema migrations | Високо | Средна | P1 |
| Docker + Compose | Средно | Ниска | P2 |
| Backup/Restore | Средно | Средна | P2 |
| WebSocket real-time | Средно | Средна | P2 |
| Admin Dashboard | Средно | Висока | P2 |
| Views + Triggers | Ниско | Средна | P3 |
| Client SDK (ORM) | Ниско | Висока | P3 |
| Partitioning | Ниско | Висока | P3 |
| Kubernetes Helm | Ниско | Средна | P3 |

---

## Очакван резултат

- **Фаза 1:** BaraDB поддържа ANSI SQL subset с ACID транзакции. Може да замени SQLite/PostgreSQL за малки проекти.
- **Фаза 2:** REST API + auth правят базата достъпна от всякакъв web stack. WebSocket добавя real-time възможности.
- **Фаза 3:** ERP-ready фичове — migrations, views, triggers, partitioning. Може да поддържа реален бизнес софтуер.
- **Фаза 4:** Production tooling — Docker, backup, monitoring, ORM, admin UI. Solo-dev може да deploy-не за 5 минути.

**Крайна оценка след плана:** от 8.5/10 към 9.5/10 — готова за production web/ERP.
