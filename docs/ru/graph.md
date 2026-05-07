# Графовый движок

Хранение в виде списка смежности со встроенными алгоритмами для обходов и анализа графов.

## Использование

```nim
import barabadb/graph/engine

var g = newGraph()
let alice = g.addNode("Person", {"Name": "Alice"}.toTable)
let bob = g.addNode("Person", {"Name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

let bfs = g.bfs(alice)
let dfs = g.dfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()
```

## Алгоритмы

| Алгоритм | Описание |
|----------|---------|
| `bfs` | Поиск в ширину |
| `dfs` | Поиск в глубину |
| `dijkstra` | Кратчайший взвешенный путь |
| `pageRank` | Ранжирование важности узлов |
| `louvain` | Обнаружение сообществ |
| `patternMatch` | Изоморфизм подграфов |

## Cypher запрос

```nim
import barabadb/graph/cypher

var engine = newCypherEngine(g)
let results = engine.execute("""
  MATCH (p:Person)-[:KNOWS]->(friend:Person)
  WHERE p.name = 'Alice'
  RETURN friend.name
""")
```

## Сопоставление шаблонов

```sql
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN b.name, c.name
```