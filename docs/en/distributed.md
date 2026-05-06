# Distributed Systems

BaraDB supports distributed deployment with Raft consensus, sharding, and replication.

## Raft Consensus

Leader election and log replication:

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
rm.addReplica(newReplica("r1", "10.0.0.1", 5432))
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