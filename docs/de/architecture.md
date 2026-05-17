# BaraDB Architektur

## Überblick

BaraDB ist eine **multimodale Datenbank-Engine** in Nim, die Document (KV), Graph, Vector, Columnar und Full-Text Search Speicherung in einer einzigen Engine mit einer einheitlichen Abfragesprache namens **BaraQL** kombiniert.

## Schichten-Architektur

```
┌─────────────────────────────────────────────────────────┐
│ 1. CLIENT LAYER                                          │
│    Binary Protocol │ HTTP/REST │ WebSocket │ Embedded    │
├─────────────────────────────────────────────────────────┤
│ 2. QUERY LAYER (BaraQL)                                  │
│    Lexer → Parser → AST → IR → Optimizer → Codegen      │
├─────────────────────────────────────────────────────────┤
│ 3. EXECUTION ENGINE                                      │
│    Document │ Graph │ Vector │ Columnar │ FTS            │
├─────────────────────────────────────────────────────────┤
│ 4. STORAGE                                               │
│    LSM-Tree │ B-Tree │ WAL │ Bloom │ Compaction │ Cache  │
├─────────────────────────────────────────────────────────┤
│ 5. DISTRIBUTED                                           │
│    Raft Consensus │ Sharding │ Replication │ Gossip      │
└─────────────────────────────────────────────────────────┘
```

## Schicht 1: Client-Layer

Mehrere Kommunikationsprotokolle:

- **Binärprotokoll** (`protocol/wire.nim`): Effizientes Big-Endian Binärprotokoll mit 16 Nachrichtentypen
- **HTTP/REST** (`core/httpserver.nim`): JSON-basierte REST API mit Multi-Threading
- **WebSocket** (`core/websocket.nim`): Vollduplex-Streaming
- **Embedded** (`storage/lsm.nim`): Direkter In-Process-Zugriff

### Verbindungsmanagement

- **Connection Pool** (`protocol/pool.nim`): Min/Max Verbindungslimits mit Idle-Timeout
- **Rate Limiting** (`protocol/ratelimit.nim`): Token-Bucket globale und per-Client Limits
- **Authentifizierung** (`protocol/auth.nim`): JWT mit HMAC-SHA256 und rollenbasierter Zugriff
- **TLS/SSL** (`protocol/ssl.nim`): TLS 1.3 mit auto-generierten Zertifikaten

## Schicht 2: Query-Layer (BaraQL)

Die BaraQL-Pipeline:

1. **Lexer** (`query/lexer.nim`): Tokenisiert Eingabe in 80+ Tokentypen
2. **Parser** (`query/parser.nim`): Rekursiver Descent-Parser produziert AST
3. **AST** (`query/ast.nim`): 300+ Zeilen mit 25+ Knotenarten
4. **IR** (`query/ir.nim`): Intermediate Representation für Ausführungspläne
5. **Optimizer** (`query/adaptive.nim`): Adaptive Cross-Modal Query-Optimierung
6. **Codegen** (`query/codegen.nim`): Übersetzt IR zu Speicheroperationen
7. **Executor** (`query/executor.nim`): Führt Pläne mit Parallelisierung aus

### Cross-Modal Planning

Der Optimizer (`query/adaptive.nim`) bestimmt die Ausführungsreihenfolge über Engines:

```
1. Selektivität für jedes Prädikat schätzen
2. Selektivstes Prädikat zuerst an seine Engine pushen
3. Bloom-Filter für KV-Lookups verwenden
4. Unabhängige Zweige parallelisieren
5. Results streamen um Materialisierung zu vermeiden
```

## Schicht 3: Execution Engine

### Document/KV Engine
- **LSM-Tree** (`storage/lsm.nim`): Write-optimierte Speicherung mit MemTable, WAL, SSTables
- **B-Tree Index** (`storage/btree.nim`): Geordneter Index für Bereichsscans mit COW

### Vector Engine (`vector/`)
- **HNSW Index** (`vector/engine.nim`): Hierarchical Navigable Small World Graph
- **IVF-PQ Index** (`vector/engine.nim`): Inverted File Index mit Product Quantization
- **SIMD Operations** (`vector/simd.nim`): AVX2-optimierte Distanzberechnungen
- **Quantization** (`vector/quant.nim`): Scalar, Product und Binary Quantization

### Graph Engine (`graph/`)
- **Adjacency List** (`graph/engine.nim`): Kanten-gewichteter gerichteter Graph
- **Algorithmen** (`graph/engine.nim`): BFS, DFS, Dijkstra, PageRank
- **Community Detection** (`graph/community.nim`): Louvain-Algorithmus
- **Pattern Matching** (`graph/community.nim`): Subgraph-Isomorphie
- **Cypher Parser** (`graph/cypher.nim`): Cypher-ähnliche Graph-Abfragen

### Full-Text Search (`fts/`)
- **Inverted Index** (`fts/engine.nim`): Term-Document Index
- **Ranking** (`fts/engine.nim`): BM25 und TF-IDF Scoring
- **Fuzzy Search** (`fts/engine.nim`): Levenshtein-Distanz-Matching
- **Multi-Language** (`fts/multilang.nim`): Tokenizer für EN, BG, DE, FR, RU

### Columnar Engine (`core/columnar.nim`)
- Perspalten-Speicherung für analytische Abfragen
- RLE und Dictionary-Kodierung
- SIMD-beschleunigte Aggregatfunktionen

## Schicht 4: Storage

- **LSM-Tree** (`storage/lsm.nim`): MemTable, WAL, SSTable, Bloom-Filter, Compaction
- **Page Cache** (`storage/compaction.nim`): LRU-Cache mit Trefferraten-Verfolgung
- **Memory-mapped I/O** (`storage/mmap.nim`): mmap-basierter Dateizugriff
- **Recovery** (`storage/recovery.nim`): WAL-Replay und Crash-Recovery

### Write Path

```
Client → Protocol → Auth → Parser → AST → IR → Codegen
  → StorageOp → MVCC Txn → WAL Write → MemTable → Commit
```

### Read Path

```
Client → Protocol → Auth → Parser → AST → IR → Codegen
  → StorageOp → MVCC Snapshot → MemTable → SSTable → Result
```

## Schicht 5: Distributed

- **Raft Consensus** (`core/raft.nim`): Leader Election, Log-Replikation
- **Sharding** (`core/sharding.nim`): Hash, Range und Consistent Hashing
- **Replication** (`core/replication.nim`): Sync, Async, Semi-Sync Modi
- **Gossip Protocol** (`core/gossip.nim`): SWIM-ähnliches Membership-Management
- **Distributed Transactions** (`core/disttxn.nim`): Two-Phase Commit

## Wichtige Designentscheidungen

1. **Reines Nim**: Keine Cython, Python oder Rust Abhängigkeiten
2. **Unified Storage**: Eine Engine-handelt KV, Graph, Vector, FTS und Columnar
3. **Embedded Mode**: Kann als Bibliothek oder Server laufen
4. **Binärprotokoll**: Custom effizientes Wire-Protokoll
5. **MVCC**: Multi-Version Concurrency Control
6. **Schema-First**: Stark typisiertes Schema-System mit Vererbung
7. **Cross-Modal**: Einheitliche Abfragesprache über alle Datenmodelle
8. **Formally Verified**: Kern-Algorithmen in TLA+ spezifiziert und mit TLC model-gecheckt

## Modulstatistiken

| Kategorie | Module | Codezeilen | Zweck |
|----------|--------|------------|-------|
| Core | 16 | ~4,200 | Server, Protokolle, Transaktionen, Distributed |
| Storage | 7 | ~3,100 | LSM, B-Tree, WAL, Bloom, Compaction, mmap |
| Query | 7 | ~2,800 | Lexer, Parser, AST, IR, Optimizer, Codegen, Executor |
| Vector | 3 | ~1,200 | HNSW, IVF-PQ, Quantization, SIMD |
| Graph | 3 | ~1,000 | Adjacency List, Algorithmen, Community Detection |
| FTS | 2 | ~900 | Inverted Index, BM25, Fuzzy, Multi-Language |
| Protocol | 7 | ~2,400 | Wire, HTTP, WebSocket, Pool, Auth, Rate Limit, SSL |
| Schema | 1 | ~600 | Typen, Links, Vererbung, Migrationen |
| Client | 2 | ~800 | Nim Binary Client, File Helpers |
| CLI | 1 | ~400 | Interaktive BaraQL Shell |
| **Total** | **49** | **~14,100** | |
