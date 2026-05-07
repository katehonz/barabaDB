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
| Phrase search | Exact phrase matching |
| Boolean | AND, OR, NOT operators |

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