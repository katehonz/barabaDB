# Distributed Systems

BaraDB supports distributed deployment with Raft consensus, sharding, and replication.

> ⚠️ **Multi-Database Limitation**
> The distributed modules (Raft, sharding, and replication) are currently wired to the **`default`** database only. If you use multiple databases (`CREATE DATABASE`, `USE DATABASE`), distributed features do not yet span across them. Each database would need its own cluster setup.

> **Status (2026-07-30, v1.3.0):** Raft C3a/C3b + DDL/forward/compact/metrics are **shipped**, and multi-node Raft is **supported** for the single-`default`-DB scope (failover under load, raft TLS, InstallSnapshot cold-node recovery — all e2e-proven). See [known-limitations](known-limitations.md) and `docs/superpowers/specs/2026-07-30-raft-cluster-status.md`.

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
| `BARADB_RAFT_SNAP_CHUNK_KB` | InstallSnapshot chunk size in KiB (default 256) |
| `BARADB_RAFT_PEER_STALE_MS` | Peer is stale after this many ms without an ack (default 30000); stale peers no longer pin log compaction |
| `BARADB_RAFT_TLS_ENABLED` | TLS on the raft TCP port (default false; fail-closed startup if cert/key missing) |
| `BARADB_RAFT_TLS_CERT_FILE` | Server certificate for the raft listener |
| `BARADB_RAFT_TLS_KEY_FILE` | Private key for the raft listener |
| `BARADB_RAFT_TLS_CA_FILE` | Optional CA bundle for peer verification |
| `BARADB_RAFT_TLS_VERIFY_PEER` | Mutual auth — verify client certificates (default false) |

When Raft is enabled, SQL DML (`INSERT`/`UPDATE`/`DELETE`/`MERGE` and transactional `COMMIT`) and schema DDL (`CREATE`/`DROP`/`ALTER` table, index, view, graph, …) are accepted only on the leader of the **`default`** database. DML ships as put/delete log entries; DDL ships as a `ddl` entry with the original SQL and is re-executed on every node at apply. Followers that receive a write/DDL **forward** it to the leader when `BARADB_RAFT_CLIENT_PEERS` maps the leader id to a SQL client address; otherwise they return `not leader; leader is '…'`. Writes against any other database name are rejected (`raft writes only supported on the 'default' database`). `CREATE`/`DROP DATABASE` are not raft-replicated (multi-DB is out of scope for v1). Committed DML also updates secondary B-tree/FTS/HNSW indexes and in-memory graphs.

**Log compaction:** after apply, each node may drop a fully-safe log prefix once `log.len` exceeds `BARADB_RAFT_LOG_MAX_ENTRIES`. On the leader, the safe prefix is computed only over peers that acked within `BARADB_RAFT_PEER_STALE_MS` — stale peers no longer pin compaction and are recovered by snapshot on return. Compaction never goes past `lastApplied`. Snapshot metadata (`lastSnapshotIndex`/`Term`) is persisted in `raft_state.bin`.

**Snapshot recovery (InstallSnapshot, v1.3.0):** when a follower's lag is unrecoverable (the entries it needs were compacted away), the leader builds a `tar.gz` snapshot of the default DB and streams it as `BARADB_RAFT_SNAP_CHUNK_KB`-sized chunks. The follower restores it via the backup/restore path, adopts the snapshot base as its `commitIndex`/`lastApplied`, and resumes normal AppendEntries catch-up. A node that returns after a long outage — and a **wiped** node (data dir deleted, same node id) — both converge automatically through this path. Proven by `tests/raft_coldnode_e2e_test.nim`.

**Client failover contract:** a write that is in flight when the leader dies **fails fast with an error** — the client must retry it (against the new leader, or any follower if `BARADB_RAFT_CLIENT_PEERS` forwarding is configured). Every write the server **acknowledged** survives the failover and is present on the new leader and all caught-up followers. Proven by `tests/raft_failover_load_e2e_test.nim` (leader killed under sustained INSERT load; all acked writes found on both survivors).

**Raft TLS (v1.3.0):** set `BARADB_RAFT_TLS_ENABLED=true` plus `BARADB_RAFT_TLS_CERT_FILE`/`BARADB_RAFT_TLS_KEY_FILE` on every node; startup fails closed if the cert or key is missing. Add `BARADB_RAFT_TLS_CA_FILE` and `BARADB_RAFT_TLS_VERIFY_PEER=true` for mutual authentication. The whole cluster must run the same mode: a plaintext node cannot speak to a TLS port (its frames are undecryptable) and is excluded from the cluster — proven by `tests/raft_tls_e2e_test.nim`. Follower→leader SQL forwarding is TLS-wrapped automatically when the server's client wire port has TLS enabled.

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
| `tests/raft_failover_load_e2e_test.nim` | Leader killed under sustained write load; every acked write survives |
| `tests/raft_tls_e2e_test.nim` | Full-TLS 3-node cluster works; plaintext node excluded |
| `tests/raft_coldnode_e2e_test.nim` | Returning node and wiped node converge via InstallSnapshot |

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