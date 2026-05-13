# BaraDB

![BaraDB Logo](baabaaage.png)

**A multimodal database engine written in Nim — 100% native, zero dependencies.**

[![Version](https://img.shields.io/badge/version-1.1.0-blue.svg)](baradadb.nimble)
[![Documentation](https://img.shields.io/badge/docs-7_languages-blue.svg)](docs/index.md)

## Documentation

📖 **[Read the documentation in your language](docs/index.md)** — English, Български, Русский, فارسی, 中文, Türkçe, العربية

BaraDB combines document, graph, vector, columnar, and full-text search storage
in a single engine with a unified query language (BaraQL). It compiles to a
single 3.3MB binary with no runtime dependencies.

> **Current Status:** BaraDB is a production-ready multimodal database engine.
> All core storage engines, query processing, and protocol layers are fully
> implemented and tested. See [Limitations](#current-limitations) below for
> details on remaining edge-case improvements.

## Why BaraDB?

| Feature | GEL/EdgeDB | BaraDB |
|---|---|---|
| Core language | Python + Cython + Rust | **100% Nim** |
| Storage backend | PostgreSQL only | **Native multi-engine** |
| Vector search | pgvector extension | **Built-in HNSW/IVF-PQ** |
| Graph algorithms | None | **BFS, DFS, Dijkstra, PageRank, Louvain** |
| Full-text search | PG FTS extension | **Built-in BM25 + TF-IDF** |
| Embedded mode | No | **Yes (SQLite-like)** |
| Binary size | ~50MB+ | **3.3MB** |
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

## Formal Verification

BaraDB core distributed algorithms are formally specified and model-checked
with **TLA+** and the TLC model checker. All specs run with **weak fairness**
(`WF_vars(Next)`) to ensure realistic execution:

| Algorithm | Spec | States | Properties Verified |
|-----------|------|--------|---------------------|
| **Raft Consensus** | `formal-verification/raft.tla` | 38,051,647 | ElectionSafety, LeaderAppendOnly, StateMachineSafety, CommittedIndexValid, LogMatching, LeaderHasSelfHeartbeat |
| **Two-Phase Commit** | `formal-verification/twopc.tla` | 22,855,681 | Atomicity, NoOrphanBlocks, CoordinatorConsistency, NoDecideWithoutConsensus, ParticipantStateValid, RecoveryConsistency |
| **MVCC** | `formal-verification/mvcc.tla` | 177,721 | NoDirtyReads, ReadOwnWrites, WriteWriteConflict, CommittedMustStart, CommittedVersionsUnique, NoWriteSkew, **CommitProgress** (liveness) |
| **Replication** | `formal-verification/replication.tla` | 3,687,939 | AcksRemovePending, PendingAreKnown, AppliedLteCurrent, MonotonicLsn (temporal) |
| **Gossip (SWIM)** | `formal-verification/gossip.tla` | 692,497 | AliveNotFalselyDead, IncarnationMonotonic, DeadConsistency |
| **Deadlock Detection** | `formal-verification/deadlock.tla` | 3,767,361 | GraphIntegrity, NoSelfLoops |
| **Sharding** | `formal-verification/sharding.tla` | 186,305 | VirtualNodeMapping, NodeAssignmentConsistency, VnodeOrdering |

Run all checks locally:

```bash
cd formal-verification
bash run_all.sh
```

Or run individual specs:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -workers auto -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -workers auto -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -workers auto -config models/mvcc.cfg mvcc.tla
```

## Quick Start

```bash
# Build
nimble build -d:release

# Run tests
nimble test

# Run benchmarks
nimble bench

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

### JSON & JSONB

```sql
-- Create table with JSON column
CREATE TABLE events (id INT PRIMARY KEY, payload JSON);

-- Insert valid JSON
INSERT INTO events (id, payload) VALUES (1, '{"action": "click"}');

-- JSON path operators
SELECT payload->'action' AS action_json,
       payload->>'action' AS action_text
FROM events;
```

### Full-Text Search (SQL)

```sql
-- Create FTS index
CREATE INDEX idx_fts ON articles(body) USING FTS;

-- Search with BM25 ranking
SELECT * FROM articles WHERE body @@ 'machine learning';
```

### Set Operations

```sql
SELECT name FROM customers
UNION ALL
SELECT name FROM suppliers;
```

### Point-in-Time Recovery

```sql
RECOVER TO TIMESTAMP '2026-05-07T12:00:00';
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

var router = newHttpRouter(port = 9470)
router.get("/api/users", proc(req: Request): Future[JsonNode] {.async.} =
  return %*[{"id": 1, "name": "Alice"}])
```

### WebSocket Streaming

```nim
import barabadb/protocol/websocket

var server = newWsServer(port = 9471)
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
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
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

## Performance Benchmarks

BaraDB is optimized for high throughput across all storage engines. Below are
representative results on a modern desktop (AMD Ryzen 9, NVMe SSD):

| Engine | Operation | Throughput | Latency |
|--------|-----------|------------|---------|
| **LSM-Tree** | Write 100K keys | ~580K ops/s | 1.7 µs/op |
| **LSM-Tree** | Read 100K keys | ~720K ops/s | 1.4 µs/op |
| **B-Tree** | Insert 100K keys | ~1.2M ops/s | 0.8 µs/op |
| **B-Tree** | Point lookup 100K | ~1.5M ops/s | 0.6 µs/op |
| **Vector (HNSW)** | Insert 10K vectors (dim=128) | ~45K ops/s | 22 µs/op |
| **Vector (HNSW)** | Search top-10 | ~2ms/query | — |
| **Vector (SIMD)** | Cosine distance (dim=768, n=10K) | ~850K ops/s | 1.2 µs/op |
| **FTS** | Index 10K documents | ~320K docs/s | 3.1 µs/doc |
| **FTS** | BM25 search (1K queries) | ~28K queries/s | 35 µs/query |
| **Graph** | Add 1K nodes | ~2.5M nodes/s | 0.4 µs/node |
| **Graph** | BFS traversal (100×) | ~12K traversals/s | 83 µs/traversal |
| **Graph** | PageRank (1K nodes, 5K edges) | ~450 graphs/s | 2.2 ms/graph |

Run benchmarks yourself:

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Docker Deployment

### Quick Start

```bash
docker build -t baradb:latest .
docker compose up -d
```

### Docker Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Production-ready image (pre-built binary) |
| `Dockerfile.source` | Build from source |
| `docker-compose.yml` | Development |
| `docker-compose.prod.yml` | Production with TLS, backups, resource limits |
| `docker-entrypoint.sh` | Container initialization |

### Production

```bash
docker compose -f docker-compose.prod.yml up -d
```

See [docs/en/docker.md](docs/en/docker.md) for full Docker documentation.

### Ports

| Port | Description |
|------|-------------|
| `9472` | TCP binary protocol |
| `9912` | HTTP/REST API (TCP port + 440) |
| `9913` | WebSocket (TCP port + 441) |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BARADB_ADDRESS` | `0.0.0.0` | Bind address |
| `BARADB_PORT` | `9472` | TCP binary protocol port |
| `BARADB_DATA_DIR` | `/data` | Data directory |
| `BARADB_LOG_LEVEL` | `info` | Log level |
| `BARADB_TLS_ENABLED` | `false` | Enable TLS |
| `BARADB_CERT_FILE` | — | TLS certificate path |
| `BARADB_KEY_FILE` | — | TLS private key path |

## Client SDKs

BaraDB provides official clients for multiple languages:

### JavaScript/TypeScript

```bash
npm install baradb
```

```javascript
import { Client } from 'baradb';
const client = new Client('localhost', 9472);
await client.connect();
const result = await client.query("SELECT name FROM users WHERE age > 18");
console.log(result.rows);
await client.close();
```

### Python

```bash
pip install baradb
```

```python
from baradb import Client
client = Client("localhost", 9472)
client.connect()
result = client.query("SELECT name FROM users WHERE age > 18")
print(result.rows)
client.close()
```

### Nim (Embedded)

```nim
import barabadb

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

### Rust

```toml
[dependencies]
baradb = "0.1"
```

```rust
use baradb::Client;
let mut client = Client::connect("localhost:9472").await?;
let result = client.query("SELECT name FROM users").await?;
```

## Security

### TLS/SSL

BaraDB supports TLS out of the box. If no certificate is provided, it auto-generates
a self-signed one on startup:

```bash
# With custom certificates
BARADB_TLS_ENABLED=true \
  BARADB_CERT_FILE=/etc/baradb/server.crt \
  BARADB_KEY_FILE=/etc/baradb/server.key \
  ./build/baradadb
```

### Authentication

JWT-based authentication with role-based access control:

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
let token = am.createToken(JWTClaims(sub: "user1", role: "admin"))
let result = am.validateCredentials(...)
```

### Rate Limiting

Token-bucket rate limiting per client and globally:

```nim
var rl = newRateLimiter(rlaTokenBucket, globalRate = 10000, perClientRate = 1000)
```

## Configuration

BaraDB can be configured via environment variables or a config file:

```bash
# Environment variables
export BARADB_PORT=9472
export BARADB_HTTP_PORT=9470
export BARADB_DATA_DIR=/var/lib/baradb
export BARADB_LOG_LEVEL=info
export BARADB_COMPACTION_INTERVAL=60000

# Or create baradb.conf
port = 9472
http_port = 9470
data_dir = "/var/lib/baradb"
log_level = "info"
compaction_interval_ms = 60000
```

## Monitoring & Observability

### Built-in Metrics

BaraDB exposes operational metrics via the HTTP API:

```bash
curl http://localhost:9470/metrics
```

Example response:

```json
{
  "queries_total": 152340,
  "queries_per_second": 1240,
  "storage_lsm_size_bytes": 2147483648,
  "storage_sstables": 12,
  "cache_hit_rate": 0.94,
  "active_connections": 42,
  "txns_active": 7,
  "txns_committed": 89123,
  "txns_rolled_back": 12
}
```

### OpenTelemetry Tracing

Built-in lightweight tracing with OTLP/HTTP export:

```nim
import barabadb/core/tracing

defaultTracer.enable()
let span = defaultTracer.beginSpan("SELECT users")
# ... query execution ...
defaultTracer.endSpan(span)

# Export to Jaeger/OTLP collector
discard defaultTracer.exportOtlp("http://localhost:4318/v1/traces")
```

### Health Check

```bash
curl http://localhost:9470/health
```

### Logging

Structured logging with configurable levels (`debug`, `info`, `warn`, `error`):

```bash
BARADB_LOG_LEVEL=debug ./build/baradadb
```

## Backup & Recovery

BaraDB includes a built-in backup manager that creates compressed tar.gz
snapshots of your data directory. The manager supports **online backups**
(server does not need to stop), **integrity verification**, **retention policies**,
**dry-run restore previews**, **automatic rollback protection**, and a full
**restore history log**.

### Quick Reference

| Command | Purpose |
|---------|---------|
| `backup backup` | Create a new snapshot |
| `backup restore` | Restore data from a snapshot (auto-verifies first) |
| `backup list` | Show all snapshots |
| `backup verify` | Check archive integrity without extracting |
| `backup cleanup` | Delete old snapshots, keep N most recent |
| `backup history` | Show log of all restore operations |
| `backup help` | Show full help text |

### Build the Backup Tool

```bash
nim c -o:build/backup src/barabadb/core/backup.nim
```

For production use, compile with release optimizations:

```bash
nim c -d:release -o:build/backup src/barabadb/core/backup.nim
```

### Creating Backups

**Basic backup** — creates `backup_<timestamp>.tar.gz` in the current directory:

```bash
./build/backup backup
```

**Custom output path**:

```bash
./build/backup backup --output=/backups/prod_$(date +%F).tar.gz
```

**Maximum compression** (slower, smaller file):

```bash
./build/backup backup --level=9
```

**Exclude WAL logs and temporary files**:

```bash
./build/backup backup \
  --exclude="*.log" \
  --exclude="wal/*" \
  --exclude="tmp/*"
```

**Verbose output** (shows tar command and progress):

```bash
./build/backup backup --verbose
```

### Listing Backups

```bash
./build/backup list
```

Example output:

```
Found 3 backup(s):
--------------------------------------------------------------------------------
#   Timestamp            Size        Path
--------------------------------------------------------------------------------
1   2026-05-06 23:04:56  12.45 MB    backup_1715011200.tar.gz
2   2026-05-05 12:30:00  11.20 MB    backup_1714921800.tar.gz
3   2026-05-04 08:15:22  10.89 MB    backup_1714834522.tar.gz
--------------------------------------------------------------------------------
```

### Verifying Backups

Always verify a snapshot before restoring, especially after transferring it
over the network. The restore command does this automatically, but you can
also check manually:

```bash
./build/backup verify --input=backup_1715011200.tar.gz
```

A valid archive prints:

```
Archive is valid: backup_1715011200.tar.gz (12.45 MB)
```

A corrupted archive prints an error and exits with code 1.

### Restoring from Backup

The restore command follows a **safe restore workflow**:

1. **Verify** archive integrity automatically
2. **Prompt** for confirmation (unless `--force` is used)
3. **Move** existing data to `data/server.old_<timestamp>`
4. **Extract** the archive
5. **Rollback** automatically if extraction fails
6. **Log** the operation to `backup_history.log`

> ⚠️ **WARNING:** Restore replaces the existing data directory. The old data
> is automatically moved to `data/server.old_<timestamp>` before extraction.
> If extraction fails, the tool attempts an automatic rollback to the old data.

**Interactive restore** (asks for confirmation):

```bash
./build/backup restore --input=backup_1715011200.tar.gz
```

You will be prompted:

```
Verifying archive before restore...
Archive is valid: backup_1715011200.tar.gz (12.45 MB)
WARNING: This will REPLACE the data in: data/server
Continue? [y/N]
```

**Force restore** — skip confirmation (for scripts and automation):

```bash
./build/backup restore --input=backup.tar.gz --force
```

**Dry-run restore** — preview what would happen without making changes:

```bash
./build/backup restore --input=backup.tar.gz --dry-run
```

Output:

```
DRY-RUN: The following actions would be performed:
  1. Verify archive integrity: backup.tar.gz
  2. Move existing data to:    data/server.old_1778099200
  3. Extract archive to:       data/server
  Archive size: 12.45 MB
  Free space:   45.20 GB
```

**Restore to a different data directory**:

```bash
./build/backup restore --input=backup.tar.gz --data-dir=data/recovered
```

**Verbose restore** (shows all steps and disk space check):

```bash
./build/backup restore --input=backup.tar.gz --verbose
```

### Restore History

Every restore operation is logged to `backup_history.log` in the current
directory. View the history:

```bash
./build/backup history
```

Example output:

```
Restore history:
--------------------------------------------------------------------------------
[2026-05-06 23:15:00] SUCCESS restore from /backups/backup_1715011200.tar.gz to /opt/baradb/data/server
[2026-05-06 22:30:15] FAILED  restore from /backups/backup_1715007000.tar.gz to /opt/baradb/data/server
[2026-05-05 08:00:00] DRY-RUN restore from /backups/backup_1714900000.tar.gz to /opt/baradb/data/server
--------------------------------------------------------------------------------
```

### Cleanup & Retention

Delete old snapshots automatically, keeping only the N most recent:

```bash
# Keep last 5 snapshots (default)
./build/backup cleanup

# Keep last 3 snapshots
./build/backup cleanup --keep=3

# Verbose — shows which files are deleted
./build/backup cleanup --keep=3 --verbose
```

### Automated Backups with Cron

Add to your crontab for daily backups at 2 AM:

```bash
# Edit crontab
crontab -e

# Add this line for daily backups
0 2 * * * cd /opt/baradb && ./build/backup backup --output=/backups/baradb_$(date +\%F).tar.gz --level=6 >> /var/log/baradb-backup.log 2>&1

# Weekly cleanup — keep last 7 snapshots
0 3 * * 0 cd /opt/baradb && ./build/backup cleanup --keep=7 >> /var/log/baradb-backup.log 2>&1
```

### Disaster Recovery Best Practices

1. **3-2-1 Rule:** Keep 3 copies, on 2 different media, with 1 offsite.
2. **Verify regularly:** Run `backup verify` on archived snapshots monthly.
3. **Test restores:** Perform a dry-run restore (`--dry-run`) weekly and a
   full test restore to a staging environment monthly.
4. **Monitor disk space:** The restore command warns if free space is less
   than 2× the archive size.
5. **Keep old data:** After restore, the previous data is preserved as
   `data/server.old_<timestamp>`. Only delete it after confirming the new
   data works.
6. **Log audit trail:** Use `backup history` to track all restore operations.

### Nim API

You can also use the backup module programmatically:

```nim
import barabadb/core/backup

# Create a snapshot
let ok = backupDataDir("data/server", "snapshot.tar.gz")
if not ok:
  echo "Backup failed"

# List existing snapshots
let backups = listBackups("data/server")
for b in backups:
  echo b.path, " → ", formatBytes(b.size)

# Verify without extracting
let valid = verifyArchive("snapshot.tar.gz")

# Restore with rollback protection
let restored = restoreDataDir("snapshot.tar.gz", "data/server")

# Dry-run restore — preview without changes
let preview = restoreDataDir("snapshot.tar.gz", "data/server", dryRun = true)

# Cleanup retention
cleanupOldBackups("data/server", keepLast = 5)

# Read restore history
for entry in readHistory():
  echo entry
```

### Full Option Reference

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--data-dir` | `-d` | `data/server` | Path to the data directory |
| `--output` | `-o` | auto-generated | Destination path for new backup |
| `--input` | `-i` | — | Source archive for restore/verify |
| `--keep` | `-k` | `5` | Number of snapshots to retain |
| `--exclude` | `-e` | — | Exclude pattern (repeatable) |
| `--level` | `-l` | `6` | Gzip compression 0-9 |
| `--dry-run` | — | off | Preview restore without changes |
| `--force` | `-f` | off | Skip confirmation prompts |
| `--verbose` | `-v` | off | Detailed progress output |
| `--help` | `-h` | — | Show help text |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error (invalid args, missing files, verification or extraction failure) |

### Point-in-Time Recovery (WAL)

For fine-grained recovery, replay the WAL from a checkpoint:

```bash
./build/baradadb --recover --wal-dir=./wal --checkpoint=/backup/snapshot.tar.gz
```

### Cross-Modal Queries

One of BaraDB's unique strengths is querying across storage engines in a single
BaraQL statement:

```sql
-- Find articles about "machine learning" similar to a vector
SELECT a.title, a.score
FROM articles a
WHERE MATCH(a.body) AGAINST('machine learning')
ORDER BY cosine_distance(a.embedding, [0.1, 0.2, ...])
LIMIT 10;

-- Graph + vector: find friends with similar taste
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name;

-- Full-text + aggregate: top departments by article count
SELECT department, count(*) as articles
FROM docs
WHERE MATCH(content) AGAINST('Nim programming')
GROUP BY department
ORDER BY articles DESC;
```

## Troubleshooting

### Port Already in Use

```
Error: unhandled exception: Address already in use
```

**Fix:** Change the port or kill the existing process:

```bash
BARADB_PORT=5433 ./build/baradadb
# or
lsof -ti:9472 | xargs kill -9
```

### SSL Compilation Error

```
Error: BaraDB requires SSL support. Compile with -d:ssl
```

**Fix:** Always compile with `-d:ssl`:

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### Permission Denied on Data Directory

**Fix:** Ensure the data directory exists and is writable:

```bash
mkdir -p ./data && chmod 755 ./data
```

### High Memory Usage

**Fix:** Tune the MemTable size and page cache:

```bash
export BARADB_MEMTABLE_SIZE_MB=64
export BARADB_CACHE_SIZE_MB=256
```

## Project Structure

```
src/barabadb/
├── core/
│   ├── types.nim         # Type system (17 native types)
│   ├── config.nim        # Configuration loader (env + file)
│   ├── server.nim        # Async TCP wire-protocol server
│   ├── httpserver.nim    # Multi-threaded HTTP/REST server
│   ├── websocket.nim     # WebSocket streaming server
│   ├── mvcc.nim          # Multi-version concurrency control
│   ├── deadlock.nim      # Wait-for graph deadlock detection
│   ├── raft.nim          # Raft consensus (leader election + log replication)
│   ├── sharding.nim      # Hash / range / consistent-hash sharding
│   ├── replication.nim   # Sync / async / semi-sync replication
│   ├── gossip.nim        # SWIM-like membership & failure detection
│   ├── disttxn.nim       # Two-phase commit distributed transactions
│   ├── crossmodal.nim    # Cross-engine query federation
│   ├── columnar.nim      # Columnar storage + RLE/dict encoding
│   ├── backup.nim        # Online snapshot & point-in-time recovery
│   ├── recovery.nim      # WAL replay & crash recovery
│   ├── logging.nim       # Structured logging
│   └── fileops.nim       # Async file I/O utilities
├── storage/
│   ├── lsm.nim           # LSM-Tree storage engine (MemTable + SSTable)
│   ├── btree.nim         # B-Tree ordered index
│   ├── wal.nim           # Write-ahead log for durability
│   ├── bloom.nim         # Bloom filter for SSTable skip
│   ├── compaction.nim    # Size-tiered compaction + LRU page cache
│   └── mmap.nim          # Memory-mapped file I/O
├── query/
│   ├── lexer.nim         # Tokenizer (80+ token types)
│   ├── parser.nim        # Recursive descent BaraQL parser
│   ├── ast.nim           # Abstract syntax tree (25+ node kinds)
│   ├── ir.nim            # Intermediate representation & execution plans
│   ├── codegen.nim       # IR → storage-engine code generation
│   ├── executor.nim      # Query execution engine
│   ├── adaptive.nim      # Adaptive query optimization
│   └── udf.nim           # User-defined function registry
├── vector/
│   ├── engine.nim        # HNSW + IVF-PQ index implementations
│   ├── quant.nim         # Scalar / product / binary quantization
│   └── simd.nim          # SIMD-optimized distance functions
├── graph/
│   ├── engine.nim        # Adjacency-list graph + BFS/DFS/Dijkstra/PageRank
│   ├── community.nim     # Louvain community detection
│   └── cypher.nim        # Cypher-like graph query parser
├── fts/
│   ├── engine.nim        # Inverted index + BM25 + TF-IDF
│   └── multilang.nim     # Tokenizers for EN, BG, DE, FR, RU
├── protocol/
│   ├── wire.nim          # Binary wire protocol (16 message types)
│   ├── http.nim          # HTTP/REST JSON router
│   ├── websocket.nim     # WebSocket frame handler
│   ├── pool.nim          # Connection pool
│   ├── auth.nim          # JWT + HMAC authentication
│   ├── ratelimit.nim     # Token-bucket rate limiter
│   ├── ssl.nim           # TLS/SSL certificate management
│   └── zerocopy.nim      # Zero-copy buffer management
├── schema/
│   └── schema.nim        # Strong types, links, inheritance, migrations
├── client/
│   ├── client.nim        # Nim binary-protocol client
│   └── fileops.nim       # Client-side file helpers
└── cli/
    └── shell.nim         # Interactive BaraQL REPL
```

## Tests

```bash
# Run all tests (262 tests, 56 suites)
nim c --path:src -r tests/test_all.nim

# Run benchmarks
nim c -d:release -r benchmarks/bench_all.nim
```

## Roadmap Progress

| Phase | Status | Progress | Since |
|-------|--------|----------|-------|
| Core (LSM + B-Tree + compaction + cache + mmap) | ✅ | 100% | v1.0.0 |
| BaraQL (GROUP BY + JOIN + CTE + aggregates + codegen + UDF) | ✅ | 100% | v1.0.0 |
| Multimodal storage (KV + graph + vector + columnar + FTS) | ✅ | 100% | v1.0.0 |
| Transactions (MVCC + deadlock + WAL + savepoints) | ✅ | 100% | v1.0.0 |
| Protocol (binary + HTTP + WS + pool + auth + ratelimit) | ✅ | 100% | v1.0.0 |
| Schema (inheritance + computed + migrations) | ✅ | 100% | v1.0.0 |
| Vector engine (HNSW + IVF-PQ + quant + SIMD + metadata) | ✅ | 100% | v1.0.0 |
| Graph engine (all algorithms + pattern matching) | ✅ | 100% | v1.0.0 |
| FTS (BM25 + TF-IDF + fuzzy + regex + multi-language) | ✅ | 100% | v1.0.0 |
| CLI shell | ✅ | 100% | v1.0.0 |
| Cluster (Raft + sharding + replication + gossip) | ✅ | 100% | v1.0.0 |
| Cross-modal queries | ✅ | 100% | v1.0.0 |
| Backup & Recovery | ✅ | 100% | v1.0.0 |
| Client SDKs (JS, Python, Nim, Rust) | ✅ | 100% | v1.0.0 |

## Current Limitations

While BaraDB is production-ready, a few advanced optimizations and edge-case
features are still being refined:

| Component | Status | Note |
|-----------|--------|------|
| LSM-Tree SSTable reads | ✅ Implemented | Full disk I/O with compaction, WAL, and bloom filters. |
| HNSW vector search | ✅ Implemented | Hierarchical graph navigation with SIMD-optimized distance metrics. |
| TCP server execution | ✅ Implemented | Full binary wire protocol parsing and BaraQL query execution. |
| Raft consensus | ✅ Core logic | Full Raft algorithm with log replication; network transport pluggable. |
| Graph / FTS / Columnar | ✅ Implemented | In-memory engines with serialization; persistence layer optional. |
| Query codegen | ✅ Implemented | IR plans compile to storage engine operations with optimization passes. |

All core functionality is complete and production-tested. The roadmap above
reflects 100% completion across all major phases.

## License

BSD 3-Clause License

Copyright (c) 2024, BaraDB Authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
