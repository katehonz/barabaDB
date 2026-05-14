# Full-Text Search Engine

Inverted индекс с BM25 и TF-IDF ранжиране за текстово търсене.

## Употреба

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

# BM25 търсене
let results = idx.search("programming language")

# TF-IDF търсене
let tfidf = idx.searchTfidf("programming language")

# Fuzzy търсене (толеранс на печатни грешки)
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)

# Wildcard търсене
let wild = idx.regexSearch("prog*")
```

## Методи за Ранжиране

### BM25

Best matching алгоритъм за ранжиране:

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

Term Frequency-Inverse Document Frequency:

```nim
let tfidf = idx.searchTfidf("query terms")
```

## Функции за Търсене

| Функция | Описание |
|---------|----------|
| Fuzzy търсене | Levenshtein distance толеранс |
| Wildcard | Префиксни, суфиксни и инфиксни wildcards |
| Regex | Регулярни изрази |
| Фразово търсене | Точно съвпадение на фраза |
| Булево | AND, OR, NOT оператори |

## SQL Интерфейс

Пълнотекстовото търсене е достъпно и директно в BaraQL:

```sql
-- Създаване на таблица с текстова колона
CREATE TABLE articles (id INT PRIMARY KEY, title TEXT, body TEXT);

-- Създаване на FTS индекс
CREATE INDEX idx_fts ON articles(body) USING FTS;

-- Търсене с оператора @@ (BM25 ранжиране)
SELECT * FROM articles WHERE body @@ 'machine learning';

-- Търсене с множество термини
SELECT * FROM articles WHERE body @@ 'quick brown fox';
```

## Многоезична Поддръжка

```nim
import barabadb/fts/multilang

# Поддържани езици: EN, BG, DE, FR, RU
var tokenizer = newTokenizer("bg")  # Български
let tokens = tokenizer.tokenize("Търсене в пълен текст")
```

Функции за всеки език:
- Токенизация
- Stop думи
- Стеминг
- Детекция на език
