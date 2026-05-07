# موتور گراف

ذخیره‌سازی لیست مجاورت با الگوریتم‌های داخلی برای پیمایش و تحلیل گراف.

## استفاده

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

## الگوریتم‌ها

| الگوریتم | توضیح |
|----------|--------|
| `bfs` | پیمایش اول سطح |
| `dfs` | پیمایش اول عمق |
| `dijkstra` | کوتاه‌ترین مسیر وزن‌دار |
| `pageRank` | رتبه‌بندی اهمیت گره |
| `louvain` | تشخیص جامعه |
| `patternMatch` | ایزومورفیسم زیرگراف |

## Cypher

```nim
import barabadb/graph/cypher

var engine = newCypherEngine(g)
let results = engine.execute("""
  MATCH (p:Person)-[:KNOWS]->(friend:Person)
  WHERE p.name = 'Alice'
  RETURN friend.name
""")
```