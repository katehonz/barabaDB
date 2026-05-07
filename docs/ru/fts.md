# Полнотекстовый поиск

Инвертированный индекс с ранжированием BM25 и TF-IDF для текстового поиска.

## Использование

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

let results = idx.search("programming language")

let tfidf = idx.searchTfidf("programming language")

let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)

let wild = idx.regexSearch("prog*")
```

## Методы ранжирования

### BM25

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

```nim
let tfidf = idx.searchTfidf("query terms")
```

## Функции поиска

| Функция | Описание |
|---------|---------|
| Fuzzy search | Толерантность к опечаткам (расстояние Левенштейна) |
| Wildcard | Префиксные, суффиксные и инфиксные подстановки |
| Regex | Регулярные выражения |
| Phrase search | Точное совпадение фразы |
| Boolean | Операторы AND, OR, NOT |

## SQL интерфейс

```sql
CREATE TABLE articles (id INT PRIMARY KEY, title TEXT, body TEXT);
CREATE INDEX idx_fts ON articles(body) USING FTS;
SELECT * FROM articles WHERE body @@ 'machine learning';
```

## Многоязычная поддержка

```nim
import barabadb/fts/multilang

var tokenizer = newTokenizer("bg")
let tokens = tokenizer.tokenize("Търсене в пълен текст")
```