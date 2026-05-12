## Full-Text Search Engine — inverted index with BM25 ranking
import std/tables
import std/strutils
import std/unicode
import std/math
import std/algorithm

type
  TermFreq* = Table[string, int]
  DocLen* = int

  PostingEntry* = object
    docId*: uint64
    termFreq*: int
    positions*: seq[int]

  InvertedIndex* = ref object
    postings*: Table[string, seq[PostingEntry]]
    docLengths*: Table[uint64, int]
    docCount*: int
    avgDocLen*: float64
    totalTerms*: int

  SearchResult* = object
    docId*: uint64
    score*: float64
    highlights*: seq[(int, int)]

  TokenizerConfig* = object
    lowercase*: bool
    removeStopWords*: bool
    stemming*: bool
    minWordLen*: int
    maxWordLen*: int

const stopWords* = [
  "a", "an", "the", "is", "it", "in", "on", "at", "to", "for",
  "of", "with", "by", "from", "as", "into", "through", "during",
  "before", "after", "above", "below", "between", "out", "off",
  "over", "under", "again", "further", "then", "once", "here",
  "there", "when", "where", "why", "how", "all", "each", "every",
  "both", "few", "more", "most", "other", "some", "such", "no",
  "nor", "not", "only", "own", "same", "so", "than", "too",
  "very", "can", "will", "just", "don", "should", "now",
  "и", "в", "на", "за", "от", "да", "се", "е", "са", "по",
  "не", "че", "с", "към", "но", "или", "ако", "при", "до",
]

proc defaultTokenizerConfig*(): TokenizerConfig =
  TokenizerConfig(
    lowercase: true,
    removeStopWords: true,
    stemming: false,
    minWordLen: 2,
    maxWordLen: 64,
  )

proc simpleStem(word: string): string =
  if word.len <= 3:
    return word
  if word.endsWith("ing"):
    return word[0..^4]
  if word.endsWith("tion"):
    return word[0..^5]
  if word.endsWith("ness"):
    return word[0..^5]
  if word.endsWith("ment"):
    return word[0..^5]
  if word.endsWith("able"):
    return word[0..^5]
  if word.endsWith("ible"):
    return word[0..^5]
  if word.endsWith("ies"):
    return word[0..^4] & "y"
  if word.endsWith("es") and word.len > 4:
    return word[0..^3]
  if word.endsWith("ed") and word.len > 4:
    return word[0..^3]
  if word.endsWith("ly") and word.len > 4:
    return word[0..^3]
  if word.endsWith("s") and not word.endsWith("ss") and word.len > 3:
    return word[0..^2]
  return word

proc tokenize*(text: string, config: TokenizerConfig = defaultTokenizerConfig()): seq[string] =
  result = @[]
  var word = ""
  for r in text.runes:
    let rStr = $r
    if r.isAlpha() or rStr == "_" or rStr == "-":
      word.add(rStr)
    else:
      if word.len > 0:
        var token = word
        if config.lowercase:
          token = token.toLower()
        if config.stemming:
          token = simpleStem(token)
        if token.len >= config.minWordLen and token.len <= config.maxWordLen:
          if not config.removeStopWords or token notin stopWords:
            result.add(token)
        word = ""
  if word.len > 0:
    var token = word
    if config.lowercase:
      token = token.toLower()
    if config.stemming:
      token = simpleStem(token)
    if token.len >= config.minWordLen and token.len <= config.maxWordLen:
      if not config.removeStopWords or token notin stopWords:
        result.add(token)

proc newInvertedIndex*(): InvertedIndex =
  InvertedIndex(
    postings: initTable[string, seq[PostingEntry]](),
    docLengths: initTable[uint64, int](),
    docCount: 0,
    avgDocLen: 0.0,
    totalTerms: 0,
  )

proc addDocument*(idx: InvertedIndex, docId: uint64, text: string,
                  config: TokenizerConfig = defaultTokenizerConfig()) =
  let tokens = tokenize(text, config)
  var termFreqs = initTable[string, int]()
  var positions = initTable[string, seq[int]]()

  for i, token in tokens:
    if token notin termFreqs:
      termFreqs[token] = 0
      positions[token] = @[]
    inc termFreqs[token]
    positions[token].add(i)

  for term, freq in termFreqs:
    if term notin idx.postings:
      idx.postings[term] = @[]
    idx.postings[term].add(PostingEntry(
      docId: docId,
      termFreq: freq,
      positions: positions[term],
    ))

  idx.docLengths[docId] = tokens.len
  inc idx.docCount
  idx.totalTerms += tokens.len
  idx.avgDocLen = float64(idx.totalTerms) / float64(idx.docCount)

proc removeDocument*(idx: InvertedIndex, docId: uint64) =
  if docId notin idx.docLengths:
    return
  let docLen = idx.docLengths[docId]
  idx.docLengths.del(docId)
  dec idx.docCount
  idx.totalTerms -= docLen
  if idx.docCount > 0:
    idx.avgDocLen = float64(idx.totalTerms) / float64(idx.docCount)

  for term, postings in idx.postings.mpairs:
    var newPostings: seq[PostingEntry] = @[]
    for entry in postings:
      if entry.docId != docId:
        newPostings.add(entry)
    postings = newPostings

proc bm25Score*(idx: InvertedIndex, term: string, docId: uint64,
                k1: float64 = 1.2, b: float64 = 0.75): float64 =
  if term notin idx.postings:
    return 0.0

  let df = idx.postings[term].len
  let n = idx.docCount
  if df == 0 or n == 0:
    return 0.0

  var tf = 0
  var found = false
  for entry in idx.postings[term]:
    if entry.docId == docId:
      tf = entry.termFreq
      found = true
      break

  if not found:
    return 0.0

  let idf = ln((float64(n) - float64(df) + 0.5) / (float64(df) + 0.5) + 1.0)
  let docLen = float64(idx.docLengths.getOrDefault(docId, 0))
  let tfNorm = (float64(tf) * (k1 + 1.0)) /
               (float64(tf) + k1 * (1.0 - b + b * docLen / idx.avgDocLen))
  return idf * tfNorm

proc search*(idx: InvertedIndex, query: string, limit: int = 10,
             config: TokenizerConfig = defaultTokenizerConfig()): seq[SearchResult] =
  let queryTokens = tokenize(query, config)
  if queryTokens.len == 0:
    return @[]

  var docScores = initTable[uint64, float64]()
  var docHighlights = initTable[uint64, seq[(int, int)]]()

  for token in queryTokens:
    if token notin idx.postings:
      continue
    for entry in idx.postings[token]:
      let score = bm25Score(idx, token, entry.docId)
      if entry.docId notin docScores:
        docScores[entry.docId] = 0.0
        docHighlights[entry.docId] = @[]
      docScores[entry.docId] += score
      for pos in entry.positions:
        let start = pos
        let stop = pos + token.len
        docHighlights[entry.docId].add((start, stop))

  var results: seq[SearchResult] = @[]
  for docId, score in docScores:
    results.add(SearchResult(
      docId: docId,
      score: score,
      highlights: docHighlights.getOrDefault(docId, @[]),
    ))

  results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))

  if results.len > limit:
    results = results[0..<limit]

  return results

proc termCount*(idx: InvertedIndex): int = idx.postings.len
proc documentCount*(idx: InvertedIndex): int = idx.docCount

# TF-IDF ranking
proc tfidfScore*(idx: InvertedIndex, term: string, docId: uint64): float64 =
  if term notin idx.postings:
    return 0.0
  let df = idx.postings[term].len
  let n = idx.docCount
  if df == 0 or n == 0:
    return 0.0

  var tf = 0
  for entry in idx.postings[term]:
    if entry.docId == docId:
      tf = entry.termFreq
      break

  let idf = ln(float64(n) / float64(df))
  return float64(tf) * idf

proc searchTfidf*(idx: InvertedIndex, query: string, limit: int = 10,
                  config: TokenizerConfig = defaultTokenizerConfig()): seq[SearchResult] =
  let queryTokens = tokenize(query, config)
  if queryTokens.len == 0:
    return @[]

  var docScores = initTable[uint64, float64]()

  for token in queryTokens:
    if token notin idx.postings:
      continue
    for entry in idx.postings[token]:
      let score = idx.tfidfScore(token, entry.docId)
      if entry.docId notin docScores:
        docScores[entry.docId] = 0.0
      docScores[entry.docId] += score

  var results: seq[SearchResult] = @[]
  for docId, score in docScores:
    results.add(SearchResult(docId: docId, score: score, highlights: @[]))

  results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
  if results.len > limit:
    results = results[0..<limit]
  return results

# Levenshtein distance for fuzzy matching
proc levenshtein*(a, b: string): int =
  let m = a.len
  let n = b.len
  var d = newSeq[seq[int]](m + 1)
  for i in 0..m:
    d[i] = newSeq[int](n + 1)
    d[i][0] = i
  for j in 0..n:
    d[0][j] = j

  for i in 1..m:
    for j in 1..n:
      let cost = if a[i-1] == b[j-1]: 0 else: 1
      d[i][j] = min(d[i-1][j] + 1, min(d[i][j-1] + 1, d[i-1][j-1] + cost))

  return d[m][n]

proc fuzzySearch*(idx: InvertedIndex, query: string, maxDistance: int = 2,
                  limit: int = 10, config: TokenizerConfig = defaultTokenizerConfig()): seq[SearchResult] =
  let queryTokens = tokenize(query, config)
  if queryTokens.len == 0:
    return @[]

  var docScores = initTable[uint64, float64]()

  for term in idx.postings.keys:
    for queryToken in queryTokens:
      let dist = levenshtein(term, queryToken)
      if dist <= maxDistance:
        let simScore = 1.0 - float64(dist) / float64(max(queryToken.len, term.len))
        for entry in idx.postings[term]:
          if entry.docId notin docScores:
            docScores[entry.docId] = 0.0
          docScores[entry.docId] += simScore * float64(entry.termFreq)

  var results: seq[SearchResult] = @[]
  for docId, score in docScores:
    results.add(SearchResult(docId: docId, score: score, highlights: @[]))

  results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
  if results.len > limit:
    results = results[0..<limit]
  return results

# Regex search
proc regexSearch*(idx: InvertedIndex, pattern: string,
                  limit: int = 10): seq[SearchResult] =
  var docScores = initTable[uint64, float64]()

  for term in idx.postings.keys:
    # Simple pattern matching: check if pattern is substring
    if pattern.len > 0:
      var match = false
      # Check if pattern starts with/ends with or contains
      if pattern.startsWith("*") and pattern.endsWith("*"):
        let inner = pattern[1..^2]
        if term.find(inner) >= 0:
          match = true
      elif pattern.startsWith("*"):
        let suffix = pattern[1..^1]
        if term.endsWith(suffix):
          match = true
      elif pattern.endsWith("*"):
        let prefix = pattern[0..^2]
        if term.startsWith(prefix):
          match = true
      else:
        if term == pattern:
          match = true

      if match:
        for entry in idx.postings[term]:
          if entry.docId notin docScores:
            docScores[entry.docId] = 0.0
          docScores[entry.docId] += float64(entry.termFreq)

  var results: seq[SearchResult] = @[]
  for docId, score in docScores:
    results.add(SearchResult(docId: docId, score: score, highlights: @[]))

  results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
  if results.len > limit:
    results = results[0..<limit]
  return results
