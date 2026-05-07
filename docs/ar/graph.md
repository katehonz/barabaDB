# محرك الرسم البياني

تخزين قائمة المجاورة مع خوارزميات مدمجة للعبور والتحليل.

## الاستخدام

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

## الخوارزميات

| الخوارزمية | الوصف |
|------------|-------|
| `bfs` | عبور بالعرض |
| `dfs` | عبور بالعمق |
| `dijkstra` | أقصر مسار موزون |
| `pageRank` | ترتيب أهمية العقدة |
| `louvain` | كشف المجتمع |
| `patternMatch` | تماثل الرسم الفرعي |

## استعلام Cypher

```nim
import barabadb/graph/cypher

var engine = newCypherEngine(g)
let results = engine.execute("""
  MATCH (p:Person)-[:KNOWS]->(friend:Person)
  WHERE p.name = 'Alice'
  RETURN friend.name
""")
```