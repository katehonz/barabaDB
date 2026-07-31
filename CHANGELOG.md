# Changelog

All notable changes to BaraDB are documented in this file.

## [1.3.0] — 2026-07-30

### Raft cluster — Supported (single `default` DB scope)

Raft 3-node moves from **Experimental** to **Supported** for the covered scope; single-node remains Production GA. Spec/plan: `docs/superpowers/specs/2026-07-30-raft-supported-design.md`, `docs/superpowers/plans/2026-07-30-v1.3.0-raft-supported.md`.

- **Failover under load proven** — `tests/raft_failover_load_e2e_test.nim`: sustained INSERT load, leader killed at ≥ 50 acked writes; every **acknowledged** write survives on both survivors. Client contract: in-flight writes during failover fail fast with an error — clients must retry ([distributed.md](docs/en/distributed.md))
- **Mandatory CI gate** — dedicated `raft-e2e` GitHub Actions job runs all five raft e2e suites; a missing server binary is a hard FAIL under CI (no silent skip)
- **Raft-port TLS** — `BARADB_RAFT_TLS_ENABLED` + `BARADB_RAFT_TLS_CERT_FILE` / `BARADB_RAFT_TLS_KEY_FILE` / `BARADB_RAFT_TLS_CA_FILE` / `BARADB_RAFT_TLS_VERIFY_PEER`; fail-closed startup when cert/key is missing; optional mutual auth; follower→leader SQL forwarding is TLS-wrapped when the client port is. E2E `tests/raft_tls_e2e_test.nim` (full-TLS cluster works; plaintext node excluded)
- **InstallSnapshot cold-node recovery** — backward-compatible wire protocol (`RaftProtoVersion` stays 1); the leader streams a `tar.gz` snapshot of the default DB in chunks of `BARADB_RAFT_SNAP_CHUNK_KB` KiB (default 256) to peers whose lag is unrecoverable; the follower restores via the backup/restore path and resumes from the snapshot base. Leader compaction unpins from peers stale beyond `BARADB_RAFT_PEER_STALE_MS` (default 30000). E2E `tests/raft_coldnode_e2e_test.nim` (returning node and wiped node converge automatically)

### Fixes

- **Raft put/delete encoding** — `ExecResult.keyValuePairs` carries an explicit `deleted` flag; an INSERT into a PK-only table (empty value) is no longer encoded as a `delete` and erased on apply; regression tests in `tests/bugfix_test.nim`
- **Rejoin livelock** — on leadership acquisition the leader drops cached peer sockets; half-dead sockets to a restarted peer previously never errored, so no redial ever happened and the cluster livelocked without heartbeats
- **Post-restore ctx repoint** — after an InstallSnapshot restore, the TCP serving ctx/db is repointed at the reopened database (queries previously read the closed pre-restore LSM and served 0 rows). Remaining limitation for startup-captured HTTP ctx: see [known-limitations](docs/en/known-limitations.md)
- **Intermediate InstallSnapshot chunk replies ignored** — the leader acts only on the final chunk reply

### Release

- `baradadb.nimble` → `1.3.0`; `/health` and startup version strings updated
- Docs: [distributed](docs/en/distributed.md) (failover contract, raft TLS setup, snapshot tunables), [known-limitations](docs/en/known-limitations.md) (raft supported scope + two newly documented limitations), [release-checklist](docs/en/release-checklist.md)

---

## [1.2.0] — 2026-07-30

### Production GA (single-node)

- **Scope** — single-node production tier; Raft multi-node documented as experimental ([known-limitations](docs/en/known-limitations.md))
- **Prod compose** — `docker-compose.prod.yml` requires `BARADB_JWT_SECRET` and enables auth; `BARADB_ENV=production` fails closed without secret
- **Backup drill** — `scripts/backup-restore-drill.sh` (backup → wipe → restore → verify)
- **Runbook** — start/stop/backup/restore in [deployment](docs/en/deployment.md)
- **Release checklist** — [docs/en/release-checklist.md](docs/en/release-checklist.md)

### Raft cluster (C3a / C3b / ops)

Production-ready path from config → election → SQL/DDL replication → ops.

- **C3a — Networked bootstrap** — `BARADB_RAFT_PEERS=id@host:port`, election timer in production, heartbeat timer reset on AppendEntries, `raft_state.bin` persistence, partial-read-safe frames; E2E `tests/raft_e2e_test.nim` (3-node election + failover)
- **C3b — SQL writes through Raft** — leader appends DML KV pairs and waits for majority commit; followers reject or **forward** via `BARADB_RAFT_CLIENT_PEERS`; apply path updates LSM + B-tree/FTS/HNSW + graphs; multi-statement write gate; writes only on `default` database
- **DDL replication** — schema DDL (`CREATE`/`DROP`/`ALTER` table, index, view, graph, …) as `ddl` log entries; re-executed on apply; `CREATE`/`DROP DATABASE` excluded
- **Leader write forwarding** — followers proxy DML/DDL to the leader SQL port when client peers are configured
- **Safe log compaction** — soft cap `BARADB_RAFT_LOG_MAX_ENTRIES` (default 256); leader never discards past peer `matchIndex`; snapshot base (`lastSnapshotIndex`/`Term`) persisted
- **Secondary-index point lookup fix** — index scans use `entry.lsmKey` (not the filter column as PK)
- **Metrics** — Prometheus raft series on `GET /metrics` (HTTP = TCP port + 440); `GET /health` includes `raft` role/term/leader/lag/log size
- **E2E writes** — `tests/raft_writes_e2e_test.nim` (schema, forward, index SELECT, failover)
- **Docs** — `docs/en|bg/distributed.md`, `docs/superpowers/specs/2026-07-30-raft-cluster-status.md`

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
