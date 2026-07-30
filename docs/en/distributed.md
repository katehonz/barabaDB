# Distributed Systems

BaraDB supports distributed deployment with Raft consensus, sharding, and replication.

> ⚠️ **Multi-Database Limitation**
> The distributed modules (Raft, sharding, and replication) are currently wired to the **`default`** database only. If you use multiple databases (`CREATE DATABASE`, `USE DATABASE`), distributed features do not yet span across them. Each database would need its own cluster setup.

> **Status (2026-07-30):** Raft C3a (network election), C3b (SQL writes), DDL replication, leader forwarding, log compaction, and metrics are **shipped on `main`**. Design/history: `docs/superpowers/specs/2026-07-30-raft-cluster-status.md`.

## Raft Consensus

Leader election and log replication over TCP; SQL DML/DDL on the default DB go through the raft log. Enable with:

| Env | Meaning |
|-----|---------|
| `BARADB_RAFT_ENABLED=true` | Turn on Raft |
| `BARADB_RAFT_NODE_ID` | This node's id |
| `BARADB_RAFT_PORT` | Raft TCP port |
| `BARADB_RAFT_PEERS` | Comma-separated `id@host:port` (include self) |
| `BARADB_RAFT_WRITE_TIMEOUT_MS` | Max wait for majority commit on SQL writes (default 5000) |
| `BARADB_RAFT_CLIENT_PEERS` | Optional `id@host:clientPort` map for leader write forwarding |
| `BARADB_RAFT_LOG_MAX_ENTRIES` | Soft cap on in-memory raft log length (default 256); safe prefix compact |

When Raft is enabled, SQL DML (`INSERT`/`UPDATE`/`DELETE`/`MERGE` and transactional `COMMIT`) and schema DDL (`CREATE`/`DROP`/`ALTER` table, index, view, graph, …) are accepted only on the leader of the **`default`** database. DML ships as put/delete log entries; DDL ships as a `ddl` entry with the original SQL and is re-executed on every node at apply. Followers that receive a write/DDL **forward** it to the leader when `BARADB_RAFT_CLIENT_PEERS` maps the leader id to a SQL client address; otherwise they return `not leader; leader is '…'`. Writes against any other database name are rejected (`raft writes only supported on the 'default' database`). `CREATE`/`DROP DATABASE` are not raft-replicated (multi-DB is out of scope for v1). Committed DML also updates secondary B-tree/FTS/HNSW indexes and in-memory graphs.

**Log compaction (v1):** after apply, each node may drop a fully-safe log prefix once `log.len` exceeds `BARADB_RAFT_LOG_MAX_ENTRIES`. The leader never discards past any peer's `matchIndex` (so lagging followers still catch up via AppendEntries). Snapshot metadata (`lastSnapshotIndex`/`Term`) is persisted in `raft_state.bin`; full InstallSnapshot state-machine payloads are not required while this safe-prefix policy holds.

**Metrics:** with raft enabled, `GET /metrics` (HTTP port = `BARADB_PORT + 440`) includes Prometheus lines such as `baradb_raft_is_leader`, `baradb_raft_term`, `baradb_raft_log_entries`, `baradb_raft_apply_lag`, `baradb_raft_commit_wait_ms_total`, `baradb_raft_elections_total`, `baradb_raft_forwards_total`, and `baradb_raft_compactions_total`. `GET /health` embeds a `raft` object (`role`, `term`, `leader_id`, `commit_index`, `apply_lag`, …).

### Minimal 3-node example

```bash
# Shared peers (raft ports) and client peers (SQL ports)
export BARADB_RAFT_ENABLED=true
export BARADB_RAFT_PEERS=n1@127.0.0.1:46101,n2@127.0.0.1:46102,n3@127.0.0.1:46103
export BARADB_RAFT_CLIENT_PEERS=n1@127.0.0.1:46010,n2@127.0.0.1:46020,n3@127.0.0.1:46030

# Terminal 1
BARADB_PORT=46010 BARADB_RAFT_PORT=46101 BARADB_RAFT_NODE_ID=n1 \
  BARADB_DATA_DIR=./data/n1 ./build/baradadb

# Terminal 2 / 3 — n2@46020/46102, n3@46030/46103 similarly

# After a leader appears (check logs for "became leader"):
# curl http://127.0.0.1:46450/health   # n1 HTTP = 46010+440
```

### In-process API (tests / embedding)

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

### E2E tests

| Test | What it proves |
|------|----------------|
| `tests/raft_e2e_test.nim` | 3 real processes; election + kill-leader failover |
| `tests/raft_writes_e2e_test.nim` | DDL/DML via raft, follower forward, index SELECT, failover writes |

## Sharding

Distribute data across nodes:

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(
  numShards: 4,
  replicas: 2,
  strategy: ssHash
))
router.rebalance(@["node1", "node2", "node3"])
let shard = router.getShard("user_123")
```

### Sharding Strategies

| Strategy | Description |
|----------|-------------|
| `ssHash` | Hash-based sharding |
| `ssRange` | Range-based sharding |
| `ssConsistent` | Consistent hashing |

## Replication

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
rm.connectReplica("r1")
let lsn = rm.writeLsn(@[1'u8, 2, 3])
rm.ackLsn("r1", lsn)
```

### Replication Modes

| Mode | Description |
|------|-------------|
| `rmSync` | Synchronous replication |
| `rmAsync` | Asynchronous replication |
| `rmSemiSync` | Semi-synchronous replication |

## Gossip Protocol

Membership and failure detection:

```nim
import barabadb/core/gossip

var g = newGossipManager()
g.addNode("node1")
g.addNode("node2")
g.tick()  # Exchange membership info
```

## Distributed Transactions

Two-phase commit across nodes:

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## Formal Verification

Core distributed algorithms are formally specified in TLA+ and model-checked:

- **Raft Consensus** — `formal-verification/raft.tla`
  - Verified: ElectionSafety, StateMachineSafety
- **Two-Phase Commit** — `formal-verification/twopc.tla`
  - Verified: Atomicity, NoOrphanBlocks
- **Replication** — `formal-verification/replication.tla`
  - Verified: MonotonicLsn, AcksRemovePending

Run TLC locally:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -config models/replication.cfg replication.tla
```