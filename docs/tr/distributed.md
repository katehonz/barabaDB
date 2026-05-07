# Dağıtık Sistemler

BaraDB Raft konsensüsü, parçalama ve çoğaltma ile dağıtık dağıtımı destekler.

## Raft Konsensüs

Lider seçimi ve log çoğaltma:

```nim
import barabadb/core/raft

var cluster = newRaftCluster()
cluster.addNode("node1")
cluster.addNode("node2")
cluster.addNode("node3")

let n1 = cluster.nodes["n1"]
n1.becomeCandidate()
n1.becomeLeader()
```

## Parçalama

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(
  numShards: 4,
  replicas: 2,
  strategy: ssHash
))
```

### Parçalama Stratejileri

| Strateji | Açıklama |
|----------|----------|
| `ssHash` | Hash tabanlı parçalama |
| `ssRange` | Aralık tabanlı parçalama |
| `ssConsistent` | Tutarlı hashleme |

## Çoğaltma

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
```

### Çoğaltma Modları

| Mod | Açıklama |
|-----|----------|
| `rmSync` | Senkron çoğaltma |
| `rmAsync` | Asenkron çoğaltma |
| `rmSemiSync` | Yarı-senkron çoğaltma |

## Dağıtık İşlemler

İki aşamalı commit:

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## Resmi Doğrulama

Temel dağıtık algoritmalar TLA+'da belirtilmiş ve model kontrolü yapılmıştır.