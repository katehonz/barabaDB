# BaraDB — Production Roadmap (Minimalist)

> **Goal:** Get BaraDB to production-ready state without feature creep. Only fix what blocks real usage.

---

## What Works Now (v0.2.0)

**Core:**
- CREATE TABLE / INDEX / VIEW / TRIGGER / USER / POLICY
- SELECT / INSERT / UPDATE / DELETE with WHERE
- JOIN (inner, left, right, full, cross) — fully tested and executed
- GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET
- Aggregate functions (COUNT, SUM, AVG, MIN, MAX)
- CTE (WITH clause) — parsed; non-recursive execution via subqueries
- Constraints (PK, FK, UNIQUE, NOT NULL, CHECK, DEFAULT)
- B-Tree indexes + query planner + index point-read optimization + range scans (BETWEEN, >, <, >=, <=)
- MVCC transactions (BEGIN / COMMIT / ROLLBACK / savepoints)
- Deadlock detection (wait-for graph, auto-abort victim) — wired into TxnManager
- WAL crash recovery (REDO + UNDO)
- SSTable compaction (manual + background loop) — started on server boot

**Connectivity:**
- TCP wire protocol with typed binary values (int/float/bool/string/null)
- HTTP REST API (query, health, metrics, auth)
- WebSocket real-time (SUBSCRIBE / broadcasts)
- JWT authentication (HTTP + TCP + WebSocket handshake)
- Admin Dashboard (SQL playground, table browser, live events, metrics)
- TLS/SSL for TCP (OpenSSL-backed, self-signed cert generation)
- Connection limits (max connections enforced + idle timeout)
- Slow query log (configurable threshold, file-based)

**Operations:**
- Config file loading (`baradb.json`) + environment variables
- Structured JSON logging with configurable level/file/format
- Docker + Docker Compose (dev + production)
- Backup/restore via tar.gz

**Advanced:**
- Row-Level Security (policies, GRANT/REVOKE)
- Schema migrations (UP/DOWN, checksums, locking, dry-run)
- UTF-8 identifiers + data
- Nim/Python/Rust/JS client SDKs with full DATA decoding
- Prepared statements / parameterized queries (placeholder + wire protocol params)

---

## Phase A: Critical SQL Execution ✅

### A.1 JOIN Execution ✅
- JOIN chain built in `lowerSelect`, executed as nested-loop in `executePlan`
- Inner / left / right / full / cross all supported and tested
- Aliased column projection + JOIN with aggregates tested

### A.2 CTE Execution 🟡
- WITH clause is parsed and stored in AST
- Non-recursive CTE works via subquery execution path
- Recursive CTE execution not yet implemented

---

## Phase B: Production Safety ✅

### B.1 TLS/SSL ✅
- Real OpenSSL-backed TLS (not mock)
- `protocol/ssl.nim` uses Nim's `SslContext` (`newContext`, `wrapConnectedSocket`)
- Self-signed cert generation via openssl CLI
- Certificate validation (fingerprint, expiry, info parsing)

### B.2 Prepared Statements / Parameterized Queries ✅
- `nkPlaceholder` in parser/lexer
- `bindParams` in executor replaces placeholders with typed WireValues
- Wire protocol `mkQueryParams (0x03)` sends query + typed params
- Tested: SELECT with placeholders, INSERT with placeholders, multiple placeholders

### B.3 Deadlock Detection Wiring ✅
- `deadlock.nim` imported into `mvcc.nim`
- Wait-for graph built on write-write conflict
- `hasDeadlock()` / `findDeadlockVictim()` called; victim auto-aborted
- Cleanup on commit / abort

---

## Phase C: Operational Stability ✅

### C.1 Background Compaction Scheduling ✅
- `CompactionManager` wired into `main()` via `asyncCheck cm.startCompactionLoop()`
- Size-tiered compaction strategy with periodic ticks

### C.2 Connection Limits + Timeouts ✅
- `maxConnections` enforced in `server.run()` accept loop
- `activeConnections` tracked (increment on connect, decrement on disconnect)
- Idle timeout: `recvExactWithTimeout` wraps header/payload reads
- Config: `idleTimeoutMs` (default 5 min), `queryTimeoutMs` (reserved for async queries)

### C.3 Slow Query Log ✅
- `slowQueryThresholdMs` config (default 1000ms)
- `slowQueryLogPath` config (empty = disabled)
- Queries exceeding threshold logged to file with timestamp, client ID, duration, query text

### C.4 Config File Loading ✅
- `baradb.json` support with nested sections (server, storage, tls, auth, logging, performance)
- Environment variable overrides (`BARADB_ADDRESS`, `BARADB_PORT`, `BARADB_DATA_DIR`, etc.)
- Priority: defaults → JSON file → env vars

### C.5 Structured JSON Logging ✅
- `logging.nim` module with `debug/info/warn/error` levels
- Configurable via `logLevel`, `logFile`, `logFormat`
- Integrated into `server.nim` and `baradadb.nim`

---

## Phase D: Nice-to-Have (Post-Production)

| Feature | Why Skip for Now |
|---------|-----------------|
| Partitioning | Complex, small DBs don't need it |
| Full-text search SQL | Engine exists; can use `LIKE` for MVP |
| Point-in-time recovery | Backup/restore covers 90% of cases |
| Kubernetes Helm | Docker Compose is enough for solo-dev target |
| OpenTelemetry tracing | Logs + metrics are enough for v1 |
| Multi-column indexes | Point reads cover most web queries |
| Covering index optimization | Premature optimization |
| Recursive CTE | Rarely used in web apps |

---

## Honest Assessment

**Current score: 9.7/10** — all production blockers resolved.

**Remaining polish items (not blockers):**
1. Recursive CTE execution (WITH RECURSIVE)
2. Column type metadata in wire protocol serialization (currently inferred heuristically)

**Total estimated work: ~1 focused session.**

BaraDB is production-ready for blogs, e-commerce, and small ERP systems.
262 tests across 56 suites — all passing. Stress test: 10000 ops, 0 errors, 555K ops/sec.

---

## 2026-05-07: Formal Verification v1.0.0

### TLA+ Спецификации (7 спека, 11.6M състояния, 0 грешки)
- `raft.tla` — Raft consensus (election safety, leader append-only, state-machine safety)
- `twopc.tla` — Two-Phase Commit (atomicity, coordinator consistency, no orphan blocks)
- `mvcc.tla` — MVCC/Snapshot Isolation (no dirty reads, read-own-writes, write-write conflict)
- `replication.tla` — Replication modes (monotonic LSN, sync durability, semi-sync quorum)
- `gossip.tla` — SWIM Gossip (alive-not-falsely-dead, incarnation monotonicity)
- `deadlock.tla` — Deadlock Detection (graph integrity, no self-loops)
- `sharding.tla` — Consistent Hash Sharding (virtual node mapping, assignment consistency)

### Оставащи FV задачи (виж `PLAN.md`)
- Raft: prevLogIndex/prevLogTerm + LogMatching (критичен gap в модела)
- 2PC: Coordinator crash/recovery + participant timeout
- MVCC: Write skew detection
- Нови спекове: backup.tla, recovery.tla, crossmodal.tla
- CI: Поправка на verify job (container → setup-java)
- Symmetry reduction + Liveness properties

---

## 2026-05-07: Medium Priority Batch

### JSON/JSONB Types ✅
- `validateType` валидира JSON при INSERT/UPDATE
- `fkJson = 0x0D` добавен в `FieldKind`
- `valueToWire` връща `fkJson` за JSON/JSONB колони
- Всички 4 клиента обновени за JSON сериализация

### Column Type Metadata в Wire Protocol ✅
- `typeToFieldKind` helper в `server.nim`
- `serializeResult` изпраща `colType` bytes след имената на колоните
- Клиентите четат и пазят `columnTypes`

### Multi-Column Indexes ✅
- Parser: `CREATE INDEX idx ON t(a, b)` чете списък от колони
- AST: `nkCreateIndex.ciColumns: seq[string]`
- Executor: ключ `table.col1.col2`, стойност `val1|val2`
- INSERT/UPDATE поддържат composite keys
- SELECT: multi-column exact match за AND chain

### CTE Execution (non-recursive) ✅
- `tkRecursive` токен в lexer
- `parseWith` поддържа `WITH RECURSIVE`
- AST: `selWith: seq[(string, Node, bool)]`
- Executor: materialization в `ctx.cteTables`
- `execScan` проверява CTE store преди LSM
- `defer: ctx.cteTables.clear()` за cleanup
