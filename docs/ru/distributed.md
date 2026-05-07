# Распределённые системы

BaraDB поддерживает распределённое развёртывание с консенсусом Raft, шардированием и репликацией.

## Консенсус Raft

Выбор лидера и репликация лога:

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

## Шардирование

Распределение данных по узлам:

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

### Стратегии шардирования

| Стратегия | Описание |
|-----------|----------|
| `ssHash` | Хэш-шардирование |
| `ssRange` | Диапазонное шардирование |
| `ssConsistent` | Консистентное хэширование |

## Репликация

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
rm.connectReplica("r1")
let lsn = rm.writeLsn(@[1'u8, 2, 3])
rm.ackLsn("r1", lsn)
```

### Режимы репликации

| Режим | Описание |
|--------|----------|
| `rmSync` | Синхронная репликация |
| `rmAsync` | Асинхронная репликация |
| `rmSemiSync` | Полусинхронная репликация |

## Gossip протокол

Членство и обнаружение отказов:

```nim
import barabadb/core/gossip

var g = newGossipManager()
g.addNode("node1")
g.addNode("node2")
g.tick()
```

## Распределённые транзакции

Двухфазный коммит:

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## Формальная верификация

Основные распределённые алгоритмы формально специфицированы в TLA+ и проверены:

- **Raft Consensus** — `formal-verification/raft.tla`
  - Проверено: ElectionSafety, StateMachineSafety
- **Two-Phase Commit** — `formal-verification/twopc.tla`
  - Проверено: Atomicity, NoOrphanBlocks
- **Replication** — `formal-verification/replication.tla`
  - Проверено: MonotonicLsn, AcksRemovePending

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -config models/replication.cfg replication.tla
```