# Tam Metin Arama Motoru

BM25 ve TF-IDF sıralamasıyla ters indeks.

## Kullanım

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

let results = idx.search("programming language")
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)
```

## Sıralama Yöntemleri

### BM25

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

```nim
let tfidf = idx.searchTfidf("query terms")
```

## Arama Özellikleri

| Özellik | Açıklama |
|----------|----------|
| Fuzzy search | Levenshtein mesafesi toleransı |
| Wildcard | Önek, sonek ve ara joker |
| Regex | Normal ifade kalıpları |
| Phrase search | Tam ifade eşleme |
| Boolean | AND, OR, NOT operatörleri |

## SQL Arayüzü

```sql
CREATE INDEX idx_fts ON articles(body) USING FTS;
SELECT * FROM articles WHERE body @@ 'machine learning';
```