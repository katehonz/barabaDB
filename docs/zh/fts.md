# 全文搜索引擎

具有 BM25 和 TF-IDF 排名的倒排索引。

## 用法

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

let results = idx.search("programming language")
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)
```

## 排名方法

### BM25

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

```nim
let tfidf = idx.searchTfidf("query terms")
```

## 搜索功能

| 功能 | 描述 |
|------|------|
| Fuzzy search | 允许拼写错误（Levenshtein 距离） |
| Wildcard | 前缀、后缀和中间通配符 |
| Regex | 正则表达式模式 |
| Phrase search | 精确短语匹配 |
| Boolean | AND、OR、NOT 运算符 |

## SQL 接口

```sql
CREATE INDEX idx_fts ON articles(body) USING FTS;
SELECT * FROM articles WHERE body @@ 'machine learning';
```