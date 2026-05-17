# Vektor-Suche

Native HNSW und IVF-PQ Indizes für Ähnlichkeitssuche mit vollständiger SQL-Integration.

## SQL — Vektor-Spalten

```sql
CREATE TABLE items (
    id INT PRIMARY KEY,
    embedding VECTOR(768)
);
```

Der `VECTOR(n)`-Typ speichert float32-Arrays mit fester Dimension `n`.

## Vektoren einfügen

```sql
INSERT INTO items (id, embedding) VALUES (1, '[0.1, 0.2, 0.3, ...]');
```

## Vektor-Distanzfunktionen

```sql
-- Kosinus-Distanz (0 = identisch, 1 = orthogonal)
SELECT id, cosine_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;

-- Euklidische / L2 Distanz
SELECT id, euclidean_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;
SELECT id, embedding <-> '[0.1, 0.2, 0.3]' AS dist FROM items;

-- Inneres Produkt (negativ für Minimierung)
SELECT id, inner_product(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;

-- Manhattan / L1 Distanz
SELECT id, l1_distance(embedding, '[0.1, 0.2, 0.3]') AS dist FROM items;
```

## Vektor-Indizes

```sql
-- HNSW-Index für approximative Nächste-Nachbarn-Suche
CREATE INDEX idx_items_vec ON items(embedding) USING hnsw;

-- Der Index wird bei INSERT und UPDATE automatisch aktualisiert
```

## Hybrid RAG Search

```sql
-- Kombinierte Vektor- + Volltext-Suche mit RRF-Reranking
SELECT hybrid_search('AI query', embedding, content, 10) AS result;

-- Gefilterte hybride Suche
SELECT hybrid_search_filtered('AI query', embedding, content, 10, 'category', 'news') AS result;
```

## AI Pipeline

### Text-Chunking

```sql
-- Text in überlappende Chunks zerlegen
SELECT chunk('Langer Text hier...', 1024, 128) AS result;

-- Ergebnis: [{"index":0, "text":"...", "size":124}, ...]
```

### Embedding-Generierung

```sql
-- Externen Embedding-Service aufrufen (konfiguriert via Umgebungsvariablen)
SELECT embed_text('Suchtext hier') AS result;
```

Umgebungsvariablen für den Embedder:
```bash
export BARADB_EMBED_ENDPOINT=http://localhost:11434/api/embeddings
export BARADB_EMBED_MODEL=nomic-embed-text
```

### Auto-Embedding bei INSERT

Wenn eine VECTOR-Spalte NULL ist, aber eine TEXT-Spalte einen Wert hat, wird das Embedding automatisch generiert (falls ein Embedder konfiguriert ist).

```sql
CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT, embedding VECTOR(768));
CREATE INDEX docs_vec ON docs(embedding) USING hnsw;

-- embedding wird automatisch gefüllt
INSERT INTO docs (id, content) VALUES (1, 'Dieser Text wird automatisch embedded');
```

## Distanzmetriken

| Metrik | SQL-Funktion | Beschreibung |
|--------|-------------|-------------|
| `cosine` | `cosine_distance(a, b)` | Kosinus-Distanz |
| `euclidean` | `euclidean_distance(a, b)` / `<->` | L2-Distanz |
| `dotproduct` | `inner_product(a, b)` | Negatives Skalarprodukt |
| `manhattan` | `l1_distance(a, b)` | L1-Distanz |

## Index-Typen

### HNSW (Standard)

```nim
import barabadb/vector/engine
var hnsw = newHNSWIndex(dimensions = 128, m = 16, efConstruction = 200)
```

### IVF-PQ

```nim
var ivfpq = newIVFPQIndex(dimensions = 128, numCentroids = 256, subQuantizers = 8)
```

## Native Nim API

```nim
import barabadb/vector/engine

var idx = newHNSWIndex(dimensions = 128)
idx.insert(1, @[1.0'f32, 0.0'f32, ...], {"category": "A"}.toTable)

let results = idx.search(queryVector, k = 10)
let filtered = idx.searchWithFilter(queryVector, k = 10,
  filter = proc(meta: Table[string, string]): bool = return "category" in meta)
```
