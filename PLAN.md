# BaraDB — Production Roadmap (Minimalist)

> **Goal:** Get BaraDB to production-ready state without feature creep. Only fix what blocks real usage.

---

## What Works Now (v0.2.0)

**Core:**
- CREATE TABLE / INDEX / VIEW / TRIGGER / USER / POLICY
- SELECT / INSERT / UPDATE / DELETE with WHERE
- Constraints (PK, FK, UNIQUE, NOT NULL, CHECK, DEFAULT)
- B-Tree indexes + query planner
- MVCC transactions (BEGIN / COMMIT / ROLLBACK)
- WAL crash recovery (REDO + UNDO)
- SSTable compaction (manual + background loop)

**Connectivity:**
- TCP wire protocol with typed binary values
- HTTP REST API (query, health, metrics, auth)
- WebSocket real-time (SUBSCRIBE / broadcasts)
- JWT authentication (HTTP + TCP)
- Admin Dashboard (SQL playground, table browser, live events, metrics)

**Advanced:**
- Row-Level Security (policies, GRANT/REVOKE)
- Schema migrations (UP/DOWN, checksums, locking, dry-run)
- UTF-8 identifiers + data
- Nim/Python/Rust/JS client SDKs with full DATA decoding

---

## Phase A: Critical SQL Execution ❌

### A.1 JOIN Execution
- **Why:** Most web apps need `SELECT ... FROM users JOIN orders ON ...`
- **What:** Lower JOIN AST nodes to IR, execute nested-loop join in `executePlan`
- **Cost:** Medium (1 file: executor.nim, ~100 lines)
- **Priority:** P0 — blocks real ORM usage

### A.2 CTE Execution (WITH clause)
- **Why:** Recursive CTEs power tree traversal; non-recursive CTEs simplify queries
- **What:** Execute CTE subqueries first, store results in temp table, reference in main query
- **Cost:** Medium (executor.nim + IR)
- **Priority:** P1 — nice to have, workaround via subqueries exists

---

## Phase B: Production Safety ❌

### B.1 TLS/SSL for TCP + HTTP
- **Why:** Without TLS, credentials and data travel in plaintext
- **What:** Wire BearSSL into TCP socket accept + hunos HTTPS
- **Cost:** Medium (protocol/ssl.nim exists but is mock-only)
- **Priority:** P0 — required for any real deployment

### B.2 Prepared Statements / Parameterized Queries
- **Why:** SQL injection protection + performance (parse once, execute many)
- **What:** Add `PREPARE` / `EXECUTE` / `DEALLOCATE` SQL + wire protocol support
- **Cost:** Medium (parser + executor + wire protocol + all clients)
- **Priority:** P1 — security-critical for web apps

### B.3 Deadlock Detection Wiring
- **Why:** Without it, concurrent transactions can freeze forever
- **What:** Import deadlock module into TxnManager, auto-abort victim transaction
- **Cost:** Low (module exists, just needs integration)
- **Priority:** P1 — one-line import + hook

---

## Phase C: Operational Stability ❌

### C.1 Background Compaction Scheduling
- **Why:** Without periodic compaction, disk usage grows forever, reads slow down
- **What:** Wire the existing `CompactionManager` into the server startup loop
- **Cost:** Low (already implemented, just not started)
- **Priority:** P1 — already partially done in HTTP server startup

### C.2 Connection Limits + Timeouts
- **Why:** Prevent resource exhaustion under load
- **What:** Max connections, query timeout, idle timeout in TCP server
- **Cost:** Low (server.nim + asyncdispatch timeouts)
- **Priority:** P1 — production deployments hit this first

### C.3 Slow Query Log
- **Why:** Essential for debugging performance issues in production
- **What:** Log queries > threshold to file with execution time
- **Cost:** Very low (measure time in executeQuery, append to file if > threshold)
- **Priority:** P2 — debugging aid

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

---

## Honest Assessment

**Current score: 9.2/10** — everything except JOINs, TLS, and deadlock detection is solid.

**Production blockers (must fix before v1.0):**
1. JOIN execution
2. TLS/SSL
3. Deadlock detection wired
4. Prepared statements

**Total estimated work: ~2-3 focused sessions.**

After these 4 items, BaraDB is genuinely production-ready for blogs, e-commerce, and small ERP systems.
