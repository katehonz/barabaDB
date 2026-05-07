# موتور جستجوی تمام‌متن

اندیس معکوس با رتبه‌بندی BM25 و TF-IDF.

## استفاده

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

let results = idx.search("programming language")
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)
```

## روش‌های رتبه‌بندی

### BM25

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

```nim
let tfidf = idx.searchTfidf("query terms")
```

## ویژگی‌های جستجو

| ویژگی | توضیح |
|--------|--------|
| Fuzzy search | تساهل فاصله Levenshtein |
| Wildcard | پیشوند، پسوند، میانوند |
| Regex | الگوهای regular |
| Phrase search | تطبیق عبارت دقیق |
| Boolean | عملگرهای AND, OR, NOT |

## رابط SQL

```sql
CREATE INDEX idx_fts ON articles(body) USING FTS;
SELECT * FROM articles WHERE body @@ 'machine learning';
```