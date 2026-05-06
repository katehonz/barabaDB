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
- `ALTER TABLE ADD COLUMN` ✅
- `DROP TABLE` ✅
- `CREATE INDEX` / `CREATE UNIQUE INDEX` ✅
- Tokens: tkCreate, tkTable, tkAlter, tkColumn, tkPrimary, tkKey, tkForeign, tkReferences, tkCascade, tkUnique, tkNotNull, tkCheck, tkDefault, tkRename, tkAdd, tkDrop ✅

### 0.3 SQL-compatible schema system
- SQL table catalog (separate from EdgeQL type system) ✅
- Store schema in LSM-Tree (`_schema:migrations:*`) ✅
- Column type enforcement during INSERT ✅ (INTEGER, FLOAT, BOOLEAN, TIMESTAMP)
- Schema validation on CREATE TABLE ✅

### 0.4 AST → IR lowering pass
- Convert Select AST nodes to IR plans (scan → filter → project → sort → limit) ✅
- Convert Insert AST nodes to IR plans ✅
- Convert Update/Delete AST nodes to IR plans ✅ (direct execution with WHERE filter)
- CTE AST nodes ❌ **Parsed but not executed**
- Lower JOINs to IR join nodes ❌ **Parsed but not lowered**

### 0.5 Codegen → Storage execution
- Execute StorageOp tree against LSM-Tree ✅ (via executePlan)
- sokScan: full table scan via `scanMemTable()` ✅
- sokPointRead: key-based lookup ✅
- sokFilter: evaluate IR expressions against rows ✅
- sokProject: column selection ✅
- sokSort: in-memory sort ✅
- sokLimit: slice results ✅
- sokGroupBy: row grouping with count(*) aggregation ✅

### 0.6 Wire server to use pipeline
- Replace `execSelect/execInsert/execDelete` with pipeline-based execution ✅
- Server flow: lex → parse → AST→IR lower → executePlan → LSM ✅
- Keep backward-compatible wire protocol ✅
- All 56 existing tests still pass ✅

---

## Phase 1: Schema & Indexes ✅ DONE

### 1.1 SQL type system
- `INTEGER`, `BIGINT`, `SMALLINT`, `SERIAL` ✅ (validated on INSERT)
- `FLOAT`, `REAL`, `DOUBLE PRECISION`, `NUMERIC` ✅ (validated on INSERT)
- `BOOLEAN` ✅ (validated: true/false/1/0/t/f/yes/no)
- `TIMESTAMP`, `DATE` ✅ (minimal format validation)
- `VARCHAR(n)`, `TEXT` ⚠️ (stored, no length enforcement)
- `JSON`, `JSONB` ❌ **Stored as string**
- `UUID` (v4 generation) ❌

### 1.2 Constraints enforcement
- PRIMARY KEY: unique index + NOT NULL ✅
- FOREIGN KEY: checks referenced row exists on INSERT ✅
- UNIQUE: unique index via B-Tree ✅
- NOT NULL: check on INSERT ✅
- CHECK: parsed ❌ **Expression not evaluated yet**
- DEFAULT: fill missing values on INSERT ✅ (works for all literal types)

### 1.3 B-Tree index integration
- `CREATE INDEX idx_name ON table(column)` ✅
- `CREATE UNIQUE INDEX` ✅
- B-Tree indexes created per PK/UNIQUE column ✅
- Query planner uses B-Tree for WHERE clauses ✅ (point reads)
- Range scans via B-Tree leaf linked list ❌ **Not implemented**

### 1.4 Query planner
- Choose index scan vs full scan based on WHERE clause ✅
- Multi-column index support ❌
- Covering index optimization ❌
- `EXPLAIN` output ✅ (returns plan description with index info)
- Adaptive query reoptimization ❌ **Module exists, not wired**

---

## Phase 2: Transactions ✅ DONE

### 2.1 Wire MVCC into server pipeline
- `BEGIN`, `COMMIT`, `ROLLBACK` commands ✅
- Server tracks per-connection Transaction state ✅
- All reads/writes through TxnManager ✅ (INSERT/DELETE)
- Isolation: Read Committed ✅

### 2.2 WAL crash recovery
- Implement REDO: replay committed WAL entries ✅
- Implement UNDO: skip uncommitted entries ✅
- Checkpoint markers in WAL ⚠️ (WAL commit markers on flush)
- Point-in-time recovery ❌

### 2.3 Compaction
- Implement actual SSTable merge ✅ (reads entries, merges by key, deduplicates, removes tombstones)
- Level-based compaction strategy ⚠️ (structure exists, manual trigger)
- Background compaction scheduling ❌

### 2.4 Deadlock detection wiring
- Wire deadlock detection into TxnManager ❌ **Module exists, never imported**

---

## Phase 3: HTTP REST API & Authentication ✅ DONE

### 3.1 HTTP server (hunos)
- Multi-threaded HTTP/1.1 + HTTP/2 server via hunos ✅
- `POST /query` — execute SQL, return JSON ✅
- `GET /health` — readiness/liveness ✅
- `GET /metrics` — Prometheus format ✅
- `POST /auth` — JWT login endpoint ✅
- `GET /api` — OpenAPI 3.0 spec ✅
- CORS via hunos corsMiddleware ✅
- Rate limiting via hunos ratelimit ✅

### 3.2 Authentication (jwt-nim-baraba)
- JWT token creation with HMAC-SHA256 (BearSSL) ✅
- JWT token verification with time claims ✅
- `Authorization: Bearer <token>` in HTTP headers ✅
- `CREATE USER` / `DROP USER` / `ALTER USER` SQL ❌ **Not implemented**
- Password hashing with argon2 ❌
- Per-user namespace isolation ❌

### 3.3 Authorization
- `GRANT` / `REVOKE` for table-level privileges ❌ **Not implemented**
- Row-Level Security (RLS) ❌
- Wire auth into both HTTP and TCP protocol paths ⚠️ **HTTP only**

### 3.4 TLS
- Wire TLS/SSL ❌ **Mock only, no OpenSSL FFI**
- Self-signed cert generation ✅ (shells to openssl CLI)

---

## Phase 4: WebSocket & Real-time ✅ DONE

### 4.1 WebSocket server
- `ws://host:port/live` — subscribe to table changes ✅
- `SUBSCRIBE table_name` / `UNSUBSCRIBE table_name` ✅
- Push notifications on INSERT/UPDATE/DELETE ✅ (onChange callback wired)
- `NOTIFY` / `LISTEN` analogue ❌

### 4.2 CORS & HTTP hardening
- CORS headers for browser access ✅ (via hunos middleware)
- Request size limits ✅ (via hunos maxBodyLen)
- HTTP/2 readiness ✅ (via hunos h2c support)

---

## Phase 5: ERP Features ❌ MOSTLY NOT DONE

### 5.1 Schema migrations
- `CREATE MIGRATION` → `APPLY MIGRATION` ❌ **No SQL syntax**
- Versioned schema in `_schema_version` table ⚠️ **Uses _schema:migrations: prefix**
- Up/down migration scripts ❌
- Dry-run mode ❌
- CLI: `baradadb migrate status|up|down` ❌

### 5.2 Views
- `CREATE VIEW` — virtual table ❌
- `CREATE MATERIALIZED VIEW` ❌

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
- `docker-compose.yml` — single node ✅ (healthcheck via wget)
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
| Constraint enforcement (Phase 1) | High | Medium | **P1 ✅** |
| MVCC wiring (Phase 2) | Critical | High | **P0 ✅** |
| WAL recovery (Phase 2) | High | Medium | **P1 ✅** |
| SSTable compaction (Phase 2) | High | Medium | **P1 ✅** |
| HTTP REST API (Phase 3) | Critical | Medium | **P0 ✅** |
| JWT Auth (Phase 3) | High | Medium | **P1 ✅** |
| WebSocket real-time (Phase 4) | Medium | Medium | **P2 ✅** |
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
- CREATE TABLE with PK, FK, UNIQUE, NOT NULL, DEFAULT, type enforcement
- CREATE INDEX / CREATE UNIQUE INDEX
- INSERT INTO ... VALUES with column list, validation, type checking
- SELECT with WHERE filter (real evaluation), ORDER BY (real sorting), GROUP BY, LIMIT/OFFSET
- UPDATE with WHERE clause (real row modification)
- DELETE with WHERE clause (real row deletion with filter)
- BEGIN / COMMIT / ROLLBACK transactions (MVCC)
- B-Tree index creation, population, and point reads
- FOREIGN KEY enforcement (checks referenced row exists)
- Type enforcement (INTEGER, FLOAT, BOOLEAN, TIMESTAMP validated)
- LIKE pattern matching (regex)
- EXPLAIN output with index usage info
- HTTP REST API via hunos (multi-threaded, CORS, rate limiting)
- JWT authentication via jwt-nim-baraba (HS256 BearSSL)
- WebSocket SUBSCRIBE/UNSUBSCRIBE with broadcast on data changes
- Schema persistence + auto-restore on restart
- WAL crash recovery (REDO committed, UNDO uncommitted)
- SSTable compaction (real merge, dedup, tombstone cleanup)
- Docker + docker-compose deployment
- Backup/restore via tar.gz
- OpenAPI 3.0 spec at GET /api

**Partially working:**
- ALTER TABLE ADD COLUMN (basic, no DROP/RENAME)
- CTE (WITH clause) — parsed but not executed
- JOINs — parsed but not executed
- CHECK constraints — parsed but not evaluated

**Not yet working:**
- CREATE VIEW, CREATE TRIGGER
- Schema migrations via SQL
- WAL point-in-time recovery
- Background compaction scheduling
- Deadlock detection wiring
- TLS/SSL (mock only)
- GRANT/REVOKE, Row-Level Security
- Admin dashboard
- Client SDK improvements
- Full-text search via SQL
- Partitioning

---

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [hunos](https://github.com/katehonz/hunos) | >= 1.2.0 | Multi-threaded HTTP/WebSocket server |
| [jwt-nim-baraba](https://github.com/katehonz/jwt-nim-baraba) | >= 2.1.0 | JWT authentication (HS256 BearSSL) |

---

**Honest score: 8.5/10 — solid foundation with real HTTP server, JWT auth, WAL recovery, and compaction. Remaining gaps: views, triggers, migrations, admin UI.**
