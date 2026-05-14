# Changelog

All notable changes to BaraDB are documented in this file.

## [1.1.0] — 2026-05-13

### Added

- **Client SDKs v1.1.0** — Full-featured clients for all languages:
  - JavaScript: TypeScript definitions, package.json, examples, unit & integration tests
  - Python: Restructured as proper package (`baradb/` with `__init__.py` and `core.py`), pyproject.toml, examples, tests (query builder, wire protocol, integration)
  - Nim: Examples, integration tests, README
  - Rust: Examples, integration tests, improved Cargo.toml
- **SCRAM-SHA-256 Authentication** — RFC 7677 compliant authentication with PBKDF2 + HMAC + SHA-256 + nonce/salt generation
- **HTTP SCRAM Endpoints** — `/auth/scram/start` + `/auth/scram/finish` in HTTP server
- **Docker Compose Test Configuration** — `docker-compose.test.yml` for test environments
- **CI/CD Clients Pipeline** — `.github/workflows/clients-ci.yml` for automated client testing

### Fixed

- **Query Executor** — Unary minus (`irNeg`) evaluation now works correctly in SELECT and WHERE clauses
- **Distributed Transactions** — Rollback after commit attempt no longer violates atomicity
- **Sharding** — Data migration protocol with TCP + `scanAll` on LSM
- **Raft** — Majority calculation for even number of nodes fixed
- **MVCC** — Aborted transactions no longer become visible
- **LSM-Tree** — Data loss on immutable memtable overwrite fixed; SSTable lookup sorting fixed
- **Auth** — JWT signature changed to HMAC-SHA256 (no longer trivially forgeable); token expiration (`exp`/`nbf`/`iat`) now validated; signature comparison is now constant-time
- **Recovery** — `summary()` no longer mutates the database
- **Wire Protocol** — 64MB limit + bounds checking + max depth to prevent OOM/DoS
- **SQL Injection** — `exprToSql` now escapes single quotes
- **ReDoS** — `irLike`/`irILike` now escape regex metacharacters
- **Graph** — `addEdge` now checks node existence
- **Vector** — Dimension mismatch validation + HNSW locking
- **FTS** — UTF-8 tokenization now uses runes instead of bytes
- **Build** — `nim.cfg` adds `-d:ssl` so `nimble build` works without flags; `--threads:on` added to all CI commands

### Changed

- **Version bumped to 1.1.0** across all components (server, Docker images, clients, CLI)
- **README** — Version badge updated; all feature tables now reference v1.1.0
- **TLA+ Formal Verification** — Added `crossmodal.tla`, `backup.tla`, `recovery.tla`; symmetry reduction in all 9 specs
- **Clean build** — 0 compiler warnings on Nim 2.2.10

## [0.1.0] — 2025-01-15

### Added

- **Core Storage Engines**
  - LSM-Tree with MemTable, WAL, SSTables, and size-tiered compaction
  - B-Tree ordered index with range scans and MVCC copy-on-write
  - Bloom filters for efficient SSTable skip
  - Memory-mapped I/O for SSTable reads
  - LRU page cache with hit rate tracking

- **Query Engine (BaraQL)**
  - SQL-compatible lexer with 80+ token types
  - Recursive descent parser producing AST with 25+ node kinds
  - Intermediate representation (IR) for execution plans
  - Code generator translating IR to storage operations
  - Adaptive query optimizer with cross-modal planning
  - Query executor with parallelization

- **BaraQL Language Features**
  - SELECT, INSERT, UPDATE, DELETE
  - WHERE, ORDER BY, LIMIT, OFFSET
  - GROUP BY, HAVING, aggregate functions (count, sum, avg, min, max)
  - INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN
  - CTEs (Common Table Expressions) with WITH
  - Subqueries (EXISTS, IN, correlated)
  - CASE expressions
  - UNION, INTERSECT, EXCEPT
  - Schema definition: CREATE TYPE, DROP TYPE

- **Vector Engine**
  - HNSW index for approximate nearest neighbor search
  - IVF-PQ index for large-scale vector search
  - SIMD-optimized distance functions (cosine, L2, dot product, Manhattan)
  - Quantization: scalar 8-bit/4-bit, product quantization, binary
  - Metadata filtering during vector search

- **Graph Engine**
  - Adjacency list storage for directed, edge-weighted graphs
  - BFS and DFS traversal
  - Dijkstra shortest path
  - PageRank node importance
  - Louvain community detection
  - Subgraph pattern matching
  - Cypher-like graph query parser

- **Full-Text Search**
  - Inverted index with term-document mapping
  - BM25 ranking algorithm
  - TF-IDF scoring
  - Fuzzy search with Levenshtein distance
  - Wildcard/regex search
  - Multi-language tokenizers (English, Bulgarian, German, French, Russian)

- **Columnar Storage**
  - Per-column storage for analytical queries
  - RLE (Run-Length Encoding) compression
  - Dictionary encoding for low-cardinality columns
  - SIMD-accelerated aggregates

- **Transactions**
  - MVCC (Multi-Version Concurrency Control) with snapshot isolation
  - Deadlock detection via wait-for graph
  - Write-ahead log for durability
  - Savepoints and partial rollback

- **Protocol Layer**
  - Binary wire protocol with 16 message types
  - HTTP/REST JSON API
  - WebSocket streaming
  - Connection pooling
  - JWT-based authentication
  - Token-bucket rate limiting
  - TLS/SSL with auto-generated certificates

- **Schema System**
  - Strong type system with 17 native types
  - Type inheritance with multi-base support
  - Property links between types
  - Schema diffing and migrations
  - Computed properties

- **Distributed Systems**
  - Raft consensus (leader election, log replication)
  - Hash, range, and consistent-hash sharding
  - Sync/async/semi-sync replication
  - Gossip protocol for membership management
  - Two-phase commit for distributed transactions

- **Cross-Modal Queries**
  - Unified query language across all storage engines
  - Cross-engine predicate pushdown
  - Optimized execution plans for multi-modal queries

- **Backup & Recovery**
  - Online snapshots without downtime
  - Point-in-time recovery via WAL replay
  - Incremental backups

- **Client SDKs**
  - JavaScript/TypeScript client with binary protocol
  - Python client with sync and async APIs
  - Nim embedded mode and client library
  - Rust client (async)

- **Operations**
  - Interactive CLI shell (BaraQL REPL)
  - Structured logging (JSON and text formats)
  - Prometheus-compatible metrics endpoint
  - Health and readiness probes
  - CPU/memory profiling endpoints

- **Docker Support**
  - Multi-stage Dockerfile (Alpine Linux)
  - Docker Compose configuration
  - Health checks

### Performance

- LSM-Tree: 580K writes/s, 720K reads/s
- B-Tree: 1.2M inserts/s, 1.5M lookups/s
- Vector SIMD: 850K cosine distances/s (dim=768)
- FTS: 320K docs/s indexing, 28K queries/s BM25
- Graph: 2.5M nodes/s insertion, 12K BFS traversals/s
- Binary protocol: 380K queries/s (100 concurrent connections)

### Tests

- 262 tests across 56 test suites
- 100% pass rate

## [Unreleased]

### Added

- **JavaScript Client — TCP Request Queue** — Internal `_requestQueue` + `_requestLock` for safe concurrent queries. Multiple parallel `query()` / `execute()` / `ping()` calls no longer interleave binary frames on the wire.

### Fixed

- **Wire Protocol — Big-Endian Float Serialization** — `FLOAT32`/`FLOAT64` and vector float values are now serialized in big-endian byte order, matching the client's `readFloatBE()` / `readDoubleBE()` and ensuring cross-platform numeric accuracy.
- **Gossip Protocol — Async UDP Socket** — Replaced synchronous `newSocket` + blocking `recvFrom` with `newAsyncSocket` + `await recvFrom`, preventing the async event loop from freezing until a UDP packet arrives.

### Planned

- Query plan caching
- Materialized views
- Geospatial index
- Time-series optimizations
- CDC (Change Data Capture) streaming
- Federated queries across BaraDB instances
