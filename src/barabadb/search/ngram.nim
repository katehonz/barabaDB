import std/tables
import std/sets
import std/strutils
import std/algorithm
import std/locks
import std/math

type
  PostingEntry* = object
    docId*: uint64
    termFreq*: int
    positions*: seq[int]

  SearchResult* = object
    docId*: uint64
    score*: float64
    highlights*: seq[(int, int)]

  NGramIndex* = ref object
    n*: int
    ngramToTerms*: Table[string, HashSet[string]]
    termFreqs*: Table[string, int]
    lock*: Lock

  FuzzyCandidate* = object
    term*: string
    distance*: int
    score*: float64

proc levenshtein(a, b: string): int =
  let m = a.len
  let n = b.len
  if m == 0: return n
  if n == 0: return m
  var prev = newSeq[int](n + 1)
  var curr = newSeq[int](n + 1)
  for j in 0..n:
    prev[j] = j
  for i in 1..m:
    curr[0] = i
    for j in 1..n:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      curr[j] = min(prev[j] + 1, min(curr[j - 1] + 1, prev[j - 1] + cost))
    swap(prev, curr)
  result = prev[n]

proc generateNgrams(s: string, n: int): seq[string] =
  result = @[]
  if s.len < n:
    result.add(s)
    return
  for i in 0..(s.len - n):
    result.add(s[i..<(i + n)])

proc newNGramIndex*(n: int = 3): NGramIndex =
  result = NGramIndex(
    n: n,
    ngramToTerms: initTable[string, HashSet[string]](),
    termFreqs: initTable[string, int](),
  )
  initLock(result.lock)

proc addTerm*(idx: NGramIndex, term: string, freq: int = 1) =
  acquire(idx.lock)
  try:
    if term in idx.termFreqs:
      idx.termFreqs[term] += freq
    else:
      idx.termFreqs[term] = freq
      let ngrams = generateNgrams(term, idx.n)
      for ng in ngrams:
        if ng notin idx.ngramToTerms:
          idx.ngramToTerms[ng] = initHashSet[string]()
        idx.ngramToTerms[ng].incl(term)
  finally:
    release(idx.lock)

proc removeTerm*(idx: NGramIndex, term: string) =
  acquire(idx.lock)
  try:
    if term notin idx.termFreqs:
      return
    idx.termFreqs.del(term)
    let ngrams = generateNgrams(term, idx.n)
    for ng in ngrams:
      if ng in idx.ngramToTerms:
        idx.ngramToTerms[ng].excl(term)
        if idx.ngramToTerms[ng].len == 0:
          idx.ngramToTerms.del(ng)
  finally:
    release(idx.lock)

proc buildFromSegment*(idx: NGramIndex, postings: Table[string, seq[PostingEntry]]) =
  acquire(idx.lock)
  try:
    idx.ngramToTerms.clear()
    idx.termFreqs.clear()
    for term, entries in postings:
      var totalFreq = 0
      for e in entries:
        totalFreq += e.termFreq
      idx.termFreqs[term] = totalFreq
      let ngrams = generateNgrams(term, idx.n)
      for ng in ngrams:
        if ng notin idx.ngramToTerms:
          idx.ngramToTerms[ng] = initHashSet[string]()
        idx.ngramToTerms[ng].incl(term)
  finally:
    release(idx.lock)

proc fuzzyCandidates*(idx: NGramIndex, query: string, maxDistance: int = 2): seq[FuzzyCandidate] =
  acquire(idx.lock)
  try:
    result = @[]
    if query.len == 0:
      return

    let queryNgrams = generateNgrams(query, idx.n)
    if queryNgrams.len == 0:
      return

    var candidateCounts = initTable[string, int]()
    for ng in queryNgrams:
      if ng in idx.ngramToTerms:
        for term in idx.ngramToTerms[ng]:
          if term notin candidateCounts:
            candidateCounts[term] = 0
          candidateCounts[term] += 1

    let queryNgramCount = queryNgrams.len
    var candidates: seq[FuzzyCandidate] = @[]

    for term, overlap in candidateCounts:
      let termNgramCount = max(term.len - idx.n + 1, 1)
      let unionSize = queryNgramCount + termNgramCount - overlap
      if unionSize == 0:
        continue
      let jaccard = float64(overlap) / float64(unionSize)
      let lenDiff = abs(term.len - query.len)
      if lenDiff > maxDistance:
        continue
      if jaccard < 0.1:
        continue
      let dist = levenshtein(query, term)
      if dist <= maxDistance:
        let simScore = 1.0 - float64(dist) / float64(max(query.len, term.len))
        let freq = idx.termFreqs.getOrDefault(term, 1)
        let score = simScore * ln(float64(freq) + 1.0)
        candidates.add(FuzzyCandidate(term: term, distance: dist, score: score))

    candidates.sort(proc(a, b: FuzzyCandidate): int =
      if a.distance != b.distance:
        return cmp(a.distance, b.distance)
      return cmp(b.score, a.score)
    )
    result = candidates
  finally:
    release(idx.lock)

proc fuzzySearchFast*(idx: NGramIndex, docPostings: Table[string, seq[PostingEntry]],
                      query: string, maxDistance: int = 2, limit: int = 10): seq[SearchResult] =
  let candidates = idx.fuzzyCandidates(query, maxDistance)
  if candidates.len == 0:
    return @[]

  var docScores = initTable[uint64, float64]()
  for cand in candidates:
    if cand.term notin docPostings:
      continue
    for entry in docPostings[cand.term]:
      if entry.docId notin docScores:
        docScores[entry.docId] = 0.0
      docScores[entry.docId] += cand.score * float64(entry.termFreq)

  result = @[]
  for docId, score in docScores:
    result.add(SearchResult(docId: docId, score: score, highlights: @[]))

  result.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
  if result.len > limit:
    result = result[0..<limit]

proc prefixSearch*(idx: NGramIndex, prefix: string, limit: int = 10): seq[FuzzyCandidate] =
  acquire(idx.lock)
  try:
    result = @[]
    if prefix.len == 0:
      return

    var matched = initHashSet[string]()
    if prefix.len >= idx.n:
      let prefixNgrams = generateNgrams(prefix, idx.n)
      if prefixNgrams.len > 0:
        let firstNg = prefixNgrams[0]
        if firstNg in idx.ngramToTerms:
          for term in idx.ngramToTerms[firstNg]:
            if term.startsWith(prefix):
              matched.incl(term)
    else:
      for term in idx.termFreqs.keys:
        if term.startsWith(prefix):
          matched.incl(term)

    var candidates: seq[FuzzyCandidate] = @[]
    for term in matched:
      let freq = idx.termFreqs.getOrDefault(term, 1)
      let score = ln(float64(freq) + 1.0)
      candidates.add(FuzzyCandidate(term: term, distance: 0, score: score))

    candidates.sort(proc(a, b: FuzzyCandidate): int = cmp(b.score, a.score))
    if candidates.len > limit:
      candidates = candidates[0..<limit]
    result = candidates
  finally:
    release(idx.lock)

proc wildcardMatch(term: string, pattern: string): bool =
  let parts = pattern.split('*')
  if parts.len == 1:
    return term == pattern

  var pos = 0

  if parts[0].len > 0:
    if not term.startsWith(parts[0]):
      return false
    pos = parts[0].len

  for i in 1..<(parts.len - 1):
    let part = parts[i]
    if part.len == 0:
      continue
    let found = term.find(part, pos)
    if found < 0:
      return false
    pos = found + part.len

  let last = parts[^1]
  if last.len > 0:
    if not term.endsWith(last):
      return false
    let endStart = term.len - last.len
    if endStart < pos:
      return false

  return true

proc wildcardSearch*(idx: NGramIndex, pattern: string, limit: int = 10): seq[FuzzyCandidate] =
  acquire(idx.lock)
  try:
    result = @[]
    if pattern.len == 0:
      return

    let parts = pattern.split('*')
    var fixedPart = ""
    for p in parts:
      if p.len > fixedPart.len:
        fixedPart = p

    var candidates: seq[FuzzyCandidate] = @[]

    if fixedPart.len >= idx.n:
      let fixedNgrams = generateNgrams(fixedPart, idx.n)
      var termCandidates = initHashSet[string]()
      if fixedNgrams.len > 0:
        let firstNg = fixedNgrams[0]
        if firstNg in idx.ngramToTerms:
          for term in idx.ngramToTerms[firstNg]:
            termCandidates.incl(term)

      for term in termCandidates:
        if wildcardMatch(term, pattern):
          let freq = idx.termFreqs.getOrDefault(term, 1)
          let score = ln(float64(freq) + 1.0)
          candidates.add(FuzzyCandidate(term: term, distance: 0, score: score))
    else:
      for term in idx.termFreqs.keys:
        if wildcardMatch(term, pattern):
          let freq = idx.termFreqs.getOrDefault(term, 1)
          let score = ln(float64(freq) + 1.0)
          candidates.add(FuzzyCandidate(term: term, distance: 0, score: score))

    candidates.sort(proc(a, b: FuzzyCandidate): int = cmp(b.score, a.score))
    if candidates.len > limit:
      candidates = candidates[0..<limit]
    result = candidates
  finally:
    release(idx.lock)
