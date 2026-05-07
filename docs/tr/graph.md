# Grafik Motoru

Grafik geçişi ve analizi için yerleşik algoritmalarla bitişik liste depolaması.

## Kullanım

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

## Algoritmalar

| Algoritma | Açıklama |
|-----------|----------|
| `bfs` | Enine arama |
| `dfs` | Derine arama |
| `dijkstra` | En kısa ağırlıklı yol |
| `pageRank` | Düğüm önem sıralaması |
| `louvain` | Topluluk tespiti |
| `patternMatch` | Altgraf eşleme |

## Cypher Sorgusu

```nim
import barabadb/graph/cypher

var engine = newCypherEngine(g)
let results = engine.execute("""
  MATCH (p:Person)-[:KNOWS]->(friend:Person)
  WHERE p.name = 'Alice'
  RETURN friend.name
""")
```