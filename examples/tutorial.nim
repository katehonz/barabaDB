## BaraDB Examples — getting started tutorials
import ../src/barabadb/storage/lsm
import ../src/barabadb/storage/btree
import ../src/barabadb/vector/engine
import ../src/barabadb/graph/engine
import ../src/barabadb/graph/community
import ../src/barabadb/fts/engine
import ../src/barabadb/core/mvcc
import ../src/barabadb/query/lexer
import ../src/barabadb/query/parser

# Example 1: Basic Key-Value Store
proc exampleKeyValue() =
  echo "=== Example 1: Key-Value Store ==="
  var db = newLSMTree("./tutorial_kv")

  # Put data
  db.put("user:1", cast[seq[byte]]("Alice,30,Engineer"))
  db.put("user:2", cast[seq[byte]]("Bob,25,Designer"))
  db.put("user:3", cast[seq[byte]]("Charlie,35,Manager"))

  # Get data
  let (found, value) = db.get("user:1")
  if found:
    echo "  user:1 = ", cast[string](value)

  # Contains check
  echo "  user:1 exists: ", db.contains("user:1")
  echo "  user:99 exists: ", db.contains("user:99")

  # Delete
  db.delete("user:3")
  echo "  user:3 deleted: ", db.contains("user:3")

  db.close()

# Example 2: B-Tree Range Queries
proc exampleBTree() =
  echo "=== Example 2: B-Tree Range Queries ==="
  var btree = newBTreeIndex[string, string]()

  for i in 0..<100:
    btree.insert("key_" & $i, "value_" & $i)

  # Point query
  let vals = btree.get("key_42")
  echo "  Point query key_42: ", vals

  # Range scan
  let range = btree.scan("key_10", "key_20")
  echo "  Range scan key_10..key_20: ", range.len, " results"
  echo "    First: ", range[0][0], " = ", range[0][1]
  echo "    Last: ", range[^1][0], " = ", range[^1][1]

# Example 3: Vector Similarity Search
proc exampleVectorSearch() =
  echo "=== Example 3: Vector Similarity Search ==="
  var idx = newHNSWIndex(dimensions = 3)

  # Insert vectors with metadata
  idx.insert(1, @[1.0'f32, 0.0'f32, 0.0'f32], {"type": "red"}.toTable)
  idx.insert(2, @[0.0'f32, 1.0'f32, 0.0'f32], {"type": "green"}.toTable)
  idx.insert(3, @[0.0'f32, 0.0'f32, 1.0'f32], {"type": "blue"}.toTable)
  idx.insert(4, @[0.9'f32, 0.1'f32, 0.0'f32], {"type": "red"}.toTable)

  # Search similar vectors
  let query = @[1.0'f32, 0.0'f32, 0.0'f32]
  let results = idx.search(query, k = 3)
  echo "  Search results for [1.0, 0.0, 0.0]:"
  for (id, dist) in results:
    echo "    ID: ", id, " distance: ", dist

# Example 4: Graph Traversal
proc exampleGraph() =
  echo "=== Example 4: Graph Traversal ==="
  var g = newGraph()

  # Create nodes
  let alice = g.addNode("Person", {"name": "Alice", "age": "30"}.toTable)
  let bob = g.addNode("Person", {"name": "Bob", "age": "25"}.toTable)
  let charlie = g.addNode("Person", {"name": "Charlie", "age": "35"}.toTable)
  let diana = g.addNode("Person", {"name": "Diana", "age": "28"}.toTable)

  # Create edges
  discard g.addEdge(alice, bob, "KNOWS")
  discard g.addEdge(bob, charlie, "KNOWS")
  discard g.addEdge(alice, diana, "KNOWS")

  # BFS traversal
  let bfs = g.bfs(alice)
  echo "  BFS from Alice: ", bfs.len, " nodes"

  # Shortest path
  let path = g.shortestPath(alice, charlie)
  echo "  Shortest path Alice→Charlie: ", path.len, " hops"

  # PageRank
  let ranks = g.pageRank()
  echo "  PageRank top node: ", ranks.entries().sorted(
    proc(a, b: (NodeId, float64)): int = cmp(b[1], a[1]))[0]

# Example 5: Full-Text Search
proc exampleFTS() =
  echo "=== Example 5: Full-Text Search ==="
  var idx = newInvertedIndex()

  # Add documents
  idx.addDocument(1, "Nim is a statically typed compiled language with Python-like syntax")
  idx.addDocument(2, "Python is an interpreted language popular for data science")
  idx.addDocument(3, "Rust is a systems programming language with memory safety")
  idx.addDocument(4, "JavaScript runs in browsers and on servers via Node.js")

  # BM25 search
  echo "  BM25 search: 'programming language':"
  for result in idx.search("programming language", limit = 3):
    echo "    Doc ", result.docId, " score: ", result.score

  # TF-IDF search
  echo "  TF-IDF search: 'compiled language':"
  for result in idx.searchTfidf("compiled language", limit = 3):
    echo "    Doc ", result.docId, " score: ", result.score

  # Fuzzy search
  echo "  Fuzzy search: 'propgramming' (typo):"
  for result in idx.fuzzySearch("propgramming", maxDistance = 2, limit = 3):
    echo "    Doc ", result.docId, " score: ", result.score

# Example 6: Transactions (MVCC)
proc exampleTransactions() =
  echo "=== Example 6: Transactions ==="
  var tm = newTxnManager()

  # Transaction 1: write
  let txn1 = tm.beginTxn()
  discard tm.write(txn1, "balance:alice", cast[seq[byte]]("100"))
  discard tm.write(txn1, "balance:bob", cast[seq[byte]]("200"))
  discard tm.commit(txn1)

  # Transaction 2: snapshot isolation
  let txn2 = tm.beginTxn()
  # Can't see concurrent writes
  let (found, val) = tm.read(txn2, "balance:alice")
  echo "  Alice balance (txn2 before commit): ", if found: cast[string](val) else: "nil"

  # Transaction 3: concurrent write
  let txn3 = tm.beginTxn()
  discard tm.write(txn3, "balance:alice", cast[seq[byte]]("150"))
  discard tm.commit(txn3)

  # txn2 still sees old value (snapshot)
  let (found2, val2) = tm.read(txn2, "balance:alice")
  echo "  Alice balance (txn2 after txn3 commit): ", if found2: cast[string](val2) else: "nil"
  discard tm.commit(txn2)

  # New transaction sees latest
  let txn4 = tm.beginTxn()
  let (found3, val3) = tm.read(txn4, "balance:alice")
  echo "  Alice balance (new txn): ", if found3: cast[string](val3) else: "nil"
  discard tm.commit(txn4)

# Example 7: BaraQL Query Parsing
proc exampleBaraQL() =
  echo "=== Example 7: BaraQL Query Parsing ==="

  let queries = [
    "SELECT name, age FROM users WHERE age > 18 ORDER BY name LIMIT 10",
    "INSERT users { name := 'Alice', age := 30 }",
    "UPDATE users SET name = 'Bob' WHERE id = 1",
    "DELETE FROM users WHERE id = 99",
    "SELECT dept, count(*), avg(salary) FROM employees GROUP BY dept HAVING count(*) > 5",
    "SELECT u.name, o.total FROM users u LEFT JOIN orders o ON u.id = o.user_id",
    "WITH recent AS (SELECT * FROM orders WHERE date > '2025-01-01') SELECT * FROM recent",
  ]

  for query in queries:
    try:
      let tokens = tokenize(query)
      let ast = parse(tokens)
      echo "  ✓ ", query[0..<min(query.len, 60)], "..."
    except Exception as e:
      echo "  ✗ ", query[0..<min(query.len, 40)], "... : ", e.msg

# Example 8: Community Detection
proc exampleCommunity() =
  echo "=== Example 8: Community Detection ==="
  var g = newGraph()

  # Create two communities with dense internal connections
  var nodes: seq[NodeId] = @[]
  for i in 0..<10:
    nodes.add(g.addNode("User_$1", {"id": $i}.toTable))

  # Community 1: fully connected
  for i in 0..4:
    for j in i+1..4:
      discard g.addEdge(nodes[i], nodes[j])

  # Community 2: fully connected
  for i in 5..9:
    for j in i+1..9:
      discard g.addEdge(nodes[i], nodes[j])

  # Single connection between communities
  discard g.addEdge(nodes[0], nodes[5])

  let result = louvain(g)
  echo "  Detected ", result.numCommunities, " communities"
  echo "  Modularity: ", result.modularity

proc main() =
  echo "╔══════════════════════════════════════╗"
  echo "║      BaraDB Tutorial Examples         ║"
  echo "╚══════════════════════════════════════╝"
  echo ""
  exampleKeyValue()
  echo ""
  exampleBTree()
  echo ""
  exampleVectorSearch()
  echo ""
  exampleGraph()
  echo ""
  exampleFTS()
  echo ""
  exampleTransactions()
  echo ""
  exampleBaraQL()
  echo ""
  exampleCommunity()

when isMainModule:
  main()
