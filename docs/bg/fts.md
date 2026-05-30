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
| Фразово търсене | Точно съвпадение на фраза с поддръжка на slop |
| Proximity търсене | Термини в рамките на конфигурируемо разстояние |
| Булево | AND, OR, NOT оператори с вложени изрази |
| Фасетно търсене | Филтриране по категории, бройки и агрегация |
| Хибридно търсене | Комбинирано пълнотекстово + векторно (HNSW) с RRF сливане |
| Сегментно индексиране | Инкрементално индексиране с автоматично уплътняване |
| Полетно усилване | Тегла за релевантност по поле |

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

## Разширено Търсене

Новият модул `src/barabadb/search/` предоставя унифицирана търсачка със сегментно-базирано индексиране за високопроизводителни операции за търсене.

### UnifiedSearchEngine

```nim
import barabadb/search/engine

# Създаване на търсачка с конфигурация по подразбиране
var engine = newUnifiedSearchEngine()

# Индексиране на документи с полета и фасети
engine.indexDocument(
  docId = 1,
  text = "Nim е бърз програмен език",
  fields = {"title": "Преглед на Nim"}.toTable,
  facets = {"category": @["програмиране"], "level": @["начинаещо"]}.toTable
)

# Основно търсене
let results = engine.search("програмен език", limit = 10)

# Фразово търсене (точно съвпадение на фраза)
let phrase = engine.searchPhrase(@["бърз", "програмен"], slop = 0)

# Proximity търсене (термини в рамките на разстояние)
let proximity = engine.searchProximity(@["бърз", "език"], maxDistance = 5)

# Булеви заявки
let boolResults = engine.searchBoolean("програмиране AND (бърз OR ефективен)")
let boolResults2 = engine.searchBoolean("Nim AND NOT Python")
let boolResults3 = engine.searchBoolean("\"точна фраза\" OR wildcard*")

# Fuzzy търсене с толеранс на печатни грешки
let fuzzy = engine.searchFuzzy("програмиране", maxDistance = 2)

# Търсене по префикс и wildcard
let prefix = engine.searchPrefix("прог", limit = 10)
let wildcard = engine.searchWildcard("прог*", limit = 10)
```

### Фасетно Търсене

```nim
import barabadb/search/engine
import std/sets

# Индексиране на документи с фасети
engine.indexDocument(
  docId = 1,
  text = "Nim урок",
  facets = {"category": @["програмиране", "урок"], "difficulty": @["начинаещо"]}.toTable
)

# Получаване на бройки по фасети
let counts = engine.getFacetCounts("category", limit = 10)
for count in counts:
  echo count.value, ": ", count.count

# Филтриране по фасети
var filters = @[
  FacetFilter(field: "category", values: @["програмиране"], exclude: false),
  FacetFilter(field: "difficulty", values: @["напреднало"], exclude: true)
]
let matchingDocs = engine.filterByFacets(filters)

# Агрегация на множество фасети
let agg = engine.facets.aggregate(@["category", "difficulty"], matchingDocs)
```

### Хибридно Търсене (Текст + Вектор)

```nim
import barabadb/search/engine
import barabadb/vector/engine

# Индексиране на вектори
engine.indexVector(1, @[0.1, 0.2, 0.3], {"title": "Документ 1"}.toTable)

# Хибридно търсене комбиниращо текст и векторна сходност
let hybrid = engine.hybridSearch(
  queryText = "програмиране",
  queryVec = @[0.1, 0.2, 0.3],
  k = 10,
  textWeight = 1.0,
  vecWeight = 1.0
)

# Филтрирано векторно търсене
proc filterMeta(meta: Table[string, string]): bool =
  meta.getOrDefault("category") == "програмиране"

let filtered = engine.searchVectorFiltered(@[0.1, 0.2, 0.3], k = 10, filterMeta)
```

### Конфигурация и Управление

```nim
# Персонализирана конфигурация
var config = defaultSearchConfig()
config.language = langBulgarian
config.maxSegmentSize = 100_000
config.ngramSize = 3
config.enableFacets = true

var engine = newUnifiedSearchEngine(config)

# Задаване на полетно усилване за настройка на релевантността
engine.setFieldBoost("title", 2.0)
engine.setFieldBoost("body", 1.0)

# Смяна на езика
engine.setLanguage(langBulgarian)

# Уплътняване на сегменти за по-добра производителност
engine.compact()

# Получаване на статистика
echo "Документи: ", engine.documentCount()
echo "Термини: ", engine.termCount()

# Премахване на документи
engine.removeDocument(1)
```
