# الأنظمة الموزعة

تدعم BaraDB النشر الموزع مع توافق Raft والتجزئة والنسخ.

## توافق Raft

انتخاب القائد ونسخ السجل:

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

## التجزئة

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(
  numShards: 4,
  replicas: 2,
  strategy: ssHash
))
```

### استراتيجيات التجزئة

| الاستراتيجية | الوصف |
|-------------|-------|
| `ssHash` | تجزئة قائمة على hash |
| `ssRange` | تجزئة قائمة على النطاق |
| `ssConsistent` | تجزئة متسقة |

## النسخ

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
```

### أوضاع النسخ

| الوضع | الوصف |
|-------|-------|
| `rmSync` | نسخ متزامن |
| `rmAsync` | نسخ غير متزامن |
| `rmSemiSync` | نسخ شبه متزامن |

## المعاملات الموزعة

الالتزام على مرحلتين:

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## التحقق الرسمي

تم تحديد الخوارزميات الموزعة الأساسية في TLA+ والتحقق منها.