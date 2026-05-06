# Пълнотекстово Търсене

Инвертиран индекс с BM25 и TF-IDF ранжиране.

## Употреба

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim е бърз език за програмиране")
idx.addDocument(2, "Python е популярен за data science")

let results = idx.search("език програмиране")
let tfidf = idx.searchTfidf("език")
let fuzzy = idx.fuzzySearch("програмиране", maxDistance = 2)
```

## Методи за Ранжиране

### BM25

Най-добрият алгоритъм за съвпадение

### TF-IDF

Term Frequency-Inverse Document Frequency

## Търсене

| Тип | Описание |
|-----|----------|
| Fuzzy | Толерантност към правописни грешки |
| Wildcard | Префикс, суфикс, и инфикс заместващи символи |
| Regex | Регулярни изрази |