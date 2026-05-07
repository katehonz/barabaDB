# محرك البحث النصي الكامل

فهرس مقلوب مع ترتيب BM25 و TF-IDF للبحث النصي.

## الاستخدام

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

let results = idx.search("programming language")
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)
```

## طرق الترتيب

### BM25

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

```nim
let tfidf = idx.searchTfidf("query terms")
```

## ميزات البحث

| الميزة | الوصف |
|---------|-------|
| Fuzzy search | تساهل مسافة Levenshtein |
| Wildcard | بادئة، لاحقة،wildcard中间 |
| Regex | أنماط التعبير العادي |
| Phrase search | تطابق عبارة تامة |
| Boolean | عوامل AND, OR, NOT |

## واجهة SQL

```sql
CREATE INDEX idx_fts ON articles(body) USING FTS;
SELECT * FROM articles WHERE body @@ 'machine learning';
```