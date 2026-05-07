# 分布式系统

BaraDB 支持使用 Raft 共识、分片和复制进行分布式部署。

## Raft 共识

领导者选举和日志复制：

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

## 分片

跨节点分发数据：

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(
  numShards: 4,
  replicas: 2,
  strategy: ssHash
))
router.rebalance(@["node1", "node2", "node3"])
```

### 分片策略

| 策略 | 描述 |
|------|------|
| `ssHash` | 基于哈希的分片 |
| `ssRange` | 基于范围的分片 |
| `ssConsistent` | 一致性哈希 |

## 复制

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
```

### 复制模式

| 模式 | 描述 |
|------|------|
| `rmSync` | 同步复制 |
| `rmAsync` | 异步复制 |
| `rmSemiSync` | 半同步复制 |

## Gossip 协议

```nim
import barabadb/core/gossip

var g = newGossipManager()
g.addNode("node1")
g.addNode("node2")
g.tick()
```

## 分布式事务

两阶段提交：

```nim
import barabadb/core/disttxn

var dt = newDistributedTxn()
dt.prepare(@["node1", "node2"])
dt.commit()
```

## 形式化验证

核心分布式算法在 TLA+ 中形式化规范并通过模型检查：

- **Raft Consensus** — `formal-verification/raft.tla`
- **Two-Phase Commit** — `formal-verification/twopc.tla`
- **Replication** — `formal-verification/replication.tla`