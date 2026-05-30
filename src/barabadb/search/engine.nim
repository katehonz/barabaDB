import std/tables
import std/sets
import std/locks
import std/math
import std/algorithm

import inverted
import phrase
import boolean as boolmod
import ngram
import stemmer
import facet
import hnsw_opt
import ../vector/engine as vengine
import ../fts/multilang
import ../fts/engine as ftsengine

type
  SearchConfig* = object
    language*: Language
    maxSegmentSize*: int
    fieldBoosts*: Table[string, float64]
    ngramSize*: int
    enableFacets*: bool

  SearchResult* = object
    docId*: uint64
    score*: float64
    highlights*: seq[(int, int)]

  UnifiedSearchEngine* = ref object
    fts*: SegmentIndex
    ngrams*: NGramIndex
    facets*: FacetIndex
    vectorIdx*: vengine.HNSWIndex
    config*: SearchConfig
    stemmerFn*: Stemmer2
    lock*: Lock

proc defaultSearchConfig*(): SearchConfig =
  SearchConfig(
    language: langEnglish,
    maxSegmentSize: 50_000,
    fieldBoosts: initTable[string, float64](),
    ngramSize: 3,
    enableFacets: true,
  )

proc newUnifiedSearchEngine*(config: SearchConfig = defaultSearchConfig()): UnifiedSearchEngine =
  let segIdx = newSegmentIndex(config.maxSegmentSize)
  segIdx.langConfig = getLanguageConfig(config.language)
  segIdx.fieldBoosts = config.fieldBoosts

  result = UnifiedSearchEngine(
    fts: segIdx,
    ngrams: newNGramIndex(config.ngramSize),
    facets: newFacetIndex(),
    vectorIdx: vengine.newHNSWIndex(128),
    config: config,
    stemmerFn: getStemmer2(config.language),
  )
  initLock(result.lock)

proc toNgramPosting(seg: Segment): Table[string, seq[ngram.PostingEntry]] =
  result = initTable[string, seq[ngram.PostingEntry]]()
  for term, entries in seg.postings:
    var converted: seq[ngram.PostingEntry] = @[]
    for entry in entries:
      converted.add(ngram.PostingEntry(
        docId: entry.docId,
        termFreq: entry.termFreq,
        positions: entry.positions,
      ))
    result[term] = converted

proc toBoolPosting(idx: SegmentIndex): Table[string, seq[boolmod.PostingEntry]] =
  result = initTable[string, seq[boolmod.PostingEntry]]()
  for seg in idx.segments:
    for term, entries in seg.postings:
      if term notin result:
        result[term] = @[]
      for entry in entries:
        if entry.docId notin seg.deleted:
          result[term].add(boolmod.PostingEntry(
            docId: entry.docId,
            termFreq: entry.termFreq,
            positions: entry.positions,
          ))

proc indexDocument*(engine: UnifiedSearchEngine, docId: uint64, text: string,
                    fields: Table[string, string] = initTable[string, string](),
                    facets: Table[string, seq[string]] = initTable[string, seq[string]]()) =
  engine.fts.addDocument(docId, text, fields)
  if engine.config.enableFacets and facets.len > 0:
    engine.facets.addDocument(docId, facets)
  let seg = engine.fts.segments[^1]
  let nPostings = toNgramPosting(seg)
  engine.ngrams.buildFromSegment(nPostings)

proc removeDocument*(engine: UnifiedSearchEngine, docId: uint64) =
  engine.fts.removeDocument(docId)
  if engine.config.enableFacets:
    engine.facets.removeDocument(docId)

proc indexVector*(engine: UnifiedSearchEngine, id: uint64, vector: vengine.Vector,
                  metadata: Table[string, string] = initTable[string, string]()) =
  hnsw_opt.insertOpt(engine.vectorIdx, id, vector, metadata)

proc search*(engine: UnifiedSearchEngine, query: string,
             limit: int = 10): seq[SearchResult] =
  let res = engine.fts.search(query, limit)
  result = newSeq[SearchResult](res.len)
  for i, r in res:
    result[i] = SearchResult(docId: r.docId, score: r.score, highlights: r.highlights)

proc searchPhrase*(engine: UnifiedSearchEngine, terms: seq[string],
                   slop: int = 0, limit: int = 10): seq[SearchResult] =
  let pq = phrase.PhraseQuery(terms: terms, slop: slop)
  let res = phrase.phraseSearch(engine.fts, pq, limit)
  result = newSeq[SearchResult](res.len)
  for i, r in res:
    result[i] = SearchResult(docId: r.docId, score: r.score, highlights: r.highlights)

proc searchProximity*(engine: UnifiedSearchEngine, terms: seq[string],
                      maxDistance: int = 5, limit: int = 10): seq[SearchResult] =
  let res = phrase.proximitySearch(engine.fts, terms, maxDistance, limit)
  result = newSeq[SearchResult](res.len)
  for i, r in res:
    result[i] = SearchResult(docId: r.docId, score: r.score, highlights: r.highlights)

proc searchBoolean*(engine: UnifiedSearchEngine, queryStr: string,
                    limit: int = 10): seq[SearchResult] =
  let postings = toBoolPosting(engine.fts)
  var allDocLengths = initTable[uint64, int]()
  var totalDocCount = 0
  var totalTerms = 0

  for seg in engine.fts.segments:
    for docId, docLen in seg.docLengths:
      if docId notin seg.deleted:
        allDocLengths[docId] = docLen
        inc totalDocCount
        totalTerms += docLen

  let avgDocLen = if totalDocCount > 0: float64(totalTerms) / float64(totalDocCount) else: 0.0
  let res = boolmod.booleanSearch(postings, allDocLengths, totalDocCount, avgDocLen, queryStr, limit)
  result = newSeq[SearchResult](res.len)
  for i, r in res:
    result[i] = SearchResult(docId: r.docId, score: r.score, highlights: r.highlights)

proc searchFuzzy*(engine: UnifiedSearchEngine, query: string,
                  maxDistance: int = 2, limit: int = 10): seq[SearchResult] =
  var allPostings = initTable[string, seq[ngram.PostingEntry]]()
  for seg in engine.fts.segments:
    let segPostings = toNgramPosting(seg)
    for term, entries in segPostings:
      if term notin allPostings:
        allPostings[term] = @[]
      for entry in entries:
        if entry.docId notin seg.deleted:
          allPostings[term].add(entry)
  let res = ngram.fuzzySearchFast(engine.ngrams, allPostings, query, maxDistance, limit)
  result = newSeq[SearchResult](res.len)
  for i, r in res:
    result[i] = SearchResult(docId: r.docId, score: r.score, highlights: r.highlights)

proc searchPrefix*(engine: UnifiedSearchEngine, prefix: string,
                   limit: int = 10): seq[FuzzyCandidate] =
  engine.ngrams.prefixSearch(prefix, limit)

proc searchWildcard*(engine: UnifiedSearchEngine, pattern: string,
                     limit: int = 10): seq[FuzzyCandidate] =
  engine.ngrams.wildcardSearch(pattern, limit)

proc searchVector*(engine: UnifiedSearchEngine, query: vengine.Vector, k: int = 10,
                   metric: vengine.DistanceMetric = vengine.dmCosine): seq[(uint64, float64)] =
  hnsw_opt.searchOpt(engine.vectorIdx, query, k, metric)

proc searchVectorFiltered*(engine: UnifiedSearchEngine, query: vengine.Vector, k: int,
                           filter: proc(meta: Table[string, string]): bool {.gcsafe.},
                           metric: vengine.DistanceMetric = vengine.dmCosine): seq[(uint64, float64)] =
  hnsw_opt.searchWithFilterOpt(engine.vectorIdx, query, k, filter, metric)

proc hybridSearch*(engine: UnifiedSearchEngine, queryText: string, queryVec: vengine.Vector,
                   k: int = 10, textWeight: float64 = 1.0,
                   vecWeight: float64 = 1.0): seq[(uint64, float64)] =
  const rrfK = 60.0

  let ftsResults = engine.search(queryText, k * 2)
  let vecResults = if queryVec.len > 0: engine.searchVector(queryVec, k * 2) else: @[]

  var rrfScores = initTable[uint64, float64]()

  for rank, res in ftsResults:
    let score = textWeight / (rrfK + float64(rank + 1))
    rrfScores[res.docId] = rrfScores.getOrDefault(res.docId, 0.0) + score

  for rank, (id, _) in vecResults:
    let score = vecWeight / (rrfK + float64(rank + 1))
    rrfScores[id] = rrfScores.getOrDefault(id, 0.0) + score

  var results: seq[(uint64, float64)] = @[]
  for docId, score in rrfScores:
    results.add((docId, score))

  results.sort(proc(a, b: (uint64, float64)): int = cmp(b[1], a[1]))
  if results.len > k:
    results = results[0..<k]
  return results

proc getFacetCounts*(engine: UnifiedSearchEngine, field: string,
                     candidateDocs: HashSet[uint64] = initHashSet[uint64](),
                     limit: int = 10): seq[FacetCount] =
  engine.facets.getFacetCounts(field, candidateDocs, limit)

proc filterByFacets*(engine: UnifiedSearchEngine, filters: seq[FacetFilter]): HashSet[uint64] =
  engine.facets.filterByFacets(filters)

proc compact*(engine: UnifiedSearchEngine) =
  engine.fts.compact()
  for seg in engine.fts.segments:
    let nPostings = toNgramPosting(seg)
    engine.ngrams.buildFromSegment(nPostings)

proc setFieldBoost*(engine: UnifiedSearchEngine, field: string, boost: float64) =
  engine.fts.fieldBoosts[field] = boost
  engine.config.fieldBoosts[field] = boost

proc setLanguage*(engine: UnifiedSearchEngine, lang: Language) =
  engine.config.language = lang
  engine.fts.langConfig = getLanguageConfig(lang)
  engine.stemmerFn = getStemmer2(lang)

proc documentCount*(engine: UnifiedSearchEngine): int =
  var count = 0
  for seg in engine.fts.segments:
    count += seg.docCount - seg.deleted.len
  return count

proc termCount*(engine: UnifiedSearchEngine): int =
  var terms: HashSet[string]
  for seg in engine.fts.segments:
    for term in seg.postings.keys:
      terms.incl(term)
  return terms.len
