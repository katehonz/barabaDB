# Разпределена Система

Поддръжка за разпределено внедряване с Raft консенсус, шардиране и репликация.

## Raft Консенсус

```nim
import barabadb/core/raft

var cluster = newRaftCluster()
cluster.addNode("node1")
cluster.addNode("node2")
cluster.addNode("node3")

let n1 = cluster.nodes["n1"]
n1.becomeLeader()
```

## Шардиране

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(numShards: 4, replicas: 2))
router.rebalance(@["node1", "node2", "node3"])
let shard = router.getShard("user_123")
```

## Репликация

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
rm.connectReplica("r1")
```