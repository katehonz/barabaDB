# Graph Engine

Adjacency list storage with built-in algorithms for graph traversal and analysis.
Fully integrated into the SQL executor via `GRAPH_TABLE()`.

## SQL — Graph DDL

### Create Graph

```sql
CREATE GRAPH org_chart;
```

Automatically creates two tables:
- `org_chart_nodes (id INTEGER PRIMARY KEY, node_label TEXT, properties TEXT)`
- `org_chart_edges (source_id INTEGER, dest_id INTEGER, edge_label TEXT, weight REAL)`

### Drop Graph

```sql
DROP GRAPH org_chart;
```

## SQL — Insert Data

```sql
-- Nodes
INSERT INTO org_chart_nodes (id, node_label) VALUES (1, 'CEO');
INSERT INTO org_chart_nodes (id, node_label) VALUES (2, 'VP');

-- Edges
INSERT INTO org_chart_edges (source_id, dest_id, edge_label) VALUES (1, 2, 'manages');
```

All INSERTs are automatically synced with the native Graph object.

## SQL — GRAPH_TABLE Queries

### BFS (Breadth-First Search)

```sql
SELECT * FROM GRAPH_TABLE(org_chart MATCH (n)-[r]->(m)
    ALGORITHM bfs
    START 1 MAXDEPTH 2
    COLUMNS (id, node_label));
```

### DFS (Depth-First Search)

```sql
SELECT * FROM GRAPH_TABLE(org_chart MATCH (n)-[r]->(m)
    ALGORITHM dfs START 1
    COLUMNS (id, node_label));
```

### PageRank

```sql
SELECT id, node_label, rank FROM GRAPH_TABLE(org_chart
    ALGORITHM pagerank
    COLUMNS (id, node_label, rank))
ORDER BY rank DESC;
```

### Community Detection (Louvain)

```sql
SELECT id, node_label, community FROM GRAPH_TABLE(org_chart
    ALGORITHM community
    COLUMNS (id, node_label, community));
```

### Shortest Path

```sql
SELECT * FROM GRAPH_TABLE(org_chart
    ALGORITHM shortest_path
    START 1 END 3
    COLUMNS (id, node_label));
```

### Dijkstra (Weighted Shortest Paths)

```sql
SELECT * FROM GRAPH_TABLE(org_chart
    ALGORITHM dijkstra START 1
    COLUMNS (id, node_label, distance));
```

## SQL Functions

### Node Similarity

```sql
-- Jaccard similarity between all node pairs
SELECT similarity_nodes('social', 'jaccard') AS result;

-- Adamic-Adar similarity
SELECT similarity_nodes('social', 'adamic_adar') AS result;
```

### Node2Vec Embeddings

```sql
-- Generate graph structure embeddings (64 dimensions)
SELECT node2vec_embed('social', 64) AS result;
```

## Cypher Compatibility

```sql
-- Cypher syntax auto-translated to GRAPH_TABLE
SELECT cypher('MATCH (a)-[r]->(b) WHERE a.node_label = ''CEO'' RETURN b.node_label') AS result;
```

## Algorithms

| Algorithm | Description | SQL Syntax |
|-----------|-------------|------------|
| `bfs` | Breadth-first traversal | `ALGORITHM bfs` |
| `dfs` | Depth-first traversal | `ALGORITHM dfs` |
| `dijkstra` | Weighted shortest paths | `ALGORITHM dijkstra` |
| `pageRank` | Node importance ranking | `ALGORITHM pagerank` |
| `louvain` | Community detection | `ALGORITHM community` |
| `shortestPath` | Shortest unweighted path | `ALGORITHM shortest_path START X END Y` |
| `similarityNodes` | Jaccard/Adamic-Adar | `similarity_nodes()` |
| `node2vec` | Graph embeddings | `node2vec_embed()` |

## Native Nim API

```nim
import barabadb/graph/engine
import barabadb/graph/community

var g = newGraph()
let alice = g.addNode("Person", {"name": "Alice"}.toTable)
let bob = g.addNode("Person", {"name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

# Traversal
let bfsResult = g.bfs(alice)
let dfsResult = g.dfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()

# Community detection
let communities = louvain(g)

# Node similarity
let similarities = g.similarityNodes(smJaccard)
let adamicAdar = g.similarityNodes(smAdamicAdar)

# Graph embeddings
let embeddings = g.node2vec(64, 10, 5)
```

## Cypher Query (Native)

```nim
import barabadb/graph/cypher

# Translate Cypher to BaraQL
let sql = cypherToSql("MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN b.name")
# Result: "SELECT b.name FROM GRAPH_TABLE(g MATCH (a)-[r]->(b) COLUMNS (b.name))"
```

## Pattern Matching

```sql
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN b.name, c.name
```

## Architecture Notes

- **Native storage**: Edges stored as adjacency lists for O(1) neighbor access
- **Bidirectional indexes**: Both `source→targets` and `target→sources` for fast traversal
- **RLS integration**: Graph tables are regular SQL tables — existing RLS policies apply automatically
- **Transactional**: INSERT/UPDATE/DELETE on graph tables participate in MVCC transactions
