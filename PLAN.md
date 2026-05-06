# BaraDB — Production Roadmap (Web & ERP)

## Vision
BaraDB as a production-ready database for:
- **Web applications** (blogs, e-commerce, SaaS)
- **Small ERP systems** (CRM, warehouse, accounting, invoicing)

> Target user: solo-dev / small team wanting a fast local DB without PostgreSQL/MySQL dependency.

---

## Current State (Baseline)

| Component | Status |
|-----------|--------|
| LSM-Tree KV store | Stable, thread-safe, persistent |
| HNSW vector search | Working, recall > 0.9 |
| TCP wire protocol | Binary, SELECT/INSERT/DELETE |
| Raft consensus | TCP transport, leader election |
| Graph engine | In-memory + persistence |
| CI/CD | GitHub Actions |
| Test suite | 56 suites, ~250 tests |

**Critical gaps for production:**
- Server bypasses IR/codegen/MVCC/schema — `executeQuery()` does lex→parse→raw LSMTree calls
- INSERT parser incomplete (no VALUES, column list, RETURNING)
- No CREATE TABLE/ALTER TABLE/DROP TABLE in parser
- MVCC not wired to query path (no BEGIN/COMMIT/ROLLBACK in server)
- B-Tree indexes not integrated with LSM-Tree
- SQL schema system not connected (EdgeQL types only)
- No HTTP REST API
- Auth not wired to server

---

## Phase 0: Pipeline Integration & Parser Completion (2–3 weeks) **← IN PROGRESS**

### 0.1 Complete DML parser (INSERT/UPDATE/DELETE)
- INSERT with column list: `INSERT INTO t (c1, c2) VALUES (v1, v2)`
- INSERT with RETURNING clause
- UPDATE with RETURNING clause
- DELETE with RETURNING clause
- Multiple VALUES rows: `VALUES (v1), (v2), ...`

### 0.2 Add SQL DDL to parser
- `CREATE TABLE` with column definitions, constraints (PK, FK, UNIQUE, NOT NULL, CHECK, DEFAULT)
- `ALTER TABLE` (ADD COLUMN, DROP COLUMN, RENAME COLUMN)
- `DROP TABLE`
- Tokens: tkCreate, tkTable, tkAlter, tkColumn, tkPrimary, tkKey, tkForeign, tkReferences, tkCascade, tkUnique, tkNotNull, tkCheck, tkDefault, tkRename, tkAdd, tkDrop

### 0.3 SQL-compatible schema system
- SQL table catalog (separate from EdgeQL type system)
- Store schema in LSM-Tree (`_schema_tables`, `_schema_columns`, `_schema_indexes`)
- Column type enforcement during INSERT/UPDATE
- Schema validation on CREATE TABLE

### 0.4 AST → IR lowering pass
- Convert Select AST nodes to IR plans (scan → filter → project → sort → limit)
- Convert Insert AST nodes to IR plans (values)
- Convert Update/Delete AST nodes to IR plans
- Convert CTE AST nodes to IR plans
- Lower JOINs to IR join nodes

### 0.5 Codegen → Storage execution
- Execute StorageOp tree against LSM-Tree
- sokScan: full table scan via `scanMemTable()` / SSTable reader
- sokPointRead: key-based lookup
- sokFilter: evaluate IR expressions against rows
- sokProject: column selection
- sokSort: in-memory sort
- sokLimit: slice results
- sokInsert/sokUpdate/sokDelete: write to LSM-Tree

### 0.6 Wire server to use pipeline
- Replace `execSelect/execInsert/execDelete` with pipeline-based execution
- Server flow: lex → parse → AST→IR lower → codegen → execute StorageOp
- Keep backward-compatible wire protocol
- All 56 existing tests must still pass

---

## Phase 1: Schema & Indexes (2–3 weeks)

### 1.1 SQL type system
- `INTEGER`, `BIGINT`, `SMALLINT`, `SERIAL` (auto-increment on INSERT)
- `VARCHAR(n)`, `TEXT`
- `BOOLEAN`
- `TIMESTAMP`, `DATE` (ISO 8601)
- `JSON`, `JSONB`
- `UUID` (v4 generation)
- `NUMERIC(p,s)`, `DOUBLE PRECISION`, `REAL`

### 1.2 Constraints enforcement
- PRIMARY KEY: unique index + NOT NULL
- FOREIGN KEY + ON DELETE CASCADE/SET NULL/RESTRICT
- UNIQUE: unique index
- NOT NULL: check on INSERT/UPDATE
- CHECK: evaluate expression on INSERT/UPDATE
- DEFAULT: fill missing values on INSERT

### 1.3 B-Tree index integration
- `CREATE INDEX idx_name ON table(column)`
- `CREATE UNIQUE INDEX`
- B-Tree indexes created per table column
- Query planner uses B-Tree for WHERE clauses on indexed columns
- Range scans via B-Tree leaf linked list

### 1.4 Query planner
- Choose index scan vs full scan based on WHERE clause
- Multi-column index support
- Covering index optimization
- `EXPLAIN` output with cost estimates
- Adaptive query reoptimization (wire up `adaptive.nim`)

---

## Phase 2: Transactions (2–3 weeks)

### 2.1 Wire MVCC into server pipeline
- `BEGIN`, `COMMIT`, `ROLLBACK` commands
- Server tracks per-connection Transaction state
- All reads/writes through TxnManager
- Isolation: Read Committed (Phase 2a), Repeatable Read (Phase 2b)

### 2.2 WAL crash recovery
- Implement REDO: replay committed WAL entries into LSM-Tree
- Implement UNDO: remove uncommitted entries on recovery
- Checkpoint markers in WAL
- Point-in-time recovery

### 2.3 Compaction
- Implement actual SSTable merge (currently simulated)
- Read multiple SSTables, merge key-value pairs, write merged SSTable
- Level-based compaction strategy
- Background compaction scheduling

### 2.4 Deadlock detection wiring
- Wire deadlock detection into TxnManager
- Automatic deadlock timeout and victim selection
- Client notification on rollback

---

## Phase 3: HTTP REST API & Authentication (2–3 weeks)

### 3.1 HTTP server
- HTTP/1.1 server alongside TCP wire protocol (shared port or separate)
- `POST /query` — execute SQL, return JSON
- `GET /health` — readiness/liveness
- `GET /metrics` — Prometheus format
- Content-Type: `application/json`

### 3.2 Authentication
- `CREATE USER` / `DROP USER` / `ALTER USER` SQL
- Password hashing with argon2
- JWT token creation with HMAC-SHA256 (replace djb2 `simpleHash`)
- `Authorization: Bearer <token>` in HTTP headers
- Per-user namespace isolation

### 3.3 Authorization
- `GRANT` / `REVOKE` for table-level privileges (SELECT, INSERT, UPDATE, DELETE)
- Row-Level Security (RLS): `CREATE POLICY` on tables
- Wire auth into both HTTP and TCP protocol paths

### 3.4 Rate limiting & TLS
- Wire RateLimiter into HTTP server (token bucket per IP)
- Wire TLS/SSL using OpenSSL FFI (not mock)
- Self-signed cert generation
- Configurable TLS via `baradadb cert create`

---

## Phase 4: WebSocket & Real-time (1–2 weeks)

### 4.1 WebSocket server
- `ws://host:port/live` — subscribe to table changes
- `SUBSCRIBE table_name` WebSocket message
- Push notifications on INSERT/UPDATE/DELETE
- `NOTIFY` / `LISTEN` analogue

### 4.2 CORS & HTTP hardening
- CORS headers for browser access
- Request size limits (10MB default)
- Connection keep-alive
- HTTP/2 readiness (ALPN negotiation)

---

## Phase 5: ERP Features (3–4 weeks)

### 5.1 Schema migrations
- `CREATE MIGRATION` → `APPLY MIGRATION`
- Versioned schema in `_schema_version` table
- Up/down migration scripts
- Dry-run mode
- CLI: `baradadb migrate status|up|down`

### 5.2 Views
- `CREATE VIEW` — virtual table (stored query)
- `CREATE MATERIALIZED VIEW` — cached snapshot + `REFRESH`
- View usage in query planner

### 5.3 Triggers & stored functions
- `CREATE TRIGGER` — BEFORE/AFTER on INSERT/UPDATE/DELETE
- Stored functions in Nim (compile to UDF)
- ERP helper functions: `vat_calc`, `currency_convert`, `invoice_number_next`

### 5.4 Full-text search for ERP documents
- `CREATE FULLTEXT INDEX ON table(column)`
- `WHERE content @@ 'search query'`
- Bulgarian stemming integration

### 5.5 Partitioning
- `CREATE TABLE (...) PARTITION BY RANGE (col)`
- Auto partition pruning in query planner
- Useful for ERP: archive old data by date range

---

## Phase 6: Production Readiness (2–3 weeks)

### 6.1 Backup & Restore
- `baradadb backup --output backup.tar.gz`
- `baradadb restore --input backup.tar.gz`
- Incremental backup via WAL archiving
- Point-in-time recovery (PITR)

### 6.2 Docker & deployment
- `Dockerfile` — multi-stage build with Nim
- `docker-compose.yml` — single node
- `docker-compose.raft.yml` — 3-node cluster
- Environment-based config (`BARADB_PORT`, `BARADB_DATA_DIR`)

### 6.3 Monitoring
- Structured JSON logging
- Prometheus `/metrics`: `baradb_queries_total`, `baradb_query_duration_s`, `baradb_connections_active`, `baradb_storage_size_bytes`
- Slow query log (configurable threshold)
- OpenTelemetry tracing

### 6.4 Admin dashboard
- Web UI on `http://host:port/admin`
- SQL playground with results table
- Schema browser (tables, columns, indexes)
- Metrics charts
- User management UI

### 6.5 Client SDK improvements
- Nim: transaction API, prepared statements, auth
- Python: complete result parsing, transaction API, async support
- JavaScript: actual TCP/WebSocket connection, complete result parsing
- Go: complete result parsing, transaction API
- Rust: complete result parsing, transaction API
- Connection pooling in all clients

---

## Priority Matrix

| Task | Impact | Difficulty | Priority |
|------|--------|-----------|----------|
| Pipeline integration (Phase 0) | Critical | High | **P0** |
| SQL DDL parser (Phase 0) | Critical | Medium | **P0** |
| AST→IR lowering (Phase 0) | Critical | High | **P0** |
| Codegen execution (Phase 0) | Critical | High | **P0** |
| SQL schema system (Phase 1) | Critical | High | **P0** |
| B-Tree index integration (Phase 1) | High | Medium | P1 |
| Constraint enforcement (Phase 1) | High | Medium | P1 |
| MVCC wiring (Phase 2) | Critical | High | **P0** |
| WAL recovery (Phase 2) | High | Medium | P1 |
| HTTP REST API (Phase 3) | Critical | Medium | **P0** |
| JWT Auth + RLS (Phase 3) | High | Medium | P1 |
| WebSocket real-time (Phase 4) | Medium | Medium | P2 |
| Schema migrations (Phase 5) | High | Medium | P1 |
| Backup/Restore (Phase 6) | Medium | Medium | P2 |
| Docker + Compose (Phase 6) | Medium | Low | P2 |
| Admin Dashboard (Phase 6) | Medium | High | P2 |
| Views + Triggers (Phase 5) | Low | Medium | P3 |
| Partitioning (Phase 5) | Low | High | P3 |
| Client SDK (Phase 6) | Medium | High | P2 |
| Kubernetes Helm (Phase 6) | Low | Medium | P3 |

---

## Expected Results

- **Phase 0:** Server uses full pipeline. INSERT/UPDATE/DELETE/CREATE TABLE work properly. 56 existing tests pass + new tests.
- **Phase 1:** SQL schema with constraints, B-Tree indexes, EXPLAIN. Can define tables with PKs, FKs, and indexes.
- **Phase 2:** ACID transactions with MVCC, WAL recovery, compaction. Can use BEGIN/COMMIT/ROLLBACK.
- **Phase 3:** HTTP REST API with JWT auth, user management, rate limiting. DB accessible from browser.
- **Phase 4:** Real-time WebSocket subscriptions. Notifications on data changes.
- **Phase 5:** ERP-grade features: migrations, views, triggers, partitioning, full-text search.
- **Phase 6:** Docker, backup, monitoring, admin UI. Deploy in 5 minutes.

**Final score after plan:** 9.5/10 — production-ready for web/ERP workloads.
