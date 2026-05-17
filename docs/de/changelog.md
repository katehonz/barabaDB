# Changelog

Alle bemerkenswerten Änderungen an BaraDB werden in dieser Datei dokumentiert.

## [Unreleased] — AI-Native Platform

### Hinzugefügt

- **MCP Server (Model Context Protocol)** — STDIO JSON-RPC 2.0 Server mit 3 AI-Tools:
  - `query` — SQL-Ausführung mit parametrisierten Abfragen + Multi-Tenant Session-Variablen
  - `vector_search` — Semantische HNSW Vektor-suche mit Tenant-Isolation
  - `schema_inspect` — Tabellen-/Spalten-/Index-/RLS-Policy-Exploration
  - Standalone Binary: `build/baramcp`
- **Graph Engine Tiefe Integration** — `CREATE GRAPH` / `DROP GRAPH` DDL mit nativer Adjacency-List-Speicherung
  - `GRAPH_TABLE()` SQL-Funktion mit 7 Algorithmen: BFS, DFS, PageRank, ShortestPath, Dijkstra, Louvain, Community
  - INSERT in `_nodes`/`_edges` Tabellen synchronisiert automatisch mit nativen Graph-Objekten
  - Optional `MATCH`, `ALGORITHM`, `START`, `END`, `MAXDEPTH` in GRAPH_TABLE Syntax
- **Chunking + Embedding Pipeline** — Serverseitige AI-Datenverarbeitung:
  - `chunk()` SQL-Funktion — Text-Splitting mit konfigurierbarer Größe/Überlappung
  - `embed_text()` SQL-Funktion — ruft externe Embedding-API auf (OpenAI/Ollama kompatibel)
  - Auto-Embedding bei INSERT — wenn VECTOR-Spalte null ist, generiert aus TEXT-Spalte
  - Konfigurierbar via Env-Vars: `BARADB_EMBED_ENDPOINT`, `BARADB_EMBED_MODEL`, `BARADB_EMBED_API_KEY`
- **LangChain ChatMessageHistory** — Python `BaraDBChatHistory` Klasse:
  - Speichert Konversations-Threads in relationaler Tabelle mit RLS
  - Multi-Tenant Isolation via `tenant_id` + `user_id`
- **RAG Pipeline Beispiel** — End-to-End Python Script (`examples/rag_pipeline.py`):
  - PDF/text Ingestion → chunking → embedding → BaraDB Speicherung → hybrid search → LLM Generierung
  - Unterstützt OpenAI und Ollama APIs
- **AI Agents & NL→SQL** — Serverseitige LLM-Integration:
  - `nl_to_sql()` SQL-Funktion — natürliche Sprache → SQL Generierung
  - `schema_prompt()` — generiert DDL + Beispieldaten für LLM-Kontext
  - Abfrage-Validierungsschicht — Sandbox-Ausführung mit LIMIT 0 + EXPLAIN
  - Selbst-Korrektur-Schleife — Fehlerfeedback an LLM zur Korrektur
  - Konfigurierbar via Env-Vars: `BARADB_LLM_ENDPOINT`, `BARADB_LLM_MODEL`, `BARADB_LLM_API_KEY`
- **Graph Similarity & Embeddings**:
  - `similarity_nodes()` — Jaccard/Adamic-Adar Ähnlichkeit zwischen Knotenpaaren
  - `node2vec_embed()` — Random-walk basierte Graph Embeddings
- **Cypher Compatibility Layer**:
  - `cypher()` SQL-Funktion — übersetzt `MATCH (a)-[r]->(b) RETURN ...` zu GRAPH_TABLE
  - Automatische Cypher → BaraQL Konvertierung
- **German Documentation** — Vollständige Dokumentation auf Deutsch (`docs/de/`)

### Geändert

- Graph Executor upgraded von Stub zu echtem BFS/DFS/PageRank/Dijkstra/Louvain
- ExecutionContext erweitert mit `graphs`, `embedder`, `llmClient` Feldern
- Graph Engine erweitert mit `addNodeWithId`, `addEdgeWithId`, Jaccard, Adamic-Adar, node2vec

## [1.1.0] — 2026-05-13

### Hinzugefügt

- **Client SDKs v1.1.4** — Vollständige Clients für alle Sprachen:
  - JavaScript: TypeScript Definitionen, package.json, Beispiele, Unit & Integration Tests
  - Python: Umstrukturiert als proper Package (`baradb/` mit `__init__.py` und `core.py`), pyproject.toml, Beispiele, Tests
  - Nim: Beispiele, Integration Tests, README
  - Rust: Beispiele, Integration Tests, verbessertes Cargo.toml
- **SCRAM-SHA-256 Authentifizierung** — RFC 7677 konforme Authentifizierung mit PBKDF2 + HMAC + SHA-256 + Nonce/Salt Generierung
- **HTTP SCRAM Endpoints** — `/auth/scram/start` + `/auth/scram/finish` im HTTP Server
- **Docker Compose Test Configuration** — `docker-compose.test.yml` für Test-Umgebungen
- **CI/CD Clients Pipeline** — `.github/workflows/clients-ci.yml` für automatisierte Client-Tests

### Behoben

- **Query Executor** — Unärer Minus (`irNeg`) funktioniert jetzt korrekt in SELECT und WHERE Klauseln
- **Distributed Transactions** — Rollback nach Commit-Versuch verletzt nicht mehr Atomicity
- **Sharding** — Datenmigrations-Protokoll mit TCP + `scanAll` auf LSM
- **Raft** — Majority-Berechnung für gerade Knotenanzahl korrigiert
- **MVCC** — Abgebrochene Transaktionen werden nicht mehr sichtbar
- **LSM-Tree** — Datenverlust bei immutable memtable overwrite behoben; SSTable lookup sorting behoben
- **Auth** — JWT-Signatur auf HMAC-SHA256 geändert (nicht mehr trivial fälschbar); Token-Ablauf (`exp`/`nbf`/`iat`) wird jetzt validiert; Signatur-Vergleich ist jetzt constant-time
- **Recovery** — `summary()` mutiert die Datenbank nicht mehr
- **Wire Protocol** — 64MB Limit + Bounds Checking + Max Depth um OOM/DoS zu verhindern
- **SQL Injection** — `exprToSql` escaped jetzt Single Quotes
- **ReDoS** — `irLike`/`irILike` escaped jetzt Regex Metacharacters
- **Graph** — `addEdge` prüft jetzt Knotenexistenz
- **Vector** — Dimension mismatch Validierung + HNSW Locking
- **FTS** — UTF-8 Tokenisierung verwendet jetzt runes statt bytes
- **Build** — `nim.cfg` fügt `-d:ssl` hinzu damit `nimble build` ohne Flags funktioniert; `--threads:on` zu allen CI Commands hinzugefügt

### Geändert

- **Version auf 1.1.0 erhöht** über alle Komponenten
- **README** — Version Badge aktualisiert; alle Feature-Tabellen referenzieren jetzt v1.1.4
- **TLA+ Formal Verification** — `crossmodal.tla`, `backup.tla`, `recovery.tla` hinzugefügt; Symmetrie-Reduktion in allen 9 Specs
- **Clean build** — 0 Compiler Warnings auf Nim 2.2.10

## [0.1.0] — 2025-01-15

### Hinzugefügt

- **Core Storage Engines**
  - LSM-Tree mit MemTable, WAL, SSTables und size-tiered Compaction
  - B-Tree geordneter Index mit Range Scans und MVCC Copy-on-Write
  - Bloom Filter für effizientes SSTable Skip
  - Memory-mapped I/O für SSTable Reads
  - LRU Page Cache mit Hit-Rate Tracking

- **Query Engine (BaraQL)**
  - SQL-kompatibler Lexer mit 80+ Tokentypen
  - Rekursiver Descent Parser produziert AST mit 25+ Knotenarten
  - Intermediate Representation (IR) für Ausführungspläne
  - Code Generator übersetzt IR zu Speicheroperationen
  - Adaptiver Query Optimizer mit Cross-Modal Planning
  - Query Executor mit Parallelisierung

- **BaraQL Language Features**
  - SELECT, INSERT, UPDATE, DELETE
  - WHERE, ORDER BY, LIMIT, OFFSET
  - GROUP BY, HAVING, Aggregatfunktionen (count, sum, avg, min, max)
  - INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN
  - CTEs (Common Table Expressions) mit WITH
  - Subqueries (EXISTS, IN, correlated)
  - CASE Expressions
  - UNION, INTERSECT, EXCEPT
  - Schema Definition: CREATE TYPE, DROP TYPE

- **Vector Engine**
  - HNSW Index für Approximate Nearest Neighbor Search
  - IVF-PQ Index für Large-Scale Vector Search
  - SIMD-optimierte Distanzfunktionen (cosine, L2, dot product, Manhattan)
  - Quantization: scalar 8-bit/4-bit, product quantization, binary
  - Metadata Filtering während Vector Search

- **Graph Engine**
  - Adjacency List Speicherung für gerichtete, kanten-gewichtete Graphen
  - BFS und DFS Traversierung
  - Dijkstra kürzester Pfad
  - PageRank Knotenwichtigkeit
  - Louvain Community Detection
  - Subgraph Pattern Matching
  - Cypher-ähnlicher Graph Query Parser

- **Full-Text Search**
  - Inverted Index mit Term-Document Mapping
  - BM25 Ranking-Algorithmus
  - TF-IDF Scoring
  - Fuzzy Search mit Levenshtein Distanz
  - Wildcard/regex Search
  - Multi-Language Tokenizer (English, Bulgarian, German, French, Russian)

- **Columnar Storage**
  - Perspalten-Speicherung für analytische Abfragen
  - RLE (Run-Length Encoding) Kompression
  - Dictionary Encoding für Low-Cardinality Spalten
  - SIMD-beschleunigte Aggregatfunktionen

- **Transactions**
  - MVCC (Multi-Version Concurrency Control) mit Snapshot Isolation
  - Deadlock-Erkennung via Wait-for Graph
  - Write-Ahead Log für Dauerhaftigkeit
  - Savepoints und partielles Rollback

- **Protocol Layer**
  - Binary Wire Protocol mit 16 Nachrichtentypen
  - HTTP/REST JSON API
  - WebSocket Streaming
  - Connection Pooling
  - JWT-basierte Authentifizierung
  - Token-bucket Rate Limiting
  - TLS/SSL mit auto-generierten Zertifikaten

- **Schema System**
  - Starkes Typsystem mit 17 nativen Typen
  - Typvererbung mit Multi-Base Support
  - Property Links zwischen Typen
  - Schema Diffing und Migrationen
  - Computed Properties

- **Distributed Systems**
  - Raft Consensus (Leader Election, Log Replikation)
  - Hash, Range und Consistent-Hash Sharding
  - Sync/async/semi-sync Replikation
  - Gossip Protocol für Membership Management
  - Two-Phase Commit für Distributed Transactions

- **Cross-Modal Queries**
  - Vereinheitlichte Abfragesprache über alle Speicher-Engines
  - Cross-Engine Predicate Pushdown
  - Optimierte Ausführungspläne für Multi-Modal Abfragen

- **Backup & Recovery**
  - Online Snapshots ohne Ausfallzeit
  - Point-in-Time Recovery via WAL Replay
  - Inkrementelle Backups

- **Client SDKs**
  - JavaScript/TypeScript Client mit Binary Protocol
  - Python Client mit Sync und Async APIs
  - Nim Embedded Mode und Client Library
  - Rust Client (async)

- **Operations**
  - Interaktive CLI Shell (BaraQL REPL)
  - Strukturiertes Logging (JSON und Text Formate)
  - Prometheus-kompatible Metrics Endpoint
  - Health und Readiness Probes
  - CPU/memory Profiling Endpoints

- **Docker Support**
  - Multi-stage Dockerfile (Alpine Linux)
  - Docker Compose Konfiguration
  - Health Checks

### Performance

- LSM-Tree: 580K writes/s, 720K reads/s
- B-Tree: 1.2M inserts/s, 1.5M lookups/s
- Vector SIMD: 850K cosine distances/s (dim=768)
- FTS: 320K docs/s indexing, 28K queries/s BM25
- Graph: 2.5M nodes/s insertion, 12K BFS traversals/s
- Binary Protocol: 380K queries/s (100 concurrent connections)

### Tests

- 262 Tests über 56 Test-Suiten
- 100% Pass Rate

## [Unreleased]

### Hinzugefügt

- **Vector SQL Integration** — Vollständige SQL-Level Vector Search Unterstützung:
  - `VECTOR(n)` Spaltentyp in `CREATE TABLE` mit Dimensionsvalidierung
  - `CREATE INDEX ... USING hnsw` / `USING ivfpq` für Approximate Nearest Neighbor Indizes
  - SQL Distanzfunktionen: `cosine_distance()`, `euclidean_distance()`, `inner_product()`, `l1_distance()`, `l2_distance()`
  - `<->` Nearest-Neighbor Operator (Euclidean Distanz)
  - `ORDER BY` Support für Vektor-Distanz-Ausdrücke, inklusive Spalten nicht in `SELECT`
  - Automatische HNSW Index-Wartung bei `INSERT` und `UPDATE`
- **Advanced SQL Engine** — Window Functions, MERGE/UPSERT, LATERAL JOIN, PIVOT/UNPIVOT, SQL/PGQ Property Graph, Advanced Aggregates
- **JavaScript Client — TCP Request Queue** — Interne `_requestQueue` + `_requestLock` für sichere konkurrierende Abfragen

### Behoben

- **Query Executor — Row Value Escaping** — `execInsert` escaped jetzt korrekt Kommas und Equals-Zeichen
- **Query Planner — ORDER BY Projection** — `irpkSort` ist jetzt vor `irpkProject` im IR Plan platziert
- **Wire Protocol — Big-Endian Float Serialization** — `FLOAT32`/`FLOAT64` werden jetzt in Big-Endian Byte-Reihenfolge serialisiert
- **Gossip Protocol — Async UDP Socket** — Synchrone `newSocket` + blocking `recvFrom` ersetzt durch `newAsyncSocket` + `await recvFrom`

### Geplant

- Query Plan Caching
- Materialized Views
- Geospatial Index
- Time-series Optimierungen
- CDC (Change Data Capture) Streaming
- Federated Queries über BaraDB Instances
