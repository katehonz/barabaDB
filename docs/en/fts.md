# Full-Text Search Engine

Inverted index with BM25 and TF-IDF ranking for text search.

## Usage

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

# BM25 search
let results = idx.search("programming language")

# TF-IDF search
let tfidf = idx.searchTfidf("programming language")

# Fuzzy search (typo tolerance)
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)

# Wildcard search
let wild = idx.regexSearch("prog*")
```

## Ranking Methods

### BM25

Best matching ranking algorithm:

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

Term Frequency-Inverse Document Frequency:

```nim
let tfidf = idx.searchTfidf("query terms")
```

## Search Features

| Feature | Description |
|---------|-------------|
| Fuzzy search | Levenshtein distance tolerance |
| Wildcard | Prefix, suffix, and infix wildcards |
| Regex | Regular expression patterns |
| Phrase search | Exact phrase matching with slop support |
| Proximity search | Terms within a configurable distance window |
| Boolean | AND, OR, NOT operators with nested expressions |
| Faceted search | Category filtering, counts, and aggregation |
| Hybrid search | Combined full-text + vector (HNSW) with RRF fusion |
| Segment indexing | Incremental indexing with automatic compaction |
| Field boosting | Per-field relevance weights |

## SQL Interface

Full-text search is also available directly in BaraQL:

```sql
-- Create a table with text column
CREATE TABLE articles (id INT PRIMARY KEY, title TEXT, body TEXT);

-- Create an FTS index
CREATE INDEX idx_fts ON articles(body) USING FTS;

-- Search with the @@ operator (BM25 ranking)
SELECT * FROM articles WHERE body @@ 'machine learning';

-- Search with multiple terms
SELECT * FROM articles WHERE body @@ 'quick brown fox';
```

## Multi-Language Support

```nim
import barabadb/fts/multilang

# Supported languages: EN, BG, DE, FR, RU
var tokenizer = newTokenizer("bg")  # Bulgarian
let tokens = tokenizer.tokenize("Търсене в пълен текст")
```

Features per language:
- Tokenization
- Stop words
- Stemming
- Language detection

## Advanced Search

The new `src/barabadb/search/` module provides a unified search engine with segment-based indexing for high-performance search operations.

### UnifiedSearchEngine

```nim
import barabadb/search/engine

# Create search engine with default configuration
var engine = newUnifiedSearchEngine()

# Index documents with fields and facets
engine.indexDocument(
  docId = 1,
  text = "Nim is a fast programming language",
  fields = {"title": "Nim Overview"}.toTable,
  facets = {"category": @["programming"], "level": @["beginner"]}.toTable
)

# Basic search
let results = engine.search("programming language", limit = 10)

# Phrase search (exact phrase matching)
let phrase = engine.searchPhrase(@["fast", "programming"], slop = 0)

# Proximity search (terms within distance)
let proximity = engine.searchProximity(@["fast", "language"], maxDistance = 5)

# Boolean queries
let boolResults = engine.searchBoolean("programming AND (fast OR efficient)")
let boolResults2 = engine.searchBoolean("Nim AND NOT Python")
let boolResults3 = engine.searchBoolean("\"exact phrase\" OR wildcard*")

# Fuzzy search with typo tolerance
let fuzzy = engine.searchFuzzy("programing", maxDistance = 2)

# Prefix and wildcard search
let prefix = engine.searchPrefix("prog", limit = 10)
let wildcard = engine.searchWildcard("prog*", limit = 10)
```

### Faceted Search

```nim
import barabadb/search/engine
import std/sets

# Index documents with facets
engine.indexDocument(
  docId = 1,
  text = "Nim tutorial",
  facets = {"category": @["programming", "tutorial"], "difficulty": @["beginner"]}.toTable
)

# Get facet counts
let counts = engine.getFacetCounts("category", limit = 10)
for count in counts:
  echo count.value, ": ", count.count

# Filter by facets
var filters = @[
  FacetFilter(field: "category", values: @["programming"], exclude: false),
  FacetFilter(field: "difficulty", values: @["advanced"], exclude: true)
]
let matchingDocs = engine.filterByFacets(filters)

# Aggregate multiple facets
let agg = engine.facets.aggregate(@["category", "difficulty"], matchingDocs)
```

### Hybrid Search (Text + Vector)

```nim
import barabadb/search/engine
import barabadb/vector/engine

# Index vectors
engine.indexVector(1, @[0.1, 0.2, 0.3], {"title": "Doc 1"}.toTable)

# Hybrid search combining text and vector similarity
let hybrid = engine.hybridSearch(
  queryText = "programming",
  queryVec = @[0.1, 0.2, 0.3],
  k = 10,
  textWeight = 1.0,
  vecWeight = 1.0
)

# Filtered vector search
proc filterMeta(meta: Table[string, string]): bool =
  meta.getOrDefault("category") == "programming"

let filtered = engine.searchVectorFiltered(@[0.1, 0.2, 0.3], k = 10, filterMeta)
```

### Configuration and Management

```nim
# Custom configuration
var config = defaultSearchConfig()
config.language = langBulgarian
config.maxSegmentSize = 100_000
config.ngramSize = 3
config.enableFacets = true

var engine = newUnifiedSearchEngine(config)

# Set field boosts for relevance tuning
engine.setFieldBoost("title", 2.0)
engine.setFieldBoost("body", 1.0)

# Change language
engine.setLanguage(langBulgarian)

# Compact segments for better performance
engine.compact()

# Get statistics
echo "Documents: ", engine.documentCount()
echo "Terms: ", engine.termCount()

# Remove documents
engine.removeDocument(1)
```