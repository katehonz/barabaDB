# Graph Engine

Съхранение със списък от съседи и вградени алгоритми.

## Употреба

```nim
import barabadb/graph/engine

var g = newGraph()
let alice = g.addNode("Person", {"name": "Alice"}.toTable)
let bob = g.addNode("Person", {"name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

let bfs = g.bfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()
```

## Алгоритми

| Алгоритъм | Описание |
|-----------|----------|
| `bfs` | breadth-first обхождане |
| `dfs` | depth-first обхождане |
| `dijkstra` | Най-кратък път с тегла |
| `pageRank` | Ранг на възел |
| `louvain` | Откриване на общности |