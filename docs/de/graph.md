# Graph Engine

Adjazenzlisten-Speicher mit eingebauten Algorithmen für Graph-Traversierung und -Analyse.
Vollständig integriert in den SQL-Executor via `GRAPH_TABLE()`.

## SQL — Graph DDL

### Graph erstellen

```sql
CREATE GRAPH org_chart;
```

Erstellt automatisch zwei Tabellen:
- `org_chart_nodes (id INTEGER PRIMARY KEY, node_label TEXT, properties TEXT)`
- `org_chart_edges (source_id INTEGER, dest_id INTEGER, edge_label TEXT, weight REAL)`

### Graph löschen

```sql
DROP GRAPH org_chart;
```

## SQL — Daten einfügen

```sql
-- Knoten
INSERT INTO org_chart_nodes (id, node_label) VALUES (1, 'CEO');
INSERT INTO org_chart_nodes (id, node_label) VALUES (2, 'VP');

-- Kanten
INSERT INTO org_chart_edges (source_id, dest_id, edge_label) VALUES (1, 2, 'manages');
```

Alle INSERTs werden automatisch mit dem nativen Graph-Objekt synchronisiert.

## SQL — GRAPH_TABLE Abfragen

### BFS (Breitensuche)

```sql
SELECT * FROM GRAPH_TABLE(org_chart MATCH (n)-[r]->(m)
    ALGORITHM bfs
    START 1 MAXDEPTH 2
    COLUMNS (id, node_label));
```

### DFS (Tiefensuche)

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

### Kürzester Pfad (Shortest Path)

```sql
SELECT * FROM GRAPH_TABLE(org_chart
    ALGORITHM shortest_path
    START 1 END 3
    COLUMNS (id, node_label));
```

### Dijkstra (gewichtete kürzeste Pfade)

```sql
SELECT * FROM GRAPH_TABLE(org_chart
    ALGORITHM dijkstra START 1
    COLUMNS (id, node_label, distance));
```

## SQL-Funktionen

### Knotenähnlichkeit

```sql
-- Jaccard-Ähnlichkeit zwischen allen Knotenpaaren
SELECT similarity_nodes('social', 'jaccard') AS result;

-- Adamic-Adar-Ähnlichkeit
SELECT similarity_nodes('social', 'adamic_adar') AS result;
```

### Node2Vec Embeddings

```sql
-- Graphstruktur-Embeddings generieren (64 Dimensionen)
SELECT node2vec_embed('social', 64) AS result;
```

## Cypher-Kompatibilität

```sql
-- Cypher-Syntax automatisch nach GRAPH_TABLE übersetzen
SELECT cypher('MATCH (a)-[r]->(b) WHERE a.node_label = ''CEO'' RETURN b.node_label') AS result;
```

## Algorithmen

| Algorithmus | Beschreibung | SQL |
|-------------|--------------|-----|
| `bfs` | Breitensuche | `ALGORITHM bfs` |
| `dfs` | Tiefensuche | `ALGORITHM dfs` |
| `dijkstra` | Gewichtete kürzeste Pfade | `ALGORITHM dijkstra` |
| `pageRank` | Knoten-Wichtigkeit | `ALGORITHM pagerank` |
| `louvain` | Community Detection | `ALGORITHM community` |
| `shortestPath` | Kürzester Pfad | `ALGORITHM shortest_path START X END Y` |
| `similarityNodes` | Knotenähnlichkeit | `similarity_nodes()` |
| `node2vec` | Graph Embeddings | `node2vec_embed()` |

## Native Nim API

```nim
import barabadb/graph/engine

var g = newGraph()
let alice = g.addNode("Person", {"name": "Alice"}.toTable)
let bob = g.addNode("Person", {"name": "Bob"}.toTable)
discard g.addEdge(alice, bob, "knows")

let bfs = g.bfs(alice)
let path = g.shortestPath(alice, bob)
let ranks = g.pageRank()
let communities = louvain(g)
let similarities = g.similarityNodes(smJaccard)
let embeddings = g.node2vec(64, 10, 5)
```
