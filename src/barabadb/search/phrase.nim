import std/tables
import std/sets
import std/algorithm
import std/math
import std/locks

from ../fts/engine import PostingEntry
import ../fts/multilang
import inverted

type
  PhraseQuery* = object
    terms*: seq[string]
    slop*: int

proc gatherPostings(idx: SegmentIndex, term: string): Table[uint64, seq[int]] =
  result = initTable[uint64, seq[int]]()
  for seg in idx.segments:
    if term notin seg.postings:
      continue
    for entry in seg.postings[term]:
      if entry.docId in seg.deleted:
        continue
      if entry.docId notin result:
        result[entry.docId] = @[]
      result[entry.docId].add(entry.positions)

proc checkPhraseMatch(positions: seq[seq[int]], slop: int): bool =
  if positions.len == 0:
    return false
  if positions.len == 1:
    return positions[0].len > 0

  for startPos in positions[0]:
    var matched = true
    var prevPos = startPos
    for i in 1..<positions.len:
      var found = false
      for candidatePos in positions[i]:
        let gap = candidatePos - prevPos
        if gap >= 1 and gap <= 1 + slop:
          prevPos = candidatePos
          found = true
          break
        elif candidatePos > prevPos + 1 + slop:
          break
      if not found:
        matched = false
        break
    if matched:
      return true
  return false

proc minProximityWindow(positions: seq[seq[int]]): int =
  if positions.len == 0:
    return int.high
  for posList in positions:
    if posList.len == 0:
      return int.high

  var pointers = newSeq[int](positions.len)
  var bestWindow = int.high

  while true:
    var lo = int.high
    var hi = int.low
    for i in 0..<positions.len:
      let p = positions[i][pointers[i]]
      if p < lo: lo = p
      if p > hi: hi = p

    let window = hi - lo
    if window < bestWindow:
      bestWindow = window

    var minIdx = 0
    for i in 1..<positions.len:
      if positions[i][pointers[i]] < positions[minIdx][pointers[minIdx]]:
        minIdx = i

    inc pointers[minIdx]
    if pointers[minIdx] >= positions[minIdx].len:
      break

  return bestWindow

proc phraseSearch*(idx: SegmentIndex, query: PhraseQuery,
                   limit: int = 10): seq[SearchResult] =
  acquire(idx.lock)
  try:
    if query.terms.len == 0:
      return @[]

    var queryTerms: seq[string] = @[]
    for term in query.terms:
      let tokenized = tokenize(term, idx.langConfig)
      for t in tokenized:
        queryTerms.add(t)

    if queryTerms.len == 0:
      return @[]

    var perTermPostings: seq[Table[uint64, seq[int]]] = @[]
    for term in queryTerms:
      perTermPostings.add(gatherPostings(idx, term))

    var candidateDocs = initHashSet[uint64]()
    if perTermPostings.len > 0:
      for docId in perTermPostings[0].keys:
        candidateDocs.incl(docId)
      for i in 1..<perTermPostings.len:
        var intersection = initHashSet[uint64]()
        for docId in candidateDocs:
          if docId in perTermPostings[i]:
            intersection.incl(docId)
        candidateDocs = intersection

    var results: seq[SearchResult] = @[]
    let phraseBonus = 2.0

    for docId in candidateDocs:
      var positions: seq[seq[int]] = @[]
      for i in 0..<perTermPostings.len:
        var sorted = perTermPostings[i][docId]
        sorted.sort()
        positions.add(sorted)

      if not checkPhraseMatch(positions, query.slop):
        continue

      var score = 0.0
      for seg in idx.segments:
        if docId in seg.deleted:
          continue
        for term in queryTerms:
          if term notin seg.postings:
            continue
          for entry in seg.postings[term]:
            if entry.docId == docId:
              let df = seg.postings[term].len
              let n = seg.docCount
              if df > 0 and n > 0:
                let idf = ln((float64(n) - float64(df) + 0.5) /
                             (float64(df) + 0.5) + 1.0)
                let docLen = float64(seg.docLengths.getOrDefault(docId, 0))
                let tfNorm = (float64(entry.termFreq) * (1.2 + 1.0)) /
                             (float64(entry.termFreq) +
                              1.2 * (1.0 - 0.75 + 0.75 * docLen / seg.avgDocLen))
                score += idf * tfNorm
              break

      score *= phraseBonus

      var highlights: seq[(int, int)] = @[]
      if positions.len > 0 and positions[0].len > 0:
        let start = positions[0][0]
        let endPos = positions[^1][^1]
        highlights.add((start, endPos + 1))

      results.add(SearchResult(
        docId: docId,
        score: score,
        highlights: highlights,
      ))

    results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
    if results.len > limit:
      results = results[0..<limit]
    return results
  finally:
    release(idx.lock)

proc proximitySearch*(idx: SegmentIndex, terms: seq[string], maxDistance: int,
                      limit: int = 10): seq[SearchResult] =
  acquire(idx.lock)
  try:
    if terms.len == 0:
      return @[]

    var queryTerms: seq[string] = @[]
    for term in terms:
      let tokenized = tokenize(term, idx.langConfig)
      for t in tokenized:
        queryTerms.add(t)

    if queryTerms.len == 0:
      return @[]

    var perTermPostings: seq[Table[uint64, seq[int]]] = @[]
    for term in queryTerms:
      perTermPostings.add(gatherPostings(idx, term))

    var candidateDocs = initHashSet[uint64]()
    if perTermPostings.len > 0:
      for docId in perTermPostings[0].keys:
        candidateDocs.incl(docId)
      for i in 1..<perTermPostings.len:
        var intersection = initHashSet[uint64]()
        for docId in candidateDocs:
          if docId in perTermPostings[i]:
            intersection.incl(docId)
        candidateDocs = intersection

    var results: seq[SearchResult] = @[]

    for docId in candidateDocs:
      var positions: seq[seq[int]] = @[]
      for i in 0..<perTermPostings.len:
        var sorted = perTermPostings[i][docId]
        sorted.sort()
        positions.add(sorted)

      let window = minProximityWindow(positions)
      if window > maxDistance:
        continue

      var score = 0.0
      for seg in idx.segments:
        if docId in seg.deleted:
          continue
        for term in queryTerms:
          if term notin seg.postings:
            continue
          for entry in seg.postings[term]:
            if entry.docId == docId:
              let df = seg.postings[term].len
              let n = seg.docCount
              if df > 0 and n > 0:
                let idf = ln((float64(n) - float64(df) + 0.5) /
                             (float64(df) + 0.5) + 1.0)
                let docLen = float64(seg.docLengths.getOrDefault(docId, 0))
                let tfNorm = (float64(entry.termFreq) * (1.2 + 1.0)) /
                             (float64(entry.termFreq) +
                              1.2 * (1.0 - 0.75 + 0.75 * docLen / seg.avgDocLen))
                score += idf * tfNorm
              break

      let proximityBonus = float64(maxDistance) / float64(max(window, 1))
      score *= proximityBonus

      results.add(SearchResult(
        docId: docId,
        score: score,
        highlights: @[],
      ))

    results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
    if results.len > limit:
      results = results[0..<limit]
    return results
  finally:
    release(idx.lock)
