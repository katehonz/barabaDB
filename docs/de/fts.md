# Volltextsuchmaschine

Invertierter Index mit BM25 und TF-IDF-Ranking für Textsuche.

## Verwendung

```nim
import barabadb/fts/engine

var idx = newInvertedIndex()
idx.addDocument(1, "Nim is a fast programming language")
idx.addDocument(2, "Python is popular for data science")

# BM25-Suche
let results = idx.search("programming language")

# TF-IDF-Suche
let tfidf = idx.searchTfidf("programming language")

# Fuzzy-Suche (Tippfehlertoleranz)
let fuzzy = idx.fuzzySearch("programing", maxDistance = 2)

# Platzhalter-Suche
let wild = idx.regexSearch("prog*")
```

## Ranking-Methoden

### BM25

Best-Matching-Ranking-Algorithmus:

```nim
let bm25 = idx.searchBM25("query terms")
```

### TF-IDF

Term Frequency-Inverse Document Frequency:

```nim
let tfidf = idx.searchTfidf("query terms")
```

## Suchfunktionen

| Funktion | Beschreibung |
|---------|-------------|
| Fuzzy-Suche | Levenshtein-Distanz-Toleranz |
| Platzhalter | Präfix-, Suffix- und Infix-Platzhalter |
| Regex | Reguläre Ausdrucksmuster |
| Phrasensuche | Exakte Phrasenübereinstimmung |
| Boolesch | AND, OR, NOT Operatoren |

## SQL-Schnittstelle

Volltextsuche ist auch direkt in BaraQL verfügbar:

```sql
-- Tabelle mit Textspalte erstellen
CREATE TABLE articles (id INT PRIMARY KEY, title TEXT, body TEXT);

-- FTS-Index erstellen
CREATE INDEX idx_fts ON articles(body) USING FTS;

-- Suche mit dem @@ Operator (BM25-Ranking)
SELECT * FROM articles WHERE body @@ 'machine learning';

-- Suche mit mehreren Begriffen
SELECT * FROM articles WHERE body @@ 'quick brown fox';
```

## Mehrsprachige Unterstützung

```nim
import barabadb/fts/multilang

# Unterstützte Sprachen: EN, BG, DE, FR, RU
var tokenizer = newTokenizer("de")  # Deutsch
let tokens = tokenizer.tokenize("Volltextsuche")
```

Funktionen pro Sprache:
- Tokenisierung
- Stoppwörter
- Stemming
- Spracherkennung
