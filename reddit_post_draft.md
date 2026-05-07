# r/nim — [Showcase] BaraDB: A database engine written from scratch in Nim

Hey r/nim! I wanted to share a project I've been working on for the past several months.

**BaraDB** is a multimodal database engine written entirely in Nim — no C/C++ dependencies, no PostgreSQL, no external services. Just Nim.

## What is it?

A single-binary (~3.3MB) database that combines:

- **Document/KV storage** — LSM-Tree with WAL, bloom filters, SSTable compaction
- **SQL-compatible query language** — BaraQL with SELECT/INSERT/UPDATE/DELETE, JOINs, GROUP BY, CTEs, indexes
- **Graph engine** — BFS, DFS, Dijkstra, PageRank, Louvain communities
- **Vector search** — HNSW index with SIMD-optimized distance metrics
- **Full-text search** — BM25 + TF-IDF with stemming (EN/BG/DE/RU)
- **Columnar engine** — RLE, dictionary encoding, batch operations
- **Wire protocol** — binary protocol + HTTP/REST + WebSocket + JWT auth
- **4 client SDKs** — Nim, Python, JavaScript, Rust

## Architecture

```
Client Layer     → Binary / HTTP / WebSocket
Query Layer      → Lexer → Parser → AST → IR → Optimizer → Codegen
Execution Engine → Document / Graph / Vector / Columnar / FTS
Storage          → LSM-Tree / B-Tree / WAL / Bloom / mmap
Distributed      → Raft / Sharding / Replication (core logic)
```

## Some numbers

- **~15,000 lines** of Nim
- **269 tests**, all passing
- **Green CI** (GitHub Actions)
- **Benchmarks**: B-Tree point lookup ~1.5M ops/s, LSM-Tree writes ~580K ops/s

## What's actually working vs. what's WIP

**Solid:**
- SQL parser & executor (JOINs, GROUP BY, subqueries, CTEs, indexes)
- MVCC transactions, deadlock detection
- LSM-Tree storage with background compaction
- B-Tree indexes with range scans
- Wire protocol + clients

**In-memory / proof-of-concept:**
- Graph, Vector, FTS, Columnar engines (serialization exists, persistence optional)
- Distributed layer (Raft core logic is there, network transport is stubbed)

**Still rough:**
- Recursive CTE execution
- Some edge-case query optimizations

## Why Nim?

Nim's metaprogramming, zero-cost abstractions, and C-like performance made it perfect for building a storage engine without drowning in C++ complexity. The binary compiles to a single static executable — deployment is just `scp`.

## Repo

[github.com/katehonz/barabaDB](https://github.com/katehonz/barabaDB)

Feedback welcome — especially from anyone who's built storage engines before. I know there's a lot left to do, but I'm proud of how far it's come.
