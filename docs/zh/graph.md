# 图引擎

具有内置算法的邻接表存储，用于图遍历和分析。

## 用法

```nim
import barabadb/graph/engine

var g = newGraph()
let alice = g.addNode("Person", {"Name": "Alice"}.toTable)
let bob = g.addNode("Person", {"Name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

let bfs = g.bfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()
```

## 算法

| 算法 | 描述 |
|------|------|
| `bfs` | 广度优先遍历 |
| `dfs` | 深度优先遍历 |
| `dijkstra` | 最短加权路径 |
| `pageRank` | 节点重要性排名 |
| `louvain` | 社区检测 |
| `patternMatch` | 子图同构 |

## Cypher 查询

```nim
import barabadb/graph/cypher

var engine = newCypherEngine(g)
let results = engine.execute("""
  MATCH (p:Person)-[:KNOWS]->(friend:Person)
  WHERE p.name = 'Alice'
  RETURN friend.name
""")
```