import std/tables
import std/strutils
import std/math
import std/algorithm
import std/sets

type
  PostingEntry* = object
    docId*: uint64
    termFreq*: int
    positions*: seq[int]

  BoolOp* = enum
    boAnd = "AND"
    boOr = "OR"
    boNot = "NOT"

  QueryNodeKind* = enum
    qnkTerm, qnkPhrase, qnkBool, qnkWildcard, qnkFuzzy, qnkRange

  QueryNode* = ref object
    case kind*: QueryNodeKind
    of qnkTerm:
      term*: string
      field*: string
      boost*: float64
    of qnkPhrase:
      phraseTerms*: seq[string]
      slop*: int
    of qnkBool:
      op*: BoolOp
      children*: seq[QueryNode]
    of qnkWildcard:
      pattern*: string
    of qnkFuzzy:
      fuzzyTerm*: string
      maxDistance*: int
    of qnkRange:
      rangeField*: string
      rangeMin*: float64
      rangeMax*: float64
      includeMin*: bool
      includeMax*: bool

  SearchResult* = object
    docId*: uint64
    score*: float64
    highlights*: seq[(int, int)]

# --- Tokenizer ---

type
  TokenKind = enum
    tkWord, tkQuoted, tkNumber,
    tkAnd, tkOr, tkNot,
    tkLParen, tkRParen,
    tkLBracket, tkRBracket,
    tkColon, tkTilde, tkStar,
    tkPlus, tkMinus, tkTo,
    tkEOF

  Token = object
    kind: TokenKind
    value: string

proc tokenizeQuery(input: string): seq[Token] =
  result = @[]
  var i = 0
  while i < input.len:
    case input[i]
    of ' ', '\t', '\n', '\r':
      inc i
    of '(':
      result.add(Token(kind: tkLParen, value: "("))
      inc i
    of ')':
      result.add(Token(kind: tkRParen, value: ")"))
      inc i
    of '[':
      result.add(Token(kind: tkLBracket, value: "["))
      inc i
    of ']':
      result.add(Token(kind: tkRBracket, value: "]"))
      inc i
    of ':':
      result.add(Token(kind: tkColon, value: ":"))
      inc i
    of '~':
      result.add(Token(kind: tkTilde, value: "~"))
      inc i
    of '*':
      result.add(Token(kind: tkStar, value: "*"))
      inc i
    of '+':
      result.add(Token(kind: tkPlus, value: "+"))
      inc i
    of '-':
      result.add(Token(kind: tkMinus, value: "-"))
      inc i
    of '"':
      inc i
      var phrase = ""
      while i < input.len and input[i] != '"':
        phrase.add(input[i])
        inc i
      if i < input.len:
        inc i
      result.add(Token(kind: tkQuoted, value: phrase))
    else:
      var word = ""
      while i < input.len and
            input[i] notin {' ', '\t', '\n', '\r', '(', ')', '[', ']',
                            ':', '~', '*', '+', '-', '"'}:
        word.add(input[i])
        inc i
      let upper = word.toUpperAscii()
      if upper == "AND":
        result.add(Token(kind: tkAnd, value: "AND"))
      elif upper == "OR":
        result.add(Token(kind: tkOr, value: "OR"))
      elif upper == "NOT":
        result.add(Token(kind: tkNot, value: "NOT"))
      elif upper == "TO":
        result.add(Token(kind: tkTo, value: "TO"))
      else:
        var isNum = true
        var hasDot = false
        for ci, c in word:
          if c == '-' and ci == 0: continue
          if c == '.' and not hasDot:
            hasDot = true
            continue
          if not c.isDigit():
            isNum = false
            break
        if isNum and word.len > 0 and word != "-":
          result.add(Token(kind: tkNumber, value: word))
        else:
          result.add(Token(kind: tkWord, value: word))
  result.add(Token(kind: tkEOF, value: ""))

# --- Parser ---

type
  Parser = object
    tokens: seq[Token]
    pos: int

proc peek(p: var Parser): Token =
  if p.pos < p.tokens.len:
    p.tokens[p.pos]
  else:
    Token(kind: tkEOF, value: "")

proc advance(p: var Parser): Token =
  result = p.peek()
  if p.pos < p.tokens.len:
    inc p.pos

proc parseExpr(p: var Parser): QueryNode
proc parsePrimary(p: var Parser): QueryNode

proc parseRange(p: var Parser, fieldName: string): QueryNode =
  let minTok = p.advance()
  var minVal: float64
  if minTok.kind == tkNumber:
    minVal = parseFloat(minTok.value)
  elif minTok.kind == tkStar:
    minVal = NegInf
  else:
    minVal = NegInf

  discard p.advance() # TO

  let maxTok = p.advance()
  var maxVal: float64
  if maxTok.kind == tkNumber:
    maxVal = parseFloat(maxTok.value)
  elif maxTok.kind == tkStar:
    maxVal = Inf
  else:
    maxVal = Inf

  if p.peek().kind == tkRBracket:
    discard p.advance()

  QueryNode(
    kind: qnkRange,
    rangeField: fieldName,
    rangeMin: minVal,
    rangeMax: maxVal,
    includeMin: true,
    includeMax: true,
  )

proc parsePrimary(p: var Parser): QueryNode =
  let tok = p.peek()
  case tok.kind
  of tkLParen:
    discard p.advance()
    let inner = parseExpr(p)
    if p.peek().kind == tkRParen:
      discard p.advance()
    return inner
  of tkQuoted:
    discard p.advance()
    let words = tok.value.splitWhitespace()
    return QueryNode(kind: qnkPhrase, phraseTerms: words, slop: 0)
  of tkWord:
    discard p.advance()
    var fieldName = ""
    var termValue = tok.value

    if p.peek().kind == tkColon:
      discard p.advance()
      fieldName = tok.value
      let next = p.peek()
      if next.kind == tkLBracket:
        discard p.advance()
        return parseRange(p, fieldName)
      elif next.kind == tkQuoted:
        let qt = p.advance()
        let words = qt.value.splitWhitespace()
        return QueryNode(kind: qnkPhrase, phraseTerms: words, slop: 0)
      elif next.kind in {tkWord, tkNumber}:
        termValue = p.advance().value
      else:
        termValue = ""

    if p.peek().kind == tkTilde:
      discard p.advance()
      var dist = 2
      if p.peek().kind == tkNumber:
        dist = parseInt(p.advance().value)
      return QueryNode(kind: qnkFuzzy, fuzzyTerm: termValue.toLowerAscii(),
                       maxDistance: dist)

    if p.peek().kind == tkStar:
      discard p.advance()
      return QueryNode(kind: qnkWildcard, pattern: termValue.toLowerAscii() & "*")

    return QueryNode(kind: qnkTerm, term: termValue.toLowerAscii(),
                     field: fieldName, boost: 1.0)
  of tkPlus:
    discard p.advance()
    return parsePrimary(p)
  of tkMinus:
    discard p.advance()
    let inner = parsePrimary(p)
    return QueryNode(kind: qnkBool, op: boNot, children: @[inner])
  of tkNumber:
    discard p.advance()
    return QueryNode(kind: qnkTerm, term: tok.value, field: "", boost: 1.0)
  else:
    discard p.advance()
    return QueryNode(kind: qnkTerm, term: "", field: "", boost: 1.0)

proc parseNotExpr(p: var Parser): QueryNode =
  if p.peek().kind == tkNot:
    discard p.advance()
    let inner = parseNotExpr(p)
    return QueryNode(kind: qnkBool, op: boNot, children: @[inner])
  return parsePrimary(p)

proc parseAndExpr(p: var Parser): QueryNode =
  var children: seq[QueryNode] = @[]
  children.add(parseNotExpr(p))

  while true:
    let tok = p.peek()
    if tok.kind == tkAnd:
      discard p.advance()
      children.add(parseNotExpr(p))
    elif tok.kind in {tkWord, tkQuoted, tkLParen, tkPlus, tkMinus,
                      tkNumber, tkNot}:
      children.add(parseNotExpr(p))
    else:
      break

  if children.len == 1:
    return children[0]
  return QueryNode(kind: qnkBool, op: boAnd, children: children)

proc parseOrExpr(p: var Parser): QueryNode =
  var children: seq[QueryNode] = @[]
  children.add(parseAndExpr(p))

  while p.peek().kind == tkOr:
    discard p.advance()
    children.add(parseAndExpr(p))

  if children.len == 1:
    return children[0]
  return QueryNode(kind: qnkBool, op: boOr, children: children)

proc parseExpr(p: var Parser): QueryNode =
  parseOrExpr(p)

proc parseQuery*(input: string): QueryNode =
  let tokens = tokenizeQuery(input)
  var parser = Parser(tokens: tokens, pos: 0)
  parseExpr(parser)

# --- Levenshtein distance ---

proc levenshtein(a, b: string): int =
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

# --- Executor ---

proc executeNode(postings: Table[string, seq[PostingEntry]],
                 query: QueryNode,
                 docScores: var Table[uint64, float64],
                 allDocIds: HashSet[uint64]): HashSet[uint64] =
  result = initHashSet[uint64]()
  case query.kind
  of qnkTerm:
    let key = if query.field.len > 0: query.field & ":" & query.term
              else: query.term
    if key in postings:
      for entry in postings[key]:
        result.incl(entry.docId)
        let s = float64(entry.termFreq) * query.boost
        if entry.docId notin docScores:
          docScores[entry.docId] = 0.0
        docScores[entry.docId] += s

  of qnkPhrase:
    if query.phraseTerms.len == 0:
      return
    var candidates = initHashSet[uint64]()
    var first = true
    for pt in query.phraseTerms:
      let ptLower = pt.toLowerAscii()
      var docs = initHashSet[uint64]()
      if ptLower in postings:
        for entry in postings[ptLower]:
          docs.incl(entry.docId)
      if first:
        candidates = docs
        first = false
      else:
        candidates = candidates * docs
    for docId in candidates:
      var valid = true
      var lastPos = -1
      for i, pt in query.phraseTerms:
        let ptLower = pt.toLowerAscii()
        if ptLower notin postings:
          valid = false
          break
        var found = false
        for entry in postings[ptLower]:
          if entry.docId == docId:
            for pos in entry.positions:
              if i == 0 or pos == lastPos + 1 + query.slop:
                found = true
                lastPos = pos
                break
            break
        if not found:
          valid = false
          break
      if valid:
        result.incl(docId)
        if docId notin docScores:
          docScores[docId] = 0.0
        docScores[docId] += 1.0

  of qnkBool:
    case query.op
    of boAnd:
      var first = true
      for child in query.children:
        let childDocs = executeNode(postings, child, docScores, allDocIds)
        if first:
          result = childDocs
          first = false
        else:
          result = result * childDocs
      if first:
        return
    of boOr:
      for child in query.children:
        let childDocs = executeNode(postings, child, docScores, allDocIds)
        result = result + childDocs
    of boNot:
      if query.children.len > 0:
        let childDocs = executeNode(postings, query.children[0], docScores, allDocIds)
        result = allDocIds - childDocs

  of qnkWildcard:
    let prefix = query.pattern.strip(chars = {'*'})
    for term in postings.keys:
      if term.startsWith(prefix):
        for entry in postings[term]:
          result.incl(entry.docId)
          if entry.docId notin docScores:
            docScores[entry.docId] = 0.0
          docScores[entry.docId] += float64(entry.termFreq)

  of qnkFuzzy:
    let target = query.fuzzyTerm.toLowerAscii()
    for term in postings.keys:
      if levenshtein(term, target) <= query.maxDistance:
        for entry in postings[term]:
          result.incl(entry.docId)
          if entry.docId notin docScores:
            docScores[entry.docId] = 0.0
          docScores[entry.docId] += float64(entry.termFreq)

  of qnkRange:
    discard

proc executeBoolQuery*(postings: Table[string, seq[PostingEntry]],
                       query: QueryNode,
                       docScores: var Table[uint64, float64],
                       allDocIds: HashSet[uint64] = initHashSet[uint64]()): HashSet[uint64] =
  executeNode(postings, query, docScores, allDocIds)

# --- BM25 helpers ---

proc expandTerms(postings: Table[string, seq[PostingEntry]],
                 node: QueryNode): seq[string] =
  result = @[]
  case node.kind
  of qnkTerm:
    let key = if node.field.len > 0: node.field & ":" & node.term
              else: node.term
    if key in postings:
      result.add(key)
  of qnkPhrase:
    for pt in node.phraseTerms:
      let t = pt.toLowerAscii()
      if t in postings:
        result.add(t)
  of qnkBool:
    for child in node.children:
      result.add(expandTerms(postings, child))
  of qnkWildcard:
    let prefix = node.pattern.strip(chars = {'*'})
    for term in postings.keys:
      if term.startsWith(prefix):
        result.add(term)
  of qnkFuzzy:
    let target = node.fuzzyTerm.toLowerAscii()
    for term in postings.keys:
      if levenshtein(term, target) <= node.maxDistance:
        result.add(term)
  of qnkRange:
    discard

# --- High-level API ---

proc booleanSearch*(postings: Table[string, seq[PostingEntry]],
                    docLengths: Table[uint64, int],
                    docCount: int,
                    avgDocLen: float64,
                    queryStr: string,
                    limit: int = 10,
                    fieldValues: Table[string, Table[uint64, float64]] =
                      initTable[string, Table[uint64, float64]]()): seq[SearchResult] =
  let query = parseQuery(queryStr)
  var allDocIds = initHashSet[uint64]()
  for docId in docLengths.keys:
    allDocIds.incl(docId)

  var rawScores = initTable[uint64, float64]()
  let matchingDocs = executeBoolQuery(postings, query, rawScores, allDocIds)

  if matchingDocs.len == 0:
    return @[]

  let terms = expandTerms(postings, query)
  var finalScores = initTable[uint64, float64]()
  const k1 = 1.2
  const b = 0.75
  let n = float64(docCount)

  for term in terms:
    if term notin postings:
      continue
    let df = float64(postings[term].len)
    if df == 0.0:
      continue
    let idf = ln((n - df + 0.5) / (df + 0.5) + 1.0)
    for entry in postings[term]:
      if entry.docId notin matchingDocs:
        continue
      let docLen = float64(docLengths.getOrDefault(entry.docId, 0))
      if docLen == 0.0 or avgDocLen == 0.0:
        continue
      let tfNorm = (float64(entry.termFreq) * (k1 + 1.0)) /
                   (float64(entry.termFreq) + k1 * (1.0 - b + b * docLen / avgDocLen))
      if entry.docId notin finalScores:
        finalScores[entry.docId] = 0.0
      finalScores[entry.docId] += idf * tfNorm

  # Apply range filters post-execution
  proc applyRangeFilters(node: QueryNode, docs: var HashSet[uint64]) =
    case node.kind
    of qnkRange:
      if node.rangeField in fieldValues:
        let fv = fieldValues[node.rangeField]
        var toRemove: seq[uint64] = @[]
        for docId in docs:
          if docId notin fv:
            toRemove.add(docId)
            continue
          let v = fv[docId]
          let belowMin = if node.includeMin: v < node.rangeMin
                         else: v <= node.rangeMin
          let aboveMax = if node.includeMax: v > node.rangeMax
                         else: v >= node.rangeMax
          if belowMin or aboveMax:
            toRemove.add(docId)
        for docId in toRemove:
          docs.excl(docId)
    of qnkBool:
      for child in node.children:
        applyRangeFilters(child, docs)
    else:
      discard

  var resultDocs = matchingDocs
  applyRangeFilters(query, resultDocs)

  var results: seq[SearchResult] = @[]
  for docId in resultDocs:
    let score = finalScores.getOrDefault(docId, rawScores.getOrDefault(docId, 0.0))
    results.add(SearchResult(docId: docId, score: score, highlights: @[]))

  results.sort(proc(a, b: SearchResult): int = cmp(b.score, a.score))
  if results.len > limit:
    results = results[0..<limit]
  return results
