# Унифициран модул за търсене

## Преглед

`UnifiedSearchEngine` е основната входна точка за всички операции по търсене в BarabaDB. Той обединява множество възможности за търсене в единен, свързан API:

- **Пълнотекстово търсене (FTS)** — извличане с BM25 класиране върху сегментирани обърнати индекси.
- **Векторно търсене** — приблизително търсене на най-близки съседи чрез HNSW с опционално филтриране по метаданни.
- **Фразово търсене** — точно или slop-толерантно съвпадение на фрази.
- **Булеви заявки** — пълна булева алгебра с AND, OR, NOT, групиране, диапазони, wildcards, fuzzy и proximity оператори.
- **Фасетно търсене** — категорично филтриране с бройки по стойности за всяко поле.
- **Нечетко търсене (Fuzzy)** — генериране на кандидати чрез N-грами, проверени с Levenshtein разстояние.
- **Хибридно търсене** — комбинира FTS и векторни резултати за смесено извличане.

## Инсталация

Добавете модула към вашия Nim проект:

```nim
import barabadb/search/engine
```

Не са необходими допълнителни зависимости; модулът за търсене е част от основния пакет `barabadb`.

## Основна употреба

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

## Разширени възможности

### Фасетно търсене

Фасетното търсене позволява филтриране на резултатите по категорични метаданни и извличане на агрегирани бройки по стойност на всеки фасет.

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

### Усилване на полета

Усилването на полета настройва относителната важност на съвпаденията в различните полета. По-висок множител означава, че съвпаденията в това поле допринасят повече за крайния резултат.

```nim
search.setFieldBoost("title", 3.0)  # Title matches 3x more important
search.setFieldBoost("author", 2.0)
```

### Поддръжка на множество езици

Модулът за търсене включва Porter2 stemmer-и за няколко езика. Сменете активния stemmer, за да съответства на езика на вашите документи и да подобрите recall-а.

```nim
search.setLanguage(langBulgarian)  # Switch to Bulgarian stemmer
```

Поддържани stemmer-и: английски (`langEnglish`), български (`langBulgarian`), немски (`langGerman`), френски (`langFrench`), руски (`langRussian`).

### Управление на сегменти

Индексът е организиран в сегменти, които периодично се сливат. Компактизирането намалява броя на сегментите и подобрява производителността на търсенето.

```nim
# Compact segments for better performance
search.compact()

# Get statistics
echo "Documents: ", search.documentCount()
echo "Terms: ", search.termCount()
```

## Синтаксис на булевите заявки

Парсерът за булеви заявки поддържа богат синтаксис за съставяне на сложни изрази за търсене.

| Оператор | Пример | Описание |
|----------|--------|----------|
| AND (по подразбиране) | `quick brown` | И двата термина са задължителни |
| AND (изричен) | `quick AND brown` | И двата термина са задължителни |
| OR | `quick OR brown` | Който и да е от термините |
| NOT | `quick NOT brown` | Изключва brown |
| Фраза | `"quick brown fox"` | Точна фраза |
| Близост | `"quick fox"~3` | В рамките на 3 думи |
| Wildcard | `quic*` | Съвпадение по префикс |
| Нечетко | `quik~2` | Максимум 2 редакции |
| Групиране | `(quick OR slow) AND fox` | Булеви групи |
| Диапазон | `price:[10 TO 100]` | Числов диапазон |

### Примери

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

## Характеристики на производителността

### HNSW векторно търсене

Векторният индекс използва Hierarchical Navigable Small World граф с heap-based `searchLayer`:

- **Скорост**: 2.4 пъти по-бързо от линейно сканиране при heap-оптимизирания път.
- **Recall@10**: 92–99% в зависимост от размера на набора от данни и размерността.
- **Филтрирано търсене**: Използва итеративно задълбочаване вместо фиксиран 10x `ef` множител, така че заявките с филтриране по метаданни остават ефективни без жертване на recall-а.

### Сегментно индексиране

Документите се индексират в непроменяеми сегменти, които се сливат при компактизиране:

- **Автоматично сегментиране**: Нов сегмент се създава на всеки 50 000 документа.
- **Софт-изтриване**: Премахнатите документи се маркират мигновено и се изключват от резултатите; физическото премахване става при компактизиране.
- **Периодично компактизиране**: `search.compact()` слива активните сегменти, възстановява пространство от софт-изтрити документи и намалява броя на сегментите, сканирани при всяка заявка.

### Нечетко търсене с N-грами

Нечеткото съвпадение е двуетапен процес:

1. **Генериране на кандидати**: Обърнат индекс от триграми осигурява O(1) достъп до термини, споделящи поне една триграма със заявката.
2. **Филтриране по сходство**: Кандидатите първо се оценяват по Jaccard сходство върху множествата от триграми (евтино), след което се проверяват с точно Levenshtein разстояние (скъпо, но приложено само върху краткия списък с кандидати).

## Архитектура

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

Всеки подиндекс е независимо тестваем и може да се използва изолирано, ако е необходимо само подмножество от възможностите за търсене.

## Миграция от FTS Engine

Ако надграждате от самостоятелния FTS engine, миграцията е проста.

**Стар код:**

```nim
import barabadb/fts/engine
var idx = newInvertedIndex()
idx.addDocument(1, "text")
let results = idx.search("query")
```

**Нов код:**

```nim
import barabadb/search/engine
var search = newUnifiedSearchEngine()
search.indexDocument(1, "text")
let results = search.search("query")
```

Ключови промени:

| Стар API | Нов API | Бележки |
|----------|---------|---------|
| `newInvertedIndex()` | `newUnifiedSearchEngine()` | Включва всички подиндекси |
| `addDocument(id, text)` | `indexDocument(id, text, fields, facets)` | Полетата и фасетите са опционални |
| `search(query)` | `search(query, limit)` | Добавен е параметър за лимит |

Старият модул `barabadb/fts/engine` е deprecated и ще бъде премахнат в бъдеща версия.

## Резултати от бенчмаркове

Бенчмарковете са изпълнени на една нишка, 128-мерни вектори, HNSW параметри `M=16, efConstruction=200, efSearch=50`.

```
N=1K:   insert=0.24s  search=0.30ms  recall@10=99.6%
N=5K:   insert=2.64s  search=0.94ms  recall@10=97.8%
N=10K:  insert=6.94s  search=1.09ms  recall@10=92.6%
N=50K:  insert=70.67s search=2.26ms  recall@10=75.5%
```

- `insert` — общо wall-clock време за индексиране на N документа (включително вмъкване на вектори).
- `search` — средна латентност на хибридна заявка за търсене.
- `recall@10` — дял на истинските топ-10 най-близки съседи, намерени от HNSW, измерен спрямо brute-force ground truth.
