# BaraDB Architecture

## Overview

BaraDB is a **multimodal database engine** written in Nim that combines document (KV), graph, vector, columnar, and full-text search storage in a single engine with a unified query language called **BaraQL**.

## Layer Architecture

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

Multiple communication protocols:

- **Binary Protocol** (`protocol/wire.nim`): Efficient big-endian binary protocol with 16 message types
- **HTTP/REST** (`core/httpserver.nim`): JSON-based REST API with multi-threading
- **WebSocket** (`core/websocket.nim`): Full-duplex streaming
- **Embedded** (`storage/lsm.nim`): Direct in-process access

### Connection Management

- **Connection Pool** (`protocol/pool.nim`): Min/max connection limits with idle timeout
- **Rate Limiting** (`protocol/ratelimit.nim`): Token-bucket global and per-client limits
- **Authentication** (`protocol/auth.nim`): JWT with HMAC-SHA256 and role-based access
- **TLS/SSL** (`protocol/ssl.nim`): TLS 1.3 with auto-generated certificates

## Layer 2: Query Layer (BaraQL)

The BaraQL pipeline:

1. **Lexer** (`query/lexer.nim`): Tokenizes input into 80+ token types
2. **Parser** (`query/parser.nim`): Recursive descent parser producing AST
3. **AST** (`query/ast.nim`): 300+ lines covering 25+ node kinds
4. **IR** (`query/ir.nim`): Intermediate representation for execution plans
5. **Optimizer** (`query/adaptive.nim`): Adaptive cross-modal query optimization
6. **Codegen** (`query/codegen.nim`): Translates IR to storage operations
7. **Executor** (`query/executor.nim`): Executes plans with parallelization

### Cross-Modal Planning

The optimizer (`query/adaptive.nim`) determines execution order across engines:

```
1. Estimate selectivity for each predicate
2. Push most selective predicate to its engine first
3. Use bloom filters for KV lookups
4. Parallelize independent branches
5. Stream results to avoid materialization
```

## Layer 3: Execution Engine

### Document/KV Engine
- **LSM-Tree** (`storage/lsm.nim`): Write-optimized storage with MemTable, WAL, SSTables
- **B-Tree Index** (`storage/btree.nim`): Ordered index for range scans with COW

### Vector Engine (`vector/`)
- **HNSW Index** (`vector/engine.nim`): Hierarchical Navigable Small World graph
- **IVF-PQ Index** (`vector/engine.nim`): Inverted File Index with Product Quantization
- **SIMD Operations** (`vector/simd.nim`): AVX2-optimized distance computations
- **Quantization** (`vector/quant.nim`): Scalar, product, and binary quantization

### Graph Engine (`graph/`)
- **Adjacency List** (`graph/engine.nim`): Edge-weighted directed graph
- **Algorithms** (`graph/engine.nim`): BFS, DFS, Dijkstra, PageRank
- **Community Detection** (`graph/community.nim`): Louvain algorithm
- **Pattern Matching** (`graph/community.nim`): Subgraph isomorphism
- **Cypher Parser** (`graph/cypher.nim`): Cypher-like graph queries

### Full-Text Search (`fts/`)
- **Inverted Index** (`fts/engine.nim`): Term-document index
- **Ranking** (`fts/engine.nim`): BM25 and TF-IDF scoring
- **Fuzzy Search** (`fts/engine.nim`): Levenshtein distance matching
- **Multi-Language** (`fts/multilang.nim`): Tokenizers for EN, BG, DE, FR, RU

### Columnar Engine (`core/columnar.nim`)
- Per-column storage for analytical queries
- RLE and dictionary encoding
- SIMD-accelerated aggregates

## Layer 4: Storage

- **LSM-Tree** (`storage/lsm.nim`): MemTable, WAL, SSTable, Bloom Filter, Compaction
- **Page Cache** (`storage/compaction.nim`): LRU cache with hit rate tracking
- **Memory-mapped I/O** (`storage/mmap.nim`): mmap-based file access
- **Recovery** (`storage/recovery.nim`): WAL replay and crash recovery

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

## Layer 5: Distributed

- **Raft Consensus** (`core/raft.nim`): Leader election, log replication
- **Sharding** (`core/sharding.nim`): Hash, range, and consistent hashing
- **Replication** (`core/replication.nim`): Sync, async, semi-sync modes
- **Gossip Protocol** (`core/gossip.nim`): SWIM-like membership management
- **Distributed Transactions** (`core/disttxn.nim`): Two-phase commit

## Key Design Decisions

1. **Pure Nim**: No Cython, Python, or Rust dependencies
2. **Unified Storage**: One engine handles KV, graph, vector, FTS, and columnar
3. **Embedded Mode**: Can run as library or server
4. **Binary Protocol**: Custom efficient wire protocol
5. **MVCC**: Multi-version concurrency control
6. **Schema-First**: Strongly typed schema system with inheritance
7. **Cross-Modal**: Single query language across all data models

## Module Statistics

| Category | Modules | Lines of Code | Purpose |
|----------|---------|---------------|---------|
| Core | 16 | ~4,200 | Server, protocols, transactions, distributed |
| Storage | 7 | ~3,100 | LSM, B-Tree, WAL, bloom, compaction, mmap |
| Query | 7 | ~2,800 | Lexer, parser, AST, IR, optimizer, codegen, executor |
| Vector | 3 | ~1,200 | HNSW, IVF-PQ, quantization, SIMD |
| Graph | 3 | ~1,000 | Adjacency list, algorithms, community detection |
| FTS | 2 | ~900 | Inverted index, BM25, fuzzy, multi-language |
| Protocol | 7 | ~2,400 | Wire, HTTP, WebSocket, pool, auth, rate limit, SSL |
| Schema | 1 | ~600 | Types, links, inheritance, migrations |
| Client | 2 | ~800 | Nim binary client, file helpers |
| CLI | 1 | ~400 | Interactive BaraQL shell |
| **Total** | **49** | **~14,100** | |

## Data Flow Diagrams

### Simple Query

```
┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐
│ Client │───→│ Lexer  │───→│ Parser │───→│  IR    │───→│ Codegen│
└────────┘    └────────┘    └────────┘    └────────┘    └───┬────┘
                                                            │
┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐       │
│ Result │←───│ Format │←───│ Execute│←───│ Storage│←──────┘
└────────┘    └────────┘    └────────┘    └────────┘
```

### Cross-Modal Query

```
                    ┌─────────────┐
                    │   Parser    │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   Adaptive  │
                    │   Optimizer │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
    │    Vector   │ │    Graph    │ │     FTS     │
    │    Engine   │ │    Engine   │ │   Engine    │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           └───────────────┼───────────────┘
                           │
                    ┌──────▼──────┐
                    │    Join     │
                    │   & Sort    │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │    Result   │
                    └─────────────┘
```
