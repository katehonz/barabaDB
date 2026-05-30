import std/tables
import std/sets
import std/math
import std/algorithm
import std/locks

from ../fts/engine import PostingEntry
import ../fts/multilang

type
  SearchResult* = object
    docId*: uint64
    score*: float64
    highlights*: seq[(int, int)]

  FieldBoost* = object
    fieldName*: string
    boost*: float64

  Segment* = ref object
    id*: int
    postings*: Table[string, seq[PostingEntry]]
    docLengths*: Table[uint64, int]
    docFields*: Table[uint64, Table[string, string]]
    docFieldTerms*: Table[uint64, Table[string, HashSet[string]]]
    docCount*: int
    avgDocLen*: float64
    totalTerms*: int
    deleted*: HashSet[uint64]

  SegmentIndex* = ref object
    segments*: seq[Segment]
    fieldBoosts*: Table[string, float64]
    nextSegmentId*: int
    maxSegmentSize*: int
    langConfig*: LanguageConfig
    lock*: Lock

proc newSegment*(id: int): Segment =
  Segment(
    id: id,
    postings: initTable[string, seq[PostingEntry]](),
    docLengths: initTable[uint64, int](),
    docFields: initTable[uint64, Table[string, string]](),
    docFieldTerms: initTable[uint64, Table[string, HashSet[string]]](),
    docCount: 0,
    avgDocLen: 0.0,
    totalTerms: 0,
    deleted: initHashSet[uint64](),
  )

proc newSegmentIndex*(maxSegmentSize: int = 50_000): SegmentIndex =
  result = SegmentIndex(
    segments: @[newSegment(0)],
    fieldBoosts: initTable[string, float64](),
    nextSegmentId: 1,
    maxSegmentSize: maxSegmentSize,
    langConfig: getLanguageConfig(langEnglish),
  )
  initLock(result.lock)

proc addDocumentToSegment(seg: Segment, docId: uint64, tokens: seq[string],
                          fields: Table[string, string], langConfig: LanguageConfig) =
  var termFreqs = initTable[string, int]()
  var positions = initTable[string, seq[int]]()

  for i, token in tokens:
    if token notin termFreqs:
      termFreqs[token] = 0
      positions[token] = @[]
    inc termFreqs[token]
    positions[token].add(i)

  for term, freq in termFreqs:
    if term notin seg.postings:
      seg.postings[term] = @[]
    seg.postings[term].add(PostingEntry(
      docId: docId,
      termFreq: freq,
      positions: positions[term],
    ))

  seg.docLengths[docId] = tokens.len
  inc seg.docCount
  seg.totalTerms += tokens.len
  if seg.docCount > 0:
    seg.avgDocLen = float64(seg.totalTerms) / float64(seg.docCount)

  if fields.len > 0:
    seg.docFields[docId] = fields
    var fieldTerms = initTable[string, HashSet[string]]()
    for fieldName, fieldValue in fields:
      let fieldTokens = tokenize(fieldValue, langConfig).toHashSet()
      fieldTerms[fieldName] = fieldTokens
    seg.docFieldTerms[docId] = fieldTerms

proc addDocument*(idx: SegmentIndex, docId: uint64, text: string,
                  fields: Table[string, string] = initTable[string, string]()) =
  acquire(idx.lock)
  try:
    let tokens = tokenize(text, idx.langConfig)
    var seg = idx.segments[^1]
    addDocumentToSegment(seg, docId, tokens, fields, idx.langConfig)

    if seg.docCount >= idx.maxSegmentSize:
      let newSeg = newSegment(idx.nextSegmentId)
      inc idx.nextSegmentId
      idx.segments.add(newSeg)
  finally:
    release(idx.lock)

proc removeDocument*(idx: SegmentIndex, docId: uint64) =
  acquire(idx.lock)
  try:
    for seg in idx.segments:
      if docId in seg.docLengths:
        seg.deleted.incl(docId)
        return
  finally:
    release(idx.lock)

proc bm25SegScore(seg: Segment, term: string, entry: PostingEntry,
                  k1: float64 = 1.2, b: float64 = 0.75): float64 =
  let df = seg.postings[term].len
  let n = seg.docCount
  if df == 0 or n == 0:
    return 0.0
  let idf = ln((float64(n) - float64(df) + 0.5) / (float64(df) + 0.5) + 1.0)
  let docLen = float64(seg.docLengths.getOrDefault(entry.docId, 0))
  let tfNorm = (float64(entry.termFreq) * (k1 + 1.0)) /
               (float64(entry.termFreq) + k1 * (1.0 - b + b * docLen / seg.avgDocLen))
  return idf * tfNorm

proc search*(idx: SegmentIndex, query: string, limit: int = 10): seq[SearchResult] =
  acquire(idx.lock)
  try:
    let queryTokens = tokenize(query, idx.langConfig)
    if queryTokens.len == 0:
      return @[]

    var docScores = initTable[uint64, float64]()
    var docHighlights = initTable[uint64, seq[(int, int)]]()

    for seg in idx.segments:
      for token in queryTokens:
        if token notin seg.postings:
          continue
        let postings = seg.postings[token]
        for entry in postings:
          if entry.docId in seg.deleted:
            continue
          var score = bm25SegScore(seg, token, entry)
          if score == 0.0:
            continue

          var maxBoost = 1.0
          if entry.docId in seg.docFieldTerms:
            let fieldTerms = seg.docFieldTerms[entry.docId]
            for fieldName, terms in fieldTerms:
              if token in terms:
                let boost = idx.fieldBoosts.getOrDefault(fieldName, 1.0)
                if boost > maxBoost:
                  maxBoost = boost
          score *= maxBoost

          if entry.docId notin docScores:
            docScores[entry.docId] = 0.0
            docHighlights[entry.docId] = @[]
          docScores[entry.docId] += score
          if entry.positions.len > 0:
            for pos in entry.positions:
              docHighlights[entry.docId].add((pos, pos + token.len))

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
  finally:
    release(idx.lock)

proc compact*(idx: SegmentIndex) =
  acquire(idx.lock)
  try:
    if idx.segments.len <= 1:
      for seg in idx.segments:
        if seg.deleted.len > 0:
          for docId in seg.deleted:
            seg.docLengths.del(docId)
            seg.docFields.del(docId)
            seg.docFieldTerms.del(docId)
            for term, postings in seg.postings.mpairs:
              var filtered: seq[PostingEntry] = @[]
              for entry in postings:
                if entry.docId != docId:
                  filtered.add(entry)
              postings = filtered
          seg.deleted = initHashSet[uint64]()
          seg.docCount = seg.docLengths.len
          seg.totalTerms = 0
          for dl in seg.docLengths.values:
            seg.totalTerms += dl
          if seg.docCount > 0:
            seg.avgDocLen = float64(seg.totalTerms) / float64(seg.docCount)
      return

    let merged = newSegment(idx.nextSegmentId)
    inc idx.nextSegmentId

    for seg in idx.segments:
      for docId, docLen in seg.docLengths:
        if docId in seg.deleted:
          continue
        merged.docLengths[docId] = docLen
        inc merged.docCount
        merged.totalTerms += docLen

        if docId in seg.docFields:
          merged.docFields[docId] = seg.docFields[docId]
        if docId in seg.docFieldTerms:
          merged.docFieldTerms[docId] = seg.docFieldTerms[docId]

      for term, postings in seg.postings:
        if term notin merged.postings:
          merged.postings[term] = @[]
        for entry in postings:
          if entry.docId notin seg.deleted:
            merged.postings[term].add(entry)

    if merged.docCount > 0:
      merged.avgDocLen = float64(merged.totalTerms) / float64(merged.docCount)

    idx.segments = @[merged]
  finally:
    release(idx.lock)
