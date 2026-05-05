# BaraDB

**A multimodal database engine written in Nim — 100% native, zero dependencies.**

BaraDB combines document, graph, vector, columnar, and full-text search storage
in a single engine with a unified query language (BaraQL). It compiles to a
single 286KB binary with no runtime dependencies.

## Why BaraDB?

| Feature | GEL/EdgeDB | BaraDB |
|---|---|---|
| Core language | Python + Cython + Rust | **100% Nim** |
| Storage backend | PostgreSQL only | **Native multi-engine** |
| Vector search | pgvector extension | **Built-in HNSW/IVF-PQ** |
| Graph algorithms | None | **BFS, DFS, Dijkstra, PageRank, Louvain** |
| Full-text search | PG FTS extension | **Built-in BM25 + TF-IDF** |
| Embedded mode | No | **Yes (SQLite-like)** |
| Binary size | ~50MB+ | **286KB** |
| Dependencies | PostgreSQL, Python, many libs | **Zero** |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    CLIENT LAYER                          │
│  Binary Protocol │ HTTP/REST │ WebSocket │ Embedded      │
├─────────────────────────────────────────────────────────┤
│                 QUERY LAYER (BaraQL)                     │
│  Lexer → Parser → AST → IR → Optimizer → Codegen        │
├─────────────────────────────────────────────────────────┤
│                EXECUTION ENGINE                          │
│  Document │ Graph │ Vector │ Columnar │ FTS              │
├─────────────────────────────────────────────────────────┤
│                    STORAGE                               │
│  LSM-Tree │ B-Tree │ WAL │ Bloom Filter │ mmap           │
├─────────────────────────────────────────────────────────┤
│                DISTRIBUTED                               │
│  Raft Consensus │ Sharding │ Replication                 │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build
nim c -d:release -o:build/baradadb src/baradadb.nim

# Run tests
nim c --path:src -r tests/test_all.nim

# Run benchmarks
nim c -d:release -r benchmarks/bench_all.nim

# Start server
./build/baradadb
```

## BaraQL — Query Language

BaraQL is SQL-compatible with extensions for graph, vector, and document queries.

### Basic Queries

```sql
-- SELECT with WHERE, ORDER BY, LIMIT
SELECT name, age FROM users WHERE age > 18 ORDER BY name LIMIT 10;

-- INSERT
INSERT users { name := 'Alice', age := 30 };

-- UPDATE
UPDATE users SET age = 31 WHERE name = 'Alice';

-- DELETE
DELETE FROM users WHERE name = 'Alice';
```

### Aggregates and Grouping

```sql
-- GROUP BY with HAVING
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;

-- Aggregates: count, sum, avg, min, max
SELECT count(*), sum(amount), avg(price) FROM orders;
```

### JOINs

```sql
-- INNER JOIN
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;

-- LEFT JOIN
SELECT u.name, o.total
FROM users u
LEFT JOIN orders o ON u.id = o.user_id;

-- Multiple JOINs
SELECT *
FROM orders o
JOIN users u ON o.user_id = u.id
JOIN products p ON o.product_id = p.id;
```

### CTEs (Common Table Expressions)

```sql
-- Single CTE
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;

-- Multiple CTEs
WITH
  recent AS (SELECT * FROM orders WHERE date > '2025-01-01'),
  totals AS (SELECT user_id, sum(amount) as total FROM recent GROUP BY user_id)
SELECT u.name, t.total FROM users u JOIN totals t ON u.id = t.user_id;
```

### Subqueries

```sql
-- Subquery in FROM
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- EXISTS subquery
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);
```

### CASE Expressions

```sql
SELECT name,
  CASE
    WHEN age < 18 THEN 'minor'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;
```

### Schema Definition

```sql
-- Create type with properties and links
CREATE TYPE Person {
  name: str,
  age: int32
};

CREATE TYPE Movie {
  title: str,
  director: Person
};
```

## Storage Engines

### LSM-Tree (Key-Value)

The primary storage engine with write-optimized append-only log structure.

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
let (found, value) = db.get("key1")
db.close()
```

Components:
- **MemTable** — in-memory sorted buffer
- **WAL** — write-ahead log for durability
- **SSTable** — sorted string tables on disk
- **Bloom Filter** — probabilistic set membership
- **Compaction** — size-tiered strategy with level management
- **Page Cache** — LRU cache with hit rate tracking

### B-Tree Index

Ordered index for range scans and point lookups.

```nim
import barabadb/storage/btree

var btree = newBTreeIndex[string, string]()
btree.insert("key1", "value1")
let values = btree.get("key1")
let range = btree.scan("key_a", "key_z")
```

### Vector Engine

Native HNSW and IVF-PQ indexes for similarity search.

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)
let results = idx.search(queryVector, k = 10)

# With metadata filtering
let filtered = idx.searchWithFilter(queryVector, k = 10,
  filter = proc(meta: Table[string, string]): bool =
    return meta.getOrDefault("category") == "A")
```

Features:
- **HNSW** — hierarchical navigable small world graph
- **IVF-PQ** — inverted file index with product quantization
- **Distance metrics** — cosine, euclidean, dot product, Manhattan
- **Quantization** — scalar 8-bit/4-bit, product, binary
- **Metadata filtering** — filter results by key-value pairs

### Graph Engine

Adjacency list storage with built-in algorithms.

```nim
import barabadb/graph/engine

var g = newGraph()
let alice = g.addNode("Person", {"name": "Alice"}.toTable)
let bob = g.addNode("Person", {"name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

# Traversal
let bfs = g.bfs(alice)
let dfs = g.dfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()
```

Algorithms:
- **BFS/DFS** — breadth-first and depth-first traversal
- **Dijkstra** — shortest weighted path
- **PageRank** — node importance ranking
- **Louvain** — community detection
- **Pattern matching** — subgraph isomorphism search

### Full-Text Search

Inverted index with BM25 and TF-IDF ranking.

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

# BM25 search
let results = idx.search("programming language")

# TF-IDF search
let tfidf = idx.searchTfidf("programming language")

# Fuzzy search (typo tolerance)
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)

# Wildcard search
let wild = idx.regexSearch("prog*")
```

### Columnar Engine

Column-oriented storage for analytical queries.

```nim
import barabadb/core/columnar

var batch = newColumnBatch()
var ageCol = batch.addInt64Col("age")
var nameCol = batch.addStringCol("name")
ageCol.appendInt64(25)
nameCol.appendString("Alice")

# Aggregates
echo ageCol.sumInt64()
echo ageCol.avgInt64()

# Encoding
let rle = rleEncode(@[1'i64, 1, 1, 2, 2, 3])
let dict = dictEncode(@["apple", "banana", "apple"])
```

## Transactions

MVCC with snapshot isolation and deadlock detection.

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# Savepoint
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)  # undo key3

discard tm.commit(txn)
```

## Protocol

### Binary Wire Protocol

16 message types with big-endian serialization.

```nim
import barabadb/protocol/wire

let msg = makeQueryMessage(1, "SELECT * FROM users")
let ready = makeReadyMessage(1)
let error = makeErrorMessage(1, 42, "Syntax error")
```

### HTTP/REST API

```nim
import barabadb/protocol/http

var router = newHttpRouter(port = 8080)
router.get("/api/users", proc(req: Request): Future[JsonNode] {.async.} =
  return %*[{"id": 1, "name": "Alice"}])
```

### WebSocket Streaming

```nim
import barabadb/protocol/websocket

var server = newWsServer(port = 8081)
server.onMessage = proc(ws: WebSocket, data: seq[byte]) {.gcsafe.} =
  echo "Received: ", cast[string](data)
asyncCheck server.run()
```

### Authentication

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
let token = am.createToken(JWTClaims(sub: "user1", role: "admin"))
let result = am.validateCredentials(AuthCredentials(authMethod: amToken, payload: token))
```

### Rate Limiting

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(rlaTokenBucket, globalRate = 1000, perClientRate = 100)
if rl.allowRequest("client-123"):
  echo "Request allowed"
```

## Schema System

```nim
import barabadb/schema/schema

var s = newSchema()

let person = newType("Person")
person.addProperty("name", "str", required = true)
person.addProperty("age", "int32")
s.addType("default", person)

# Inheritance
let employee = newType("Employee")
employee.setBases(@["Person"])
employee.addProperty("department", "str")
s.addType("default", employee)

# Resolve inheritance — Employee gets name, age, department
let resolved = s.resolveInheritance(employee)

# Diff schemas
let diff = s.diff(oldSchema, newSchema)
```

## Distributed

### Raft Consensus

```nim
import barabadb/core/raft

var cluster = newRaftCluster()
cluster.addNode("node1")
cluster.addNode("node2")
cluster.addNode("node3")

let n1 = cluster.nodes["n1"]
n1.becomeCandidate()
n1.becomeLeader()
let entry = n1.appendLog("SET key1 value1")
```

### Sharding

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(numShards: 4, replicas: 2, strategy: ssHash))
router.rebalance(@["node1", "node2", "node3"])
let shard = router.getShard("user_123")
```

### Replication

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 5432))
rm.connectReplica("r1")
let lsn = rm.writeLsn(@[1'u8, 2, 3])
rm.ackLsn("r1", lsn)  # blocks until acked
```

## User Defined Functions

```nim
import barabadb/query/udf

var reg = newUDFRegistry()
reg.registerStdlib()  # abs, sqrt, pow, lower, upper, len, trim, substr, toString, toInt

# Custom function
reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## Project Structure

```
src/barabadb/
├── core/
│   ├── types.nim         # Type system (17 types)
│   ├── config.nim        # Configuration
│   ├── server.nim        # Async TCP server
│   ├── mvcc.nim          # Multi-version concurrency control
│   ├── deadlock.nim      # Deadlock detection
│   ├── raft.nim          # Raft consensus
│   ├── sharding.nim      # Hash/range/consistent sharding
│   ├── replication.nim   # Sync/async/semi-sync replication
│   └── columnar.nim      # Columnar storage + encoding
├── storage/
│   ├── lsm.nim           # LSM-Tree storage engine
│   ├── btree.nim         # B-Tree index
│   ├── wal.nim           # Write-ahead log
│   ├── bloom.nim         # Bloom filter
│   ├── compaction.nim    # SSTable compaction + page cache
│   └── mmap.nim          # Memory-mapped I/O
├── query/
│   ├── lexer.nim         # Tokenizer (80+ tokens)
│   ├── parser.nim        # Recursive descent parser
│   ├── ast.nim           # Abstract syntax tree
│   ├── ir.nim            # Intermediate representation
│   ├── codegen.nim       # IR → storage operations
│   └── udf.nim           # User defined functions
├── vector/
│   ├── engine.nim        # HNSW + IVF-PQ indexes
│   ├── quant.nim         # Scalar/product/binary quantization
│   └── simd.nim          # SIMD-optimized distance ops
├── graph/
│   ├── engine.nim        # Adjacency list + algorithms
│   └── community.nim     # Louvain + pattern matching
├── fts/
│   └── engine.nim        # Inverted index + BM25 + fuzzy
├── protocol/
│   ├── wire.nim          # Binary wire protocol
│   ├── http.nim          # HTTP/REST router
│   ├── websocket.nim     # WebSocket streaming
│   ├── pool.nim          # Connection pool
│   ├── auth.nim          # JWT authentication
│   └── ratelimit.nim     # Rate limiting
├── schema/
│   └── schema.nim        # Types, links, inheritance, migrations
└── cli/
    └── shell.nim         # Interactive query shell
```

## Tests

```bash
# Run all tests (162 tests, 35 suites)
nim c --path:src -r tests/test_all.nim

# Run benchmarks
nim c -d:release -r benchmarks/bench_all.nim
```

## Roadmap Progress

| Phase | Status | Progress |
|-------|--------|----------|
| Core (LSM + B-Tree + compaction + cache + mmap) | ✅ | 95% |
| BaraQL (GROUP BY + JOIN + CTE + aggregates + codegen + UDF) | ✅ | 100% |
| Multimodal storage (KV + graph + vector + columnar) | 🟡 | 75% |
| Transactions (MVCC + deadlock + WAL + savepoints) | ✅ | 85% |
| Protocol (binary + HTTP + WS + pool + auth + ratelimit) | ✅ | 85% |
| Schema (inheritance + computed + migrations) | ✅ | 95% |
| Vector engine (HNSW + IVF-PQ + quant + SIMD + metadata) | ✅ | 95% |
| Graph engine (all algorithms + pattern matching) | ✅ | 90% |
| FTS (BM25 + TF-IDF + fuzzy + regex) | ✅ | 85% |
| CLI shell | 🟡 | 50% |
| Cluster (Raft + sharding + replication) | ✅ | 60% |
| Optimizations (SIMD + mmap done) | 🟡 | 40% |

## License

Apache 2.0
