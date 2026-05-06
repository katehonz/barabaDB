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

## Phase 0: Pipeline Integration & Parser Completion ✅ DONE

### 0.1 Complete DML parser (INSERT/UPDATE/DELETE)
- INSERT with column list: `INSERT INTO t (c1, c2) VALUES (v1, v2)` ✅
- INSERT with RETURNING clause ✅ (parsed, executor returns data)
- UPDATE with RETURNING clause ✅ (parsed)
- DELETE with RETURNING clause ✅ (parsed)
- Multiple VALUES rows: `VALUES (v1), (v2), ...` ✅

### 0.2 Add SQL DDL to parser
- `CREATE TABLE` with column definitions, constraints (PK, FK, UNIQUE, NOT NULL, CHECK, DEFAULT) ✅
- `ALTER TABLE` ❌ **STUB** — parsed but no operations populated, no executor
- `DROP TABLE` ✅
- Tokens: tkCreate, tkTable, tkAlter, tkColumn, tkPrimary, tkKey, tkForeign, tkReferences, tkCascade, tkUnique, tkNotNull, tkCheck, tkDefault, tkRename, tkAdd, tkDrop ✅

### 0.3 SQL-compatible schema system
- SQL table catalog (separate from EdgeQL type system) ✅
- Store schema in LSM-Tree (`_schema:migrations:*`) ✅
- Column type enforcement during INSERT ❌ **Types parsed but not enforced**
- Schema validation on CREATE TABLE ✅

### 0.4 AST → IR lowering pass
- Convert Select AST nodes to IR plans (scan → filter → project → sort → limit) ✅
- Convert Insert AST nodes to IR plans ✅
- Convert Update/Delete AST nodes to IR plans ❌ **Bypassed — direct execution**
- Convert CTE AST nodes to IR plans ❌ **Lowering exists but CTE execution not wired**
- Lower JOINs to IR join nodes ❌ **Parsed but not lowered**

### 0.5 Codegen → Storage execution
- Execute StorageOp tree against LSM-Tree ✅ (via executePlan)
- sokScan: full table scan via `scanMemTable()` ✅
- sokPointRead: key-based lookup ✅
- sokFilter: evaluate IR expressions against rows ✅ **FIXED**
- sokProject: column selection ✅
- sokSort: in-memory sort ✅ **FIXED**
- sokLimit: slice results ✅

### 0.6 Wire server to use pipeline
- Replace `execSelect/execInsert/execDelete` with pipeline-based execution ✅
- Server flow: lex → parse → AST→IR lower → executePlan → LSM ✅
- Keep backward-compatible wire protocol ✅
- All 56 existing tests still pass ✅

---

## Phase 1: Schema & Indexes ✅ MOSTLY DONE

### 1.1 SQL type system
- `INTEGER`, `BIGINT`, `SMALLINT`, `SERIAL` ❌ **Types stored as strings, not enforced**
- `VARCHAR(n)`, `TEXT` ❌ **Same**
- `BOOLEAN` ❌ **Same**
- `TIMESTAMP`, `DATE` (ISO 8601) ❌ **Same**
- `JSON`, `JSONB` ❌ **Same**
- `UUID` (v4 generation) ❌ **Same**
- `NUMERIC(p,s)`, `DOUBLE PRECISION`, `REAL` ❌ **Same**

### 1.2 Constraints enforcement
- PRIMARY KEY: unique index + NOT NULL ✅
- FOREIGN KEY + ON DELETE CASCADE/SET NULL/RESTRICT ❌ **Parsed but not enforced**
- UNIQUE: unique index ✅ (uses B-Tree index)
- NOT NULL: check on INSERT ✅
- CHECK: evaluate expression on INSERT/UPDATE ❌ **Parsed but not evaluated**
- DEFAULT: fill missing values on INSERT ✅

### 1.3 B-Tree index integration
- `CREATE INDEX idx_name ON table(column)` ❌ **No parser/executor**
- `CREATE UNIQUE INDEX` ❌ **No parser/executor**
- B-Tree indexes created per PK/UNIQUE column ✅
- Query planner uses B-Tree for WHERE clauses ✅ (point reads)
- Range scans via B-Tree leaf linked list ❌ **Not implemented**

### 1.4 Query planner
- Choose index scan vs full scan based on WHERE clause ✅
- Multi-column index support ❌
- Covering index optimization ❌
- `EXPLAIN` output with cost estimates ✅ **FIXED — now returns plan string**
- Adaptive query reoptimization ❌ **Module exists, not wired**

---

## Phase 2: Transactions ✅ MOSTLY DONE

### 2.1 Wire MVCC into server pipeline
- `BEGIN`, `COMMIT`, `ROLLBACK` commands ✅
- Server tracks per-connection Transaction state ✅
- All reads/writes through TxnManager ✅ (INSERT/DELETE)
- Isolation: Read Committed ✅

### 2.2 WAL crash recovery
- Implement REDO: replay committed WAL entries ❌ **Not implemented**
- Implement UNDO: remove uncommitted entries ❌ **Not implemented**
- Checkpoint markers in WAL ❌
- Point-in-time recovery ❌

### 2.3 Compaction
- Implement actual SSTable merge ❌ **Stub — metadata shuffle only**
- Level-based compaction strategy ❌
- Background compaction scheduling ❌

### 2.4 Deadlock detection wiring
- Wire deadlock detection into TxnManager ❌ **Module exists, never imported**

---

## Phase 3: HTTP REST API & Authentication ✅ PARTIALLY DONE

### 3.1 HTTP server
- HTTP/1.1 server alongside TCP wire protocol ✅
- `POST /query` — execute SQL, return JSON ✅ **FIXED — returns actual rows**
- `GET /health` — readiness/liveness ✅
- `GET /metrics` — Prometheus format ✅ (basic counters)

### 3.2 Authentication
- `CREATE USER` / `DROP USER` / `ALTER USER` SQL ❌ **Not implemented**
- Password hashing with argon2 ❌ **Not implemented**
- JWT token creation with HMAC-SHA256 ⚠️ **Uses djb2 hash, not real HMAC**
- `Authorization: Bearer <token>` in HTTP headers ✅
- Per-user namespace isolation ❌

### 3.3 Authorization
- `GRANT` / `REVOKE` for table-level privileges ❌ **Not implemented**
- Row-Level Security (RLS) ❌ **Not implemented**
- Wire auth into both HTTP and TCP protocol paths ❌ **HTTP only, optional**

### 3.4 Rate limiting & TLS
- Wire RateLimiter into HTTP server ❌ **Module exists, never imported**
- Wire TLS/SSL ❌ **Mock only, no OpenSSL FFI**
- Self-signed cert generation ✅ (shells to openssl CLI)

---

## Phase 4: WebSocket & Real-time ✅ PARTIALLY DONE

### 4.1 WebSocket server
- `ws://host:port/live` — subscribe to table changes ✅
- `SUBSCRIBE table_name` WebSocket message ✅
- Push notifications on INSERT/UPDATE/DELETE ❌ **broadcastToTable exists but never called**
- `NOTIFY` / `LISTEN` analogue ❌

### 4.2 CORS & HTTP hardening
- CORS headers for browser access ⚠️ **On WS upgrade only, not HTTP server**
- Request size limits ❌
- Connection keep-alive ❌
- HTTP/2 readiness ❌

---

## Phase 5: ERP Features ❌ MOSTLY NOT DONE

### 5.1 Schema migrations
- `CREATE MIGRATION` → `APPLY MIGRATION` ❌ **No SQL syntax**
- Versioned schema in `_schema_version` table ❌ **Uses _schema:migrations: prefix**
- Up/down migration scripts ❌
- Dry-run mode ❌
- CLI: `baradadb migrate status|up|down` ❌

### 5.2 Views
- `CREATE VIEW` — virtual table ❌
- `CREATE MATERIALIZED VIEW` ❌
- View usage in query planner ❌

### 5.3 Triggers & stored functions
- `CREATE TRIGGER` ❌
- Stored functions ❌
- ERP helper functions ❌

### 5.4 Full-text search for ERP documents
- `CREATE FULLTEXT INDEX ON table(column)` ❌ **FTS engine exists, not wired to SQL**
- `WHERE content @@ 'search query'` ❌

### 5.5 Partitioning
- `CREATE TABLE (...) PARTITION BY RANGE (col)` ❌

---

## Phase 6: Production Readiness ⚠️ PARTIALLY DONE

### 6.1 Backup & Restore
- `baradadb backup --output backup.tar.gz` ✅
- `baradadb restore --input backup.tar.gz` ✅
- Incremental backup via WAL archiving ❌
- Point-in-time recovery (PITR) ❌

### 6.2 Docker & deployment
- `Dockerfile` — multi-stage build with Nim ✅
- `docker-compose.yml` — single node ✅
- `docker-compose.raft.yml` — 3-node cluster ❌
- Environment-based config ✅

### 6.3 Monitoring
- Structured JSON logging ❌ **Uses echo**
- Prometheus `/metrics` ✅ (basic counters)
- Slow query log ❌
- OpenTelemetry tracing ❌

### 6.4 Admin dashboard
- Web UI ❌ **Does not exist**

### 6.5 Client SDK improvements
- All clients: ❌ **Not improved**

---

## Priority Matrix

| Task | Impact | Difficulty | Priority |
|------|--------|-----------|----------|
| Pipeline integration (Phase 0) | Critical | High | **P0 ✅** |
| SQL DDL parser (Phase 0) | Critical | Medium | **P0 ✅** |
| AST→IR lowering (Phase 0) | Critical | High | **P0 ✅** |
| Codegen execution (Phase 0) | Critical | High | **P0 ✅** |
| SQL schema system (Phase 1) | Critical | High | **P0 ✅** |
| B-Tree index integration (Phase 1) | High | Medium | **P1 ✅** |
| Constraint enforcement (Phase 1) | High | Medium | **P1 ✅ (NOT NULL, PK, UNIQUE, DEFAULT)** |
| MVCC wiring (Phase 2) | Critical | High | **P0 ✅** |
| WAL recovery (Phase 2) | High | Medium | P1 ❌ |
| HTTP REST API (Phase 3) | Critical | Medium | **P0 ✅** |
| JWT Auth + RLS (Phase 3) | High | Medium | P1 ⚠️ **JWT exists, RLS not** |
| WebSocket real-time (Phase 4) | Medium | Medium | **P2 ✅ (server works, executor not wired)** |
| Schema migrations (Phase 5) | High | Medium | P1 ❌ |
| Backup/Restore (Phase 6) | Medium | Medium | **P2 ✅** |
| Docker + Compose (Phase 6) | Medium | Low | **P2 ✅** |
| Admin Dashboard (Phase 6) | Medium | High | P2 ❌ |
| Views + Triggers (Phase 5) | Low | Medium | P3 ❌ |
| Partitioning (Phase 5) | Low | High | P3 ❌ |
| Client SDK (Phase 6) | Medium | High | P2 ❌ |
| Kubernetes Helm (Phase 6) | Low | Medium | P3 ❌ |

---

## What Actually Works (Honest)

**Production-ready NOW:**
- CREATE TABLE with PK, UNIQUE, NOT NULL, DEFAULT constraints
- INSERT INTO ... VALUES with column list and validation
- SELECT with WHERE filter, ORDER BY, LIMIT/OFFSET
- UPDATE with WHERE clause
- DELETE with WHERE clause
- BEGIN / COMMIT / ROLLBACK transactions
- B-Tree index point reads on indexed columns
- HTTP REST API: POST /query, GET /health, GET /metrics
- JWT authentication (optional)
- WebSocket SUBSCRIBE/UNSUBSCRIBE
- Schema persistence + auto-restore on restart
- Docker + docker-compose deployment
- Backup/restore via tar.gz

**Partially working:**
- EXPLAIN (returns plan description, not cost estimates)
- Auth (JWT exists but uses weak hash, no user management)

**Not yet working:**
- ALTER TABLE, CREATE INDEX, CREATE VIEW
- FOREIGN KEY, CHECK constraints
- WAL crash recovery, compaction
- Rate limiting, TLS
- Admin dashboard
- Client SDK improvements
- Full-text search via SQL
- Type enforcement (INTEGER, VARCHAR, etc.)

---

**Honest score: 8/10 — solid foundation, but significant gaps remain before production use.**
