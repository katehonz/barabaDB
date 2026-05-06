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
- **HTTP/REST** (`protocol/http.nim`): JSON-based REST API
- **WebSocket** (`protocol/websocket.nim`): Full-duplex streaming
- **Embedded** (`storage/lsm.nim`): Direct in-process access

## Layer 2: Query Layer (BaraQL)

The BaraQL pipeline:

1. **Lexer** (`query/lexer.nim`): Tokenizes input into 80+ token types
2. **Parser** (`query/parser.nim`): Recursive descent parser producing AST
3. **AST** (`query/ast.nim`): 300+ lines covering 25+ node kinds
4. **IR** (`query/ir.nim`): Intermediate representation for execution plans
5. **Optimizer/Codegen** (`query/codegen.nim`): Translates IR to storage operations

## Layer 3: Execution Engine

### Document/KV Engine
- **LSM-Tree** (`storage/lsm.nim`): Write-optimized storage
- **B-Tree Index** (`storage/btree.nim`): Ordered index for range scans

### Vector Engine (`vector/`)
- **HNSW Index**: Hierarchical Navigable Small World graph
- **IVF-PQ Index**: Inverted File Index with Product Quantization
- **SIMD Operations**: Unrolled distance computations

### Graph Engine (`graph/`)
- **Adjacency List**: Edge-weighted directed graph
- **Algorithms**: BFS, DFS, Dijkstra, PageRank, Louvain

### Full-Text Search (`fts/`)
- **Inverted Index**: Term-document index
- **Ranking**: BM25 and TF-IDF scoring
- **Multi-Language**: Tokenizers for EN, BG, DE, FR, RU

### Columnar Engine (`core/columnar.nim`)
- Per-column storage for analytical queries
- RLE and dictionary encoding

## Layer 4: Storage

- **LSM-Tree**: MemTable, WAL, SSTable, Bloom Filter, Compaction
- **Page Cache**: LRU cache with hit rate tracking
- **Memory-mapped I/O**: mmap-based file access

## Layer 5: Distributed

- **Raft Consensus**: Leader election, log replication
- **Sharding**: Hash, range, and consistent hashing
- **Replication**: Sync, async, semi-sync modes
- **Gossip Protocol**: Membership management

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

## Key Design Decisions

1. **Pure Nim**: No Cython, Python, or Rust dependencies
2. **Unified Storage**: One engine handles KV, graph, vector, FTS, and columnar
3. **Embedded Mode**: Can run as library or server
4. **Binary Protocol**: Custom efficient wire protocol
5. **MVCC**: Multi-version concurrency control
6. **Schema-First**: Strongly typed schema system with inheritance

## Module Statistics

| Category | Modules |
|----------|---------|
| Core | 10 |
| Storage | 7 |
| Query | 7 |
| Vector | 3 |
| Graph | 3 |
| FTS | 2 |
| Protocol | 7 |
| Distributed | 5 |
| **Total** | **48** |