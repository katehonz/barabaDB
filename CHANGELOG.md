# Changelog

All notable changes to BaraDB are documented in this file.

## [1.2.0] — Unreleased

### Core Storage Hardening

Foundational LSM improvements for write performance, durability, and compaction correctness.

- **Hash-table MemTable** (`storage/lsm.nim`) — O(1) put/get instead of O(n) sorted-seq insert; sort only on flush to SSTable
- **Timestamp-aware MemTable overwrite** — WAL recovery keeps newest version per key
- **WAL rewrite after flush** (`storage/wal.nim`) — `truncate` / `rewriteLive` so recovery is O(unflushed) not O(history); fsync on truncate/rewrite/close
- **WAL group commit** — `WalSyncMode`: `none` | `group` (default) | `every`; fsync every N entries and/or every interval ms
- **Config knobs** — `wal_sync_mode`, `wal_group_every`, `wal_sync_interval_ms` / env `BARADB_WAL_*`; registry opens DBs with config
- **L0 file-count compaction trigger** — RocksDB-style `L0CompactionTrigger` (default 4) instead of size-only for overlapping L0
- **`rebuildFromLSM` for compaction** (`storage/compaction.nim`) — strategy always syncs from live SSTable catalog (no drift after flush)
- **Safe mmap close after compaction** — release handles for compacted inputs after unlink
- **Recovery flag** — flush during WAL replay does not rewrite the open WAL file mid-read
- **Fair WAL micro-bench** — `benchWalDurabilityModes` compares none/group/every on the same workload
- **RwLock for LSM** (`storage/rwlock.nim`) — writer-preferring reader-writer lock; default API uses exclusive mode
- **Deep-copy on get** — returned values are copied so callers never share seq buffers with the store
- **`-d:baraConcurrentReads`** — opt-in shared read locks (unsafe with default ORC across OS threads)
- **`scanRange(start, end)`** — inclusive multi-level range scan (memtable + SSTables)
- **Focused tests** — `tests/test_storage_hardening.nim` (RwLock, WAL group, scanRange, stress)
- **Note:** Nim ORC must not share GC'd `LSMTree` refs across OS threads without isolation
- **StorageGate** (`storage/gate.nim`) — global exclusive lock serializing HTTP (Hunos workers), TCP, compaction, Raft apply
- **HTTP stop no longer closes shared registry** — ownership stays with main; `stop(closeStorage=true)` for standalone HTTP
- **Schema persistence** — stable keys `_schema:tables:<name>`; restore from full LSM (`scanAll`), not only memtable; DROP/ALTER update durable catalog; secondary index rebuild on open
- **Schema tests** — `tests/test_schema_persist.nim` (create/flush/reopen, drop, alter, multi-table)
- **Executor split** — `query/exec/{types,values,schema}.nim`; `executor.nim` re-exports for API stability; see `query/exec/README.md`
- **Fair benchmarks** — `benchmarks/fair_bench.py` multi-tier (embedded SQLite↔LSM; client-server HTTP/wire↔PG); batch multi-row INSERT; wire protocol via Python client; `generate_report.py --fair`; `nimble bench_fair`
- **Fix wire INSERT SIGSEGV** — ORC cycle collector crash under async TCP load; switch default MM to `--mm:arc` in `nim.cfg`; regression `tests/test_wire_insert_stress.nim`
- **Honest bench docs** — tier warnings in `bench_all`, `pg_bench`, `compare.nim`; `benchmarks/README.md`
- **Regression suite** — `Core Storage Hardening` tests in `tests/test_all.nim`

### Search Module (new)

A unified search module combining vector similarity, full-text, and structured
search into a single high-performance engine.

- **Heap-optimized HNSW search** — priority-queue-based candidate selection, 2.4x faster than baseline (`search/hnsw_opt.nim`)
- **Segment-based inverted indexing** — partitioned posting lists for concurrent indexing and reduced lock contention (`search/inverted.nim`)
- **Phrase and proximity search** — ordered phrase matching with configurable slop distance (`search/phrase.nim`)
- **Boolean query parser** — full boolean algebra with AND, OR, NOT, and range expressions (e.g. `price:[10 TO 100]`) (`search/boolean.nim`)
- **N-gram fuzzy search** — character n-gram index for typo-tolerant retrieval (`search/ngram.nim`)
- **Faceted search** — filter results and aggregate counts by arbitrary field values (`search/facet.nim`)
- **Porter2 stemmers** — morphological stemming for English, Bulgarian, German, French, and Russian (`search/stemmer.nim`)
- **UnifiedSearchEngine API** — single entry point combining all search modes with consistent scoring (`search/engine.nim`)
- **Search benchmarks** — reproducible performance measurement suite (`benchmarks/bench_search.nim`)

---

## [1.1.7] — 2026-05-29

### Security (5 critical + 5 high)

- **Fix REP/DISTTXN protocol auth bypass** (`server.nim`) — unauthenticated TCP clients could write data or manipulate distributed transactions
- **Fix HTTP backup/restore path traversal** (`httpserver.nim`) — `..` and absolute paths rejected
- **Fix empty JWT secret when auth enabled** (`server.nim`) — server now refuses to start with `authEnabled: true` and no `jwtSecret`
- **Fix HTTP admin panel served without auth** (`httpserver.nim`) — admin UI now requires authentication when `authEnabled`
- **Fix timing attacks on HMAC/SCRAM comparison** (`auth.nim`, `scram.nim`) — constant-time comparison
- **Fix WebSocket JWT expiration not validated** (`websocket.nim`) — `exp` claim now checked
- **Fix sync replication returning success on partial ack** (`replication.nim`) — returns 0 when not all replicas acknowledge
- **Fix SSL verifyPeer not applied** (`ssl.nim`) — `verifyMode` now passed to `newContext()`
- **Fix JWT JSON parser missing escape handling** (`auth.nim`) — backslash escapes now parsed correctly

### Data Integrity (3 critical + 3 high + 2 medium)

- **Fix WAL write race with flush** (`lsm.nim`) — WAL write now under `db.lock`, preventing data loss after crash
- **Fix 2PC marking uncontacted participants as prepared/committed** (`disttxn.nim`) — only contacted nodes are marked
- **Fix Raft commit index for even-sized clusters** (`raft.nim`) — correct majority calculation
- **Fix MVCC savepoint/rollback no-op** (`mvcc.nim`) — deep copy writeSet at savepoint time
- **Fix table mutation during iteration** (`mvcc.nim`) — collect stale txns before deleting
- **Fix B-tree leaf merge phantom separator key** (`btree.nim`) — no longer inserts empty-valued separator at leaf level
- **Fix writeSSTable partial file on crash** (`lsm.nim`) — write to `.tmp` then atomic rename
- **Fix compaction mmap leak** (`compaction.nim`) — close SSTables after reading

### Query Correctness (1 high + 2 medium)

- **Fix LIMIT 0 returning all rows** (`executor.nim`) — now returns empty result
- **Fix COUNT(col) counting NULL values** (`executor.nim`) — 3 locations fixed to check `v.kind != vkNull`
- **Fix EXISTS subquery always false** (`executor.nim`) — lowering now sets `existsSubquery` plan
- **Fix multi-CTE queries losing earlier CTE tables** (`executor.nim`) — save/restore `cteTables` around inner execution
- **Fix JSON injection in hybrid_search_filtered** (`executor.nim`) — escape quotes/backslashes in ID

### Raft Consensus (3 high + 1 low)

- **Fix Raft appendEntries using array index instead of log-index** (`raft.nim`) — uses `findLogEntryByIndex`
- **Fix Raft applyCommitted using logical index as array position** (`raft.nim`) — uses `findLogEntryByIndex`
- **Fix Raft loadState silently swallowing errors** (`raft.nim`) — now logs warning

### Storage Engine (2 medium)

- **Fix loadSSTable missing minimum file-size check** (`lsm.nim`) — rejects files < 40 bytes
- **Fix substr(s, start) returning single char** (`udf.nim`) — now returns rest-of-string

### Distributed Systems (2 high + 1 medium)

- **Fix sharding connectWithTimeout missing SO_ERROR check** (`sharding.nim`) — verifies connection actually succeeded
- **Fix replication healthCheck double-close socket** (`replication.nim`) — safe close with try/except

### Resource Management (3 medium)

- **Fix unbounded plan cache** (`adaptive.nim`) — max 10000 entries, auto-evict
- **Fix MVCC unbounded committedTxns/abortedTxns** (`mvcc.nim`) — prune entries older than oldest active snapshot
- **Fix connection pool not checking maxLifetime** (`pool.nim`) — lifetime check added to `acquire`

### Operations (1 medium)

- **Fix migration lock persisting after crash** (`executor.nim`) — stores timestamp, auto-releases after 1 hour

### Other

- **Fix nl_to_sql DML validation** (`executor.nim`) — requires `is_superuser` session variable for DML
- **Fix lexer readIdent double column counting** (`lexer.nim`) — removed manual `inc l.col`
- **Fix WebSocket frame 32-bit overflow** (`websocket.nim`) — guard against `len > high(int)`
- **Fix admin panel auth** (`httpserver.nim`) — check auth when `authEnabled`
- **Fix unused imports** (`backup.nim`, `repair.nim`, `raft.nim`) — moved `parseopt` into `when isMainModule`, removed unused `algorithm`

### Build

- **Fix hunos 1.3.1 compatibility with Nim 2.2.x** — patched `getRandomBytes` → `urandom` in `hunos/sessions.nim` and `hunos/csrf.nim` (see `HUNOS_ISSUE.md`)
- Updated `baradadb.nimble` version to `1.1.7`

### Tests

- All 448 tests passing, 0 failures

---

## [1.1.6] — previous

See git log for changes prior to this release.
