# Разпределена Система

BaraDB поддържа разпределено внедряване с Raft консенсус, шардиране, репликация и gossip протокол.

## Raft Консенсус

Leader election и log репликация:

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

## Шардиране

Разпределение на данни между възли:

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

### Стратегии за Шардиране

| Стратегия | Описание |
|-----------|----------|
| `ssHash` | Хеш-базирано шардиране |
| `ssRange` | Range-базирано шардиране |
| `ssConsistent` | Consistent hashing |

## Репликация

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
rm.connectReplica("r1")
let lsn = rm.writeLsn(@[1'u8, 2, 3])
rm.ackLsn("r1", lsn)
```

### Режими на Репликация

| Режим | Описание |
|--------|----------|
| `rmSync` | Синхронна репликация |
| `rmAsync` | Асинхронна репликация |
| `rmSemiSync` | Полу-синхронна репликация |

## Gossip Протокол

Управление на членство и детекция на откази:

```nim
import barabadb/core/gossip

var g = newGossipProtocol("node1", "localhost", 9472, gossipPort = 9572)
g.join(newGossipNode("node2", "10.0.0.2", 9472))
```

## Разпределени Транзакции

Two-phase commit между възли:

```nim
import barabadb/core/disttxn

var tm = newDistTxnManager()
let txn = tm.beginTransaction("node1")
txn.addParticipant("node2", "10.0.0.2", 9472)
txn.prepare()
txn.commit()
```

## Формална Верификация

Основните разпределени алгоритми са формално специфицирани в TLA+ и проверени с TLC:

- **Raft Консенсус** — `formal-verification/raft.tla`
  - Проверено: ElectionSafety, StateMachineSafety
- **Two-Phase Commit** — `formal-verification/twopc.tla`
  - Проверено: Atomicity, NoOrphanBlocks
- **Репликация** — `formal-verification/replication.tla`
  - Проверено: MonotonicLsn, AcksRemovePending

Пускане на TLC локално:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -config models/replication.cfg replication.tla
```
