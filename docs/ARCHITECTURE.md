# BaraDB Architecture

## Overview

BaraDB is a **multimodal database engine** written in Nim that combines document (KV), graph, vector, columnar, and full-text search storage in a single engine with a unified query language called **BaraQL**.

The architecture follows a 5-layer design:

```
┌─────────────────────────────────────────────────────────┐
│ 1. CLIENT LAYER                                          │
│    Binary Protocol │ HTTP/REST │ WebSocket │ Embedded    │
├─────────────────────────────────────────────────────────┤
│ 2. QUERY LAYER (BaraQL)                                  │
│    Lexer → Parser → AST → IR → Optimizer → Codegen      │
├─────────────────────────────────────────────────────────┤
│ 3. EXECUTION ENGINE                                      │
│    Document │ Graph │ Vector │ Columnar │ FTS            │
├─────────────────────────────────────────────────────────┤
│ 4. STORAGE                                               │
│    LSM-Tree │ B-Tree │ WAL │ Bloom │ Compaction │ Cache  │
├─────────────────────────────────────────────────────────┤
│ 5. DISTRIBUTED                                           │
│    Raft Consensus │ Sharding │ Replication │ Gossip      │
└─────────────────────────────────────────────────────────┘
```

## Layer 1: Client Layer

The client layer provides multiple ways to communicate with BaraDB:

- **Binary Protocol** (`protocol/wire.nim`): Efficient big-endian binary protocol with 16 message types for high-performance data transfer. Supports query, batch, transaction, and auth messages.
- **HTTP/REST** (`protocol/http.nim`): JSON-based REST API with routing, CORS, and path parameters. Suitable for web applications.
- **WebSocket** (`protocol/websocket.nim`): Full-duplex streaming for real-time data feeds and push notifications.
- **Embedded** (`storage/lsm.nim`): Direct in-process access using the LSM-Tree API, similar to SQLite's embedded mode.

Supporting infrastructure:
- **Connection Pool** (`protocol/pool.nim`): Load-balanced connection management with min/max limits and eviction.
- **Authentication** (`protocol/auth.nim`): JWT-based authentication with token management.
- **Rate Limiting** (`protocol/ratelimit.nim`): Token bucket and sliding window rate limiting.
- **TLS/SSL** (`protocol/ssl.nim`): Encrypted connections with certificate management.

## Layer 2: Query Layer (BaraQL)

The query layer processes BaraQL — a SQL-compatible query language with extensions for graph, vector, and document operations.

### Pipeline

1. **Lexer** (`query/lexer.nim`): Tokenizes input into 80+ token types including keywords, identifiers, operators, and literals. Supports Unicode input and case-insensitive keywords.

2. **Parser** (`query/parser.nim`): Recursive descent parser that produces an Abstract Syntax Tree (AST). Supports:
   - SELECT with WHERE, GROUP BY, HAVING, ORDER BY, LIMIT, OFFSET
   - INSERT, UPDATE, DELETE, SET
   - CREATE TYPE, DROP TYPE, CREATE INDEX
   - JOIN (INNER, LEFT, RIGHT, FULL, CROSS)
   - CTE (WITH ... AS)
   - Subqueries in FROM and WHERE
   - CASE/WHEN expressions
   - Aggregate functions (COUNT, SUM, AVG, MIN, MAX)
   - Dotted path identifiers (table.column)

3. **AST** (`query/ast.nim`): Nodes for all statement types, expressions, clauses, and schema definitions. 300+ lines covering 25+ node kinds.

4. **IR - Intermediate Representation** (`query/ir.nim`): Self-contained representation that abstracts from the query language syntax. Includes:
   - `IRPlan`: Execution plan nodes (Scan, Filter, Project, Join, GroupBy, Sort, Limit, etc.)
   - `IRExpr`: Expression nodes (Literal, Field, Binary, Aggregate, Function, etc.)
   - `TypeChecker`: Expression type inference with context.

5. **Optimizer / Codegen** (`query/codegen.nim`): Translates IR plans to storage operations. Supports:
   - Predicate pushdown: filter conditions moved to storage level
   - Point read optimization: equality filters converted to direct key lookups
   - Cost estimation for plan comparison
   - EXPLAIN output for debugging

6. **Adaptive Query Execution** (`query/adaptive.nim`): Runtime plan adaptation:
   - Cardinality estimation with exponential moving average
   - Automatic reoptimization when estimates are off by >3x
   - Plan caching via hash-based lookup
   - Parallelism hints for execution contexts

## Layer 3: Execution Engine

### Document/KV Engine
- **LSM-Tree** (`storage/lsm.nim`): Write-optimized log-structured merge tree for key-value storage.
- **B-Tree Index** (`storage/btree.nim`): Ordered index for range scans and point queries.

### Vector Engine (`vector/`)
- **HNSW Index** (`engine.nim`): Hierarchical Navigable Small World graph for approximate nearest neighbor search.
- **IVF-PQ Index** (`engine.nim`): Inverted File Index with Product Quantization.
- **Quantization** (`quant.nim`): Scalar 8-bit/4-bit, product, and binary quantization for compression.
- **SIMD Operations** (`simd.nim`): Unrolled loop distance computations (cosine, Euclidean, dot product, Manhattan).
- **Batch Operations**: batchInsert, batchSearch, batchDistance for high-throughput.
- **SQL Integration** (`query/executor.nim`):
  - `VECTOR(n)` column type with dimension validation
  - `CREATE INDEX ... USING hnsw` / `USING ivfpq`
  - Distance functions: `cosine_distance()`, `euclidean_distance()`, `inner_product()`, `l1_distance()`, `l2_distance()`
  - `<->` nearest-neighbor operator
  - Automatic index maintenance on INSERT/UPDATE

### Graph Engine (`graph/`)
- **Adjacency List** (`engine.nim`): Edge-weighted directed graph storage with forward/reverse adjacency.
- **Algorithms**: BFS, DFS, Dijkstra shortest path, PageRank.
- **Community Detection** (`community.nim`): Louvain algorithm with modularity optimization.
- **Pattern Matching** (`community.nim`): Subgraph isomorphism via backtracking search.
- **Cypher Queries** (`cypher.nim`): MATCH/RETURN/WHERE/LIMIT query parser and executor.

### Full-Text Search (`fts/`)
- **Inverted Index** (`engine.nim`): Term-document index with position tracking.
- **Ranking**: BM25 and TF-IDF scoring.
- **Fuzzy Search**: Levenshtein distance up to configurable threshold.
- **Regex Search**: Wildcard pattern matching (*prefix, suffix*, *both*).
- **Multi-Language** (`multilang.nim`): Tokenizers and stemmers for EN, BG, DE, FR, RU with stop word lists and automatic language detection.

### Columnar Engine (`core/columnar.nim`)
- **Columnar Storage**: Per-column data arrays for analytical queries.
- **Encoding**: Run-length encoding (RLE) and dictionary encoding.
- **Aggregates**: sum, avg, min, max, count over columns.
- **GroupBy**: Multi-column grouping with aggregation.

### Cross-Modal Engine (`core/crossmodal.nim`)
- **Unified Query Interface**: Hybrid search across document, vector, graph, and FTS.
- **Weighted Scoring**: Configurable weights for each modality in hybrid queries.
- **2PC Transactions**: Two-phase commit for atomic cross-modal operations.

## Layer 4: Storage

- **LSM-Tree** (`storage/lsm.nim`): Core storage engine with MemTable, immutable table, and SSTable on disk.
- **WAL** (`storage/wal.nim`): Write-Ahead Log for durability. Fixes crash consistency.
- **Bloom Filter** (`storage/bloom.nim`): Probabilistic data structure for fast negative lookups (1% false positive rate).
- **Compaction** (`storage/compaction.nim`): Size-tiered strategy with level management.
- **Page Cache** (`storage/compaction.nim`): LRU cache with hit rate tracking.
- **Memory-mapped I/O** (`storage/mmap.nim`): mmap-based file access with madvise hints.
- **Crash Recovery** (`storage/recovery.nim`): WAL replay for REDO/UNDO on startup.

## Layer 5: Distributed

- **Raft Consensus** (`core/raft.nim`): Leader election, log replication, RequestVote, AppendEntries.
- **Election Timer** (`core/raft.nim`): Configurable timeout-based leader election loop.
- **Sharding** (`core/sharding.nim`): Hash-based, range-based, and consistent hashing.
- **Cluster Membership** (`core/sharding.nim`): Auto-rebalance on node join/leave/fail.
- **Replication** (`core/replication.nim`): Sync, async, and semi-sync replication modes.
- **Gossip Protocol** (`core/gossip.nim`): Membership management with alive/suspect/dead states.
- **Distributed Transactions** (`core/disttxn.nim`): Two-phase commit across nodes with saga pattern.
- **Transaction Manager** (`core/mvcc.nim`): Multi-Version Concurrency Control with snapshot isolation.
- **Deadlock Detection** (`core/deadlock.nim`): Wait-for graph cycle detection.

## Data Flow

### Write Path
```
Client → Protocol → Auth → Parser → AST → IR → Codegen
  → StorageOp → MVCC Txn → WAL Write → MemTable → Commit
```

### Read Path
```
Client → Protocol → Auth → Parser → AST → IR → Codegen
  → StorageOp → MVCC Snapshot → MemTable → SSTable → Result
```

### Vector Search Path
```
Client → Query "SIMILAR vec TO [...]" → Parser → Codegen
  → HNSW Index → Distance Computation → Top-K → Result
```

### Graph Path
```
Client → Query "MATCH (n)-[r]->(m) RETURN n" → Cypher Parser
  → Graph Engine → BFS/DFS/Dijkstra → Result
```

## Key Design Decisions

1. **Pure Nim**: No Cython, Python, or Rust dependencies. Single compiler (nim) builds everything.
2. **Unified Storage**: One engine handles KV, graph, vector, FTS, and columnar — no separate services.
3. **Embedded Mode**: Can run as a library (like SQLite) or as a server (like PostgreSQL).
4. **Binary Protocol**: Custom efficient protocol instead of text-based SQL at wire level.
5. **Copy-on-Write MVCC**: Multi-version concurrency control for non-blocking reads without explicit locks.
6. **Schema-First Design**: Strongly typed schema system with inheritance, computed properties, and automatic migrations.

## Module Count

| Category | Modules | Lines (est.) |
|----------|---------|--------------|
| Core | 10 | ~2500 |
| Storage | 7 | ~1500 |
| Query | 7 | ~2500 |
| Vector | 3 | ~1000 |
| Graph | 3 | ~1000 |
| FTS | 2 | ~800 |
| Protocol | 7 | ~1500 |
| Schema | 1 | ~400 |
| Client | 2 | ~500 |
| CLI | 1 | ~200 |
| Distributed | 5 | ~1500 |
| **Total** | **48** | **~14,000** |
