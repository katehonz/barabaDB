# سیستم‌های توزیع‌شده

BaraDB از استقرار توزیع‌شده با اجماع Raft، شاردینگ و تکثیر پشتیبانی می‌کند.

## اجماع Raft

انتخاب رهبر و تکثیر لاگ:

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

## شاردینگ

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(
  numShards: 4,
  replicas: 2,
  strategy: ssHash
))
```

### استراتژی‌های شاردینگ

| استراتژی | توضیح |
|-----------|--------|
| `ssHash` | شاردینگ مبتنی بر hash |
| `ssRange` | شاردینگ مبتنی بر بازه |
| `ssConsistent` | هش سازگار |

## تکثیر

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
```

### حالت‌های تکثیر

| حالت | توضیح |
|------|--------|
| `rmSync` | تکثیر همگام |
| `rmAsync` | تکثیر ناهمگام |
| `rmSemiSync` | تکثیر نیمه‌همگام |

## پروتکل Gossip

```nim
import barabadb/core/gossip

var g = newGossipManager()
g.addNode("node1")
g.addNode("node2")
g.tick()
```

## تراکنش‌های توزیع‌شده

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## تأیید رسمی

الگوریتم‌های اصلی توزیع‌شده در TLA+ مشخص و تأیید شده‌اند.