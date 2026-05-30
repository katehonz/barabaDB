# Unified Search Module

## Overview

The `UnifiedSearchEngine` is the main entry point for all search operations in BarabaDB. It combines multiple search capabilities into a single, cohesive API:

- **Full-Text Search (FTS)** — BM25-ranked retrieval over segmented inverted indexes.
- **Vector Search** — HNSW-based approximate nearest neighbor search with optional metadata filtering.
- **Phrase Search** — Exact or slop-aware phrase matching.
- **Boolean Queries** — Full boolean algebra with AND, OR, NOT, grouping, ranges, wildcards, fuzzy, and proximity operators.
- **Faceted Search** — Categorical filtering with per-field facet counts.
- **Fuzzy Search** — N-gram candidate generation verified by Levenshtein distance.
- **Hybrid Search** — Combines FTS and vector scores for blended retrieval.

## Installation

Add the module to your Nim project:

```nim
import barabadb/search/engine
```

No additional dependencies are required; the search module is part of the core `barabadb` package.

## Basic Usage

```nim
import barabadb/search/engine

let config = defaultSearchConfig()
var search = newUnifiedSearchEngine(config)

# Index documents
search.indexDocument(1, "The quick brown fox", {"title": "Animals"}.toTable)
search.indexDocument(2, "Lazy dog sleeps all day", {"title": "Pets"}.toTable)

# BM25 search
let results = search.search("quick fox", limit = 10)

# Phrase search
let phrases = search.searchPhrase(@["quick", "brown"], slop = 0)

# Boolean query
let boolResults = search.searchBoolean("quick AND (fox OR dog)")

# Fuzzy search
let fuzzy = search.searchFuzzy("quik", maxDistance = 2)

# Prefix search
let prefix = search.searchPrefix("quic*")

# Vector search
search.indexVector(1, @[0.1'f32, 0.2, 0.3], {"category": "A"}.toTable)
let vecResults = search.searchVector(@[0.15'f32, 0.25, 0.35], k = 10)

# Hybrid search (combines FTS + vector)
let hybrid = search.hybridSearch("fox", @[0.1'f32, 0.2, 0.3], k = 10)
```

## Advanced Features

### Faceted Search

Faceted search lets you filter results by categorical metadata and retrieve aggregated counts per facet value.

```nim
# Index with facets
search.indexDocument(1, "Nim programming book",
  fields = {"author": "John"}.toTable,
  facets = {"category": @["programming", "books"], "language": @["nim"]}.toTable)

# Filter by facets
let filters = @[FacetFilter(field: "category", values: @["programming"])]
let filteredDocs = search.filterByFacets(filters)

# Get facet counts
let counts = search.getFacetCounts("category")
```

### Field Boosting

Field boosting adjusts the relative importance of matches in different fields. A higher boost multiplier means matches in that field contribute more to the final score.

```nim
search.setFieldBoost("title", 3.0)  # Title matches 3x more important
search.setFieldBoost("author", 2.0)
```

### Multi-Language Support

The search engine ships with Porter2 stemmers for several languages. Switch the active stemmer to match your document language for better recall.

```nim
search.setLanguage(langBulgarian)  # Switch to Bulgarian stemmer
```

Supported stemmers: English (`langEnglish`), Bulgarian (`langBulgarian`), German (`langGerman`), French (`langFrench`), Russian (`langRussian`).

### Segment Management

The index is organized into segments that are merged periodically. Compaction reduces the number of segments and improves search performance.

```nim
# Compact segments for better performance
search.compact()

# Get statistics
echo "Documents: ", search.documentCount()
echo "Terms: ", search.termCount()
```

## Boolean Query Syntax

The boolean query parser supports a rich syntax for composing complex search expressions.

| Operator | Example | Description |
|----------|---------|-------------|
| AND (default) | `quick brown` | Both terms required |
| AND (explicit) | `quick AND brown` | Both terms required |
| OR | `quick OR brown` | Either term |
| NOT | `quick NOT brown` | Exclude brown |
| Phrase | `"quick brown fox"` | Exact phrase |
| Proximity | `"quick fox"~3` | Within 3 words |
| Wildcard | `quic*` | Prefix match |
| Fuzzy | `quik~2` | Max 2 edits |
| Grouping | `(quick OR slow) AND fox` | Boolean groups |
| Range | `price:[10 TO 100]` | Numeric range |

### Examples

```nim
# Simple conjunction — both terms must appear
let r1 = search.searchBoolean("database indexing")

# Disjunction with exclusion
let r2 = search.searchBoolean("search OR retrieval NOT deprecated")

# Phrase with proximity
let r3 = search.searchBoolean("\"quick fox\"~5")

# Grouped boolean with field range
let r4 = search.searchBoolean("(nim OR rust) AND performance score:[80 TO 100]")
```

## Performance Characteristics

### HNSW Vector Search

The vector index uses a Hierarchical Navigable Small World graph with heap-based `searchLayer`:

- **Speed**: 2.4x faster than linear scan on the heap-optimized path.
- **Recall@10**: 92–99% depending on dataset size and dimensionality.
- **Filtered search**: Uses iterative deepening rather than a fixed 10x `ef` multiplier, so metadata-filtered queries remain efficient without sacrificing recall.

### Segment-Based Indexing

Documents are indexed into immutable segments that are merged during compaction:

- **Auto-segmentation**: A new segment is created every 50,000 documents.
- **Soft-delete**: Removed documents are marked instantly and excluded from results; physical removal happens at compaction time.
- **Periodic compaction**: `search.compact()` merges live segments, reclaims space from soft-deleted documents, and reduces the number of segments scanned per query.

### N-gram Fuzzy Search

Fuzzy matching is a two-phase process:

1. **Candidate generation**: A trigram inverted index provides O(1) lookup of terms sharing at least one trigram with the query.
2. **Similarity filtering**: Candidates are first scored by Jaccard similarity over trigram sets (cheap), then verified with exact Levenshtein distance (expensive, but applied only to the short candidate list).

## Architecture

```
UnifiedSearchEngine
├── SegmentIndex (FTS with BM25)
│   └── Multiple segments (auto-merge)
├── NGramIndex (fuzzy/prefix/wildcard)
│   └── Trigram inverted index
├── FacetIndex (categorical filtering)
│   └── Per-field value → docId mapping
├── HNSWIndex (vector search)
│   └── Heap-optimized searchLayer
└── Porter2 Stemmers (EN/BG/DE/FR/RU)
```

Each sub-index is independently testable and can be used in isolation if only a subset of search capabilities is needed.

## Migration from FTS Engine

If you are upgrading from the standalone FTS engine, the migration is straightforward.

**Old code:**

```nim
import barabadb/fts/engine
var idx = newInvertedIndex()
idx.addDocument(1, "text")
let results = idx.search("query")
```

**New code:**

```nim
import barabadb/search/engine
var search = newUnifiedSearchEngine()
search.indexDocument(1, "text")
let results = search.search("query")
```

Key changes:

| Old API | New API | Notes |
|---------|---------|-------|
| `newInvertedIndex()` | `newUnifiedSearchEngine()` | Includes all sub-indexes |
| `addDocument(id, text)` | `indexDocument(id, text, fields, facets)` | Fields and facets are optional |
| `search(query)` | `search(query, limit)` | Limit parameter added |

The old `barabadb/fts/engine` module is deprecated and will be removed in a future release.

## Benchmark Results

Benchmarks run on a single thread, 128-dimensional vectors, HNSW parameters `M=16, efConstruction=200, efSearch=50`.

```
N=1K:   insert=0.24s  search=0.30ms  recall@10=99.6%
N=5K:   insert=2.64s  search=0.94ms  recall@10=97.8%
N=10K:  insert=6.94s  search=1.09ms  recall@10=92.6%
N=50K:  insert=70.67s search=2.26ms  recall@10=75.5%
```

- `insert` — total wall-clock time to index N documents (including vector insertion).
- `search` — mean latency per hybrid search query.
- `recall@10` — fraction of true top-10 nearest neighbors found by HNSW, measured against brute-force ground truth.
