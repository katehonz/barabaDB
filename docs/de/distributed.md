# Distributed Systems

BaraDB unterstützt verteiltes Deployment mit Raft Consensus, Sharding und Replikation.

## Raft Consensus

Leader Election und Log-Replikation:

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

Daten über Knoten verteilen:

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

### Sharding-Strategien

| Strategie | Beschreibung |
|----------|-------------|
| `ssHash` | Hash-basiertes Sharding |
| `ssRange` | Range-basiertes Sharding |
| `ssConsistent` | Consistent Hashing |

## Replikation

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
rm.connectReplica("r1")
let lsn = rm.writeLsn(@[1'u8, 2, 3])
rm.ackLsn("r1", lsn)
```

### Replikationsmodi

| Modus | Beschreibung |
|-------|--------------|
| `rmSync` | Synchronous Replikation |
| `rmAsync` | Asynchrone Replikation |
| `rmSemiSync` | Semi-synchrone Replikation |

## Gossip Protocol

Membership und Failure-Erkennung:

```nim
import barabadb/core/gossip

var g = newGossipManager()
g.addNode("node1")
g.addNode("node2")
g.tick()  # Membership-Info austauschen
```

## Distributed Transactions

Two-Phase Commit über Knoten:

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## Formale Verifikation

Kern-Algorithmen für Distributed Systems sind formal in TLA+ spezifiziert und model-gecheckt:

- **Raft Consensus** — `formal-verification/raft.tla`
  - Verifiziert: ElectionSafety, StateMachineSafety
- **Two-Phase Commit** — `formal-verification/twopc.tla`
  - Verifiziert: Atomicity, NoOrphanBlocks
- **Replication** — `formal-verification/replication.tla`
  - Verifiziert: MonotonicLsn, AcksRemovePending

TLC lokal ausführen:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -config models/replication.cfg replication.tla
```
