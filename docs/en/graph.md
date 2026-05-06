# Graph Engine

Adjacency list storage with built-in algorithms for graph traversal and analysis.

## Usage

```nim
import barabadb/graph/engine

var g = newGraph()
let alice = g.addNode("Person", {"name": "Alice"}.toTable)
let bob = g.addNode("Person", {"name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

# Traversal
let bfs = g.bfs(alice)
let dfs = g.dfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()
```

## Algorithms

| Algorithm | Description |
|-----------|-------------|
| `bfs` | Breadth-first traversal |
| `dfs` | Depth-first traversal |
| `dijkstra` | Shortest weighted path |
| `pageRank` | Node importance ranking |
| `louvain` | Community detection |
| `patternMatch` | Subgraph isomorphism |

## Cypher Query

```nim
import barabadb/graph/cypher

var engine = newCypherEngine(g)
let results = engine.execute("""
  MATCH (p:Person)-[:KNOWS]->(friend:Person)
  WHERE p.name = 'Alice'
  RETURN friend.name
""")
```

## Pattern Matching

```sql
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN b.name, c.name
```