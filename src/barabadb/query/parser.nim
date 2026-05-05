## BaraQL Parser — recursive descent parser
import std/strutils
import lexer
import ast
import ../core/types

type
  Parser* = object
    tokens: seq[Token]
    pos: int

proc newParser*(tokens: seq[Token]): Parser =
  Parser(tokens: tokens, pos: 0)

proc peek(p: Parser): Token =
  if p.pos < p.tokens.len:
    return p.tokens[p.pos]
  Token(kind: tkEof)

proc advance(p: var Parser): Token =
  result = p.tokens[p.pos]
  inc p.pos

proc expect(p: var Parser, kind: TokenKind): Token =
  let tok = p.advance()
  if tok.kind != kind:
    raise newException(ValueError,
      "Expected " & $kind & " but got " & $tok.kind & " at line " & $tok.line)
  return tok

proc match(p: var Parser, kind: TokenKind): bool =
  if p.peek().kind == kind:
    discard p.advance()
    return true
  return false

proc parseExpr(p: var Parser): Node
proc parseSelect(p: var Parser): Node

proc parsePrimary(p: var Parser): Node =
  let tok = p.peek()
  case tok.kind
  of tkIntLit:
    discard p.advance()
    Node(kind: nkIntLit, intVal: parseInt(tok.value), line: tok.line, col: tok.col)
  of tkFloatLit:
    discard p.advance()
    Node(kind: nkFloatLit, floatVal: parseFloat(tok.value), line: tok.line, col: tok.col)
  of tkStringLit:
    discard p.advance()
    Node(kind: nkStringLit, strVal: tok.value, line: tok.line, col: tok.col)
  of tkBoolLit:
    discard p.advance()
    Node(kind: nkBoolLit, boolVal: tok.value == "true", line: tok.line, col: tok.col)
  of tkNull:
    discard p.advance()
    Node(kind: nkNullLit, line: tok.line, col: tok.col)
  of tkIdent:
    discard p.advance()
    # Check for function call: ident(...)
    if p.peek().kind == tkLParen:
      discard p.advance()  # consume (
      var args: seq[Node] = @[]
      if p.peek().kind != tkRParen:
        args.add(p.parseExpr())
        while p.match(tkComma):
          args.add(p.parseExpr())
      discard p.expect(tkRParen)
      return Node(kind: nkFuncCall, funcName: tok.value, funcArgs: args,
                  line: tok.line, col: tok.col)
    # Check for dotted path: ident.ident.ident
    var parts = @[tok.value]
    while p.peek().kind == tkDot:
      discard p.advance()  # consume .
      parts.add(p.expect(tkIdent).value)
    if parts.len == 1:
      return Node(kind: nkIdent, identName: tok.value, line: tok.line, col: tok.col)
    return Node(kind: nkPath, pathParts: parts, line: tok.line, col: tok.col)
  of tkLParen:
    discard p.advance()
    # Check for subquery
    if p.peek().kind == tkSelect:
      let sub = p.parseSelect()
      discard p.expect(tkRParen)
      return Node(kind: nkSubquery, subQuery: sub, line: tok.line, col: tok.col)
    let expr = p.parseExpr()
    discard p.expect(tkRParen)
    expr
  of tkLBracket:
    discard p.advance()
    var elems: seq[Node] = @[]
    if p.peek().kind != tkRBracket:
      elems.add(p.parseExpr())
      while p.match(tkComma):
        elems.add(p.parseExpr())
    discard p.expect(tkRBracket)
    Node(kind: nkArrayLit, arrayElems: elems, line: tok.line, col: tok.col)
  of tkSelect:
    p.parseSelect()
  of tkExists:
    discard p.advance()
    discard p.expect(tkLParen)
    let sub = p.parseSelect()
    discard p.expect(tkRParen)
    Node(kind: nkExists, existsExpr: sub, line: tok.line, col: tok.col)
  of tkNot:
    discard p.advance()
    let operand = p.parsePrimary()
    Node(kind: nkUnaryOp, unOp: ukNot, unOperand: operand, line: tok.line, col: tok.col)
  of tkMinus:
    discard p.advance()
    let operand = p.parsePrimary()
    Node(kind: nkUnaryOp, unOp: ukNeg, unOperand: operand, line: tok.line, col: tok.col)
  of tkCount, tkSum, tkAvg, tkMin, tkMax:
    let funcName = tok.value
    discard p.advance()
    discard p.expect(tkLParen)
    var args: seq[Node] = @[]
    # Handle DISTINCT inside aggregate
    var hasDistinct = false
    if p.peek().kind == tkDistinct:
      discard p.advance()
      hasDistinct = true
    if p.peek().kind != tkRParen:
      args.add(p.parseExpr())
    discard p.expect(tkRParen)
    var node = Node(kind: nkFuncCall, funcName: funcName.toLower(), funcArgs: args,
                    line: tok.line, col: tok.col)
    return node
  of tkCase:
    discard p.advance()
    var caseExpr: Node = nil
    # CASE expr WHEN ... THEN ... ELSE ... END
    if p.peek().kind != tkWhen:
      caseExpr = p.parseExpr()
    var whens: seq[(Node, Node)] = @[]
    while p.match(tkWhen):
      let cond = p.parseExpr()
      discard p.expect(tkThen)
      let val = p.parseExpr()
      whens.add((cond, val))
    var elseExpr: Node = nil
    if p.match(tkElse):
      elseExpr = p.parseExpr()
    discard p.expect(tkEnd)
    Node(kind: nkCase, caseExpr: caseExpr, caseWhens: whens, caseElse: elseExpr,
         line: tok.line, col: tok.col)
  else:
    discard p.advance()
    Node(kind: nkNullLit, line: tok.line, col: tok.col)

proc parseMulDiv(p: var Parser): Node =
  result = p.parsePrimary()
  while p.peek().kind in {tkStar, tkSlash, tkPercent, tkFloorDiv}:
    let op = case p.peek().kind
      of tkStar: bkMul
      of tkSlash: bkDiv
      of tkPercent: bkMod
      of tkFloorDiv: bkFloorDiv
      else: bkMul
    let tok = p.advance()
    let right = p.parsePrimary()
    result = Node(kind: nkBinOp, binOp: op, binLeft: result, binRight: right,
                  line: tok.line, col: tok.col)

proc parseAddSub(p: var Parser): Node =
  result = p.parseMulDiv()
  while p.peek().kind in {tkPlus, tkMinus, tkConcat}:
    let op = case p.peek().kind
      of tkPlus: bkAdd
      of tkMinus: bkSub
      of tkConcat: bkConcat
      else: bkAdd
    let tok = p.advance()
    let right = p.parseMulDiv()
    result = Node(kind: nkBinOp, binOp: op, binLeft: result, binRight: right,
                  line: tok.line, col: tok.col)

proc parseComparison(p: var Parser): Node =
  result = p.parseAddSub()
  # Handle BETWEEN ... AND ...
  if p.peek().kind == tkBetween:
    let tok = p.advance()
    let low = p.parseAddSub()
    discard p.expect(tkAnd)
    let high = p.parseAddSub()
    return Node(kind: nkBetweenExpr, betweenExpr: result,
                betweenLow: low, betweenHigh: high, line: tok.line, col: tok.col)
  # Handle IN (subquery | list)
  if p.peek().kind == tkIn:
    let tok = p.advance()
    let right = p.parseAddSub()
    return Node(kind: nkInExpr, inLeft: result, inRight: right,
                line: tok.line, col: tok.col)
  # Handle LIKE / ILIKE
  if p.peek().kind in {tkLike, tkILike}:
    let isILike = p.peek().kind == tkILike
    let tok = p.advance()
    let pattern = p.parseAddSub()
    return Node(kind: nkLikeExpr, likeExpr: result, likePattern: pattern,
                likeCaseInsensitive: isILike, line: tok.line, col: tok.col)
  # Handle IS NULL / IS NOT NULL
  if p.peek().kind == tkIs:
    let tok = p.advance()
    var negated = false
    if p.peek().kind == tkNot:
      discard p.advance()
      negated = true
    discard p.advance()  # consume NULL token (assumed)
    return Node(kind: nkIsExpr, isExpr: result, isNegated: negated,
                line: tok.line, col: tok.col)
  while p.peek().kind in {tkEq, tkNotEq, tkLt, tkLtEq, tkGt, tkGtEq}:
    let op = case p.peek().kind
      of tkEq: bkEq
      of tkNotEq: bkNotEq
      of tkLt: bkLt
      of tkLtEq: bkLtEq
      of tkGt: bkGt
      of tkGtEq: bkGtEq
      else: bkEq
    let tok = p.advance()
    let right = p.parseAddSub()
    result = Node(kind: nkBinOp, binOp: op, binLeft: result, binRight: right,
                  line: tok.line, col: tok.col)

proc parseNot(p: var Parser): Node =
  if p.peek().kind == tkNot:
    let tok = p.advance()
    let operand = p.parseComparison()
    return Node(kind: nkUnaryOp, unOp: ukNot, unOperand: operand,
                line: tok.line, col: tok.col)
  return p.parseComparison()

proc parseAnd(p: var Parser): Node =
  result = p.parseNot()
  while p.peek().kind == tkAnd:
    let tok = p.advance()
    let right = p.parseNot()
    result = Node(kind: nkBinOp, binOp: bkAnd, binLeft: result, binRight: right,
                  line: tok.line, col: tok.col)

proc parseOr(p: var Parser): Node =
  result = p.parseAnd()
  while p.peek().kind == tkOr:
    let tok = p.advance()
    let right = p.parseAnd()
    result = Node(kind: nkBinOp, binOp: bkOr, binLeft: result, binRight: right,
                  line: tok.line, col: tok.col)

proc parseExpr(p: var Parser): Node =
  return p.parseOr()

proc parseJoinType(p: var Parser): JoinKind =
  if p.match(tkInner):
    return jkInner
  elif p.match(tkLeft):
    if p.match(tkOuter): discard
    return jkLeft
  elif p.match(tkRight):
    if p.match(tkOuter): discard
    return jkRight
  elif p.match(tkFull):
    if p.match(tkOuter): discard
    return jkFull
  elif p.match(tkCross):
    return jkCross
  return jkInner

proc parseWith(p: var Parser): Node =
  # WITH name AS (select), name2 AS (select2) SELECT ...
  let tok = p.expect(tkWith)
  result = Node(kind: nkWith, line: tok.line, col: tok.col)
  result.withBindings = @[]

  # Parse first CTE
  let cteName = p.expect(tkIdent).value
  discard p.expect(tkAs)
  discard p.expect(tkLParen)
  let cteQuery = p.parseSelect()
  discard p.expect(tkRParen)
  result.withBindings.add((cteName, cteQuery))

  # Parse additional CTEs
  while p.match(tkComma):
    let name = p.expect(tkIdent).value
    discard p.expect(tkAs)
    discard p.expect(tkLParen)
    let query = p.parseSelect()
    discard p.expect(tkRParen)
    result.withBindings.add((name, query))

proc parseSelect(p: var Parser): Node =
  # Handle WITH (CTE)
  var withClause: Node = nil
  if p.peek().kind == tkWith:
    withClause = p.parseWith()

  let tok = p.expect(tkSelect)
  result = Node(kind: nkSelect, line: tok.line, col: tok.col)

  if withClause != nil:
    result.selWith = withClause.withBindings

  if p.peek().kind == tkDistinct:
    discard p.advance()
    result.selDistinct = true

  # Parse SELECT list
  result.selResult = @[]
  result.selResult.add(p.parseExpr())
  while p.match(tkComma):
    result.selResult.add(p.parseExpr())

  # Parse FROM
  result.selJoins = @[]
  if p.match(tkFrom):
    # Handle subquery: (SELECT ...) AS alias
    if p.peek().kind == tkLParen:
      discard p.advance()  # consume (
      let subquery = p.parseSelect()
      discard p.expect(tkRParen)
      var alias = ""
      if p.match(tkAs):
        alias = p.expect(tkIdent).value
      elif p.peek().kind == tkIdent:
        alias = p.advance().value
      result.selFrom = Node(kind: nkFrom, fromTable: "(subquery)",
                            fromAlias: alias, line: tok.line, col: tok.col)
    else:
      let tableTok = p.expect(tkIdent)
      var alias = ""
      if p.match(tkAs):
        alias = p.expect(tkIdent).value
      elif p.peek().kind == tkIdent:
        alias = p.advance().value
      result.selFrom = Node(kind: nkFrom, fromTable: tableTok.value,
                            fromAlias: alias, line: tableTok.line, col: tableTok.col)

    # Parse JOINs
    while p.peek().kind == tkJoin or
          (p.peek().kind in {tkInner, tkLeft, tkRight, tkFull, tkCross} and
           p.pos + 1 < p.tokens.len and p.tokens[p.pos + 1].kind == tkJoin):
      let jk = p.parseJoinType()
      discard p.expect(tkJoin)
      let joinTable = p.expect(tkIdent)
      var joinAlias = ""
      if p.match(tkAs):
        joinAlias = p.expect(tkIdent).value
      elif p.peek().kind == tkIdent:
        joinAlias = p.advance().value
      var joinCond: Node = nil
      if p.match(tkOn):
        joinCond = p.parseExpr()
      let joinTarget = Node(kind: nkFrom, fromTable: joinTable.value,
                            fromAlias: joinAlias, line: joinTable.line, col: joinTable.col)
      result.selJoins.add(Node(kind: nkJoin, joinKind: jk, joinTarget: joinTarget,
                               joinOn: joinCond, joinAlias: joinAlias,
                               line: joinTable.line, col: joinTable.col))

  # Parse WHERE
  if p.match(tkWhere):
    result.selWhere = Node(kind: nkWhere, whereExpr: p.parseExpr())

  # Parse GROUP BY
  if p.match(tkGroup):
    discard p.expect(tkBy)
    result.selGroupBy = @[]
    result.selGroupBy.add(p.parseExpr())
    while p.match(tkComma):
      result.selGroupBy.add(p.parseExpr())

  # Parse HAVING
  if p.match(tkHaving):
    result.selHaving = Node(kind: nkHaving, havingExpr: p.parseExpr())

  # Parse ORDER BY
  if p.match(tkOrder):
    discard p.expect(tkBy)
    result.selOrderBy = @[]
    var firstExpr = p.parseExpr()
    var firstDir = sdAsc
    if p.match(tkDesc):
      firstDir = sdDesc
    elif p.match(tkAsc):
      firstDir = sdAsc
    result.selOrderBy.add(Node(kind: nkOrderBy, orderByExpr: firstExpr,
                               orderByDir: firstDir))
    while p.match(tkComma):
      let expr = p.parseExpr()
      var dir = sdAsc
      if p.match(tkDesc):
        dir = sdDesc
      elif p.match(tkAsc):
        dir = sdAsc
      result.selOrderBy.add(Node(kind: nkOrderBy, orderByExpr: expr,
                                 orderByDir: dir))

  # Parse LIMIT
  if p.match(tkLimit):
    result.selLimit = Node(kind: nkLimit, limitExpr: p.parseExpr())

  # Parse OFFSET
  if p.match(tkOffset):
    result.selOffset = Node(kind: nkOffset, offsetExpr: p.parseExpr())

proc parseInsert(p: var Parser): Node =
  let tok = p.expect(tkInsert)
  let target = p.expect(tkIdent).value
  result = Node(kind: nkInsert, insTarget: target, line: tok.line, col: tok.col)

proc parseUpdate(p: var Parser): Node =
  let tok = p.expect(tkUpdate)
  let target = p.expect(tkIdent).value
  result = Node(kind: nkUpdate, updTarget: target, line: tok.line, col: tok.col)
  if p.match(tkSet):
    result.updSet = @[]
    let field = p.expect(tkIdent).value
    discard p.match(tkEq)  # = or :=
    let val = p.parseExpr()
    result.updSet.add(Node(kind: nkBinOp, binOp: bkAssign,
      binLeft: Node(kind: nkIdent, identName: field),
      binRight: val))
    while p.match(tkComma):
      let f = p.expect(tkIdent).value
      discard p.match(tkEq)
      let v = p.parseExpr()
      result.updSet.add(Node(kind: nkBinOp, binOp: bkAssign,
        binLeft: Node(kind: nkIdent, identName: f),
        binRight: v))
  if p.match(tkWhere):
    result.updWhere = Node(kind: nkWhere, whereExpr: p.parseExpr())

proc parseDelete(p: var Parser): Node =
  let tok = p.expect(tkDelete)
  discard p.match(tkFrom)  # optional FROM keyword
  let target = p.expect(tkIdent).value
  result = Node(kind: nkDelete, delTarget: target, line: tok.line, col: tok.col)
  if p.match(tkWhere):
    result.delWhere = Node(kind: nkWhere, whereExpr: p.parseExpr())

proc parseCreateType(p: var Parser): Node =
  let tok = p.expect(tkCreate)
  discard p.expect(tkType)
  let name = p.expect(tkIdent).value
  result = Node(kind: nkCreateType, ctName: name, line: tok.line, col: tok.col)
  # Parse bases (EXTENDING)
  result.ctBases = @[]
  if p.match(tkIdent):  # "extending" keyword mapped to ident
    # Check if the ident is "extending"
    # For now, just accept bases in braces
    discard
  # Parse body
  if p.match(tkLBrace):
    result.ctProperties = @[]
    result.ctLinks = @[]
    while p.peek().kind != tkRbrace and p.peek().kind != tkEof:
      discard p.match(tkComma)  # optional comma separator
      # Parse property or link
      var isRequired = false
      var isMulti = false
      if p.peek().kind == tkRequired:
        discard p.advance()
        isRequired = true
      if p.peek().kind == tkMulti:
        discard p.advance()
        isMulti = true

      let fieldTok = p.expect(tkIdent)
      # Check for link or property
      if p.peek().kind == tkArrow:  # -> means link
        discard p.advance()  # consume ->
        let target = p.expect(tkIdent).value
        result.ctLinks.add(Node(kind: nkLinkDef,
          ldName: fieldTok.value, ldTarget: target,
          ldRequired: isRequired,
          ldCardinality: if isMulti: Many else: One))
      else:
        var typeName = ""
        if p.match(tkColon):
          typeName = p.expect(tkIdent).value
        result.ctProperties.add(Node(kind: nkPropertyDef,
          pdName: fieldTok.value, pdType: typeName,
          pdRequired: isRequired))
      discard p.match(tkSemicolon)
    discard p.expect(tkRbrace)

proc parseStatement*(p: var Parser): Node =
  case p.peek().kind
  of tkWith, tkSelect: p.parseSelect()
  of tkInsert: p.parseInsert()
  of tkUpdate: p.parseUpdate()
  of tkDelete: p.parseDelete()
  of tkCreate: p.parseCreateType()
  else:
    let tok = p.advance()
    Node(kind: nkNullLit, line: tok.line, col: tok.col)

proc parse*(tokens: seq[Token]): Node =
  var parser = newParser(tokens)
  result = Node(kind: nkStatementList)
  while parser.peek().kind != tkEof:
    result.stmts.add(parser.parseStatement())
    discard parser.match(tkSemicolon)

proc parse*(input: string): Node =
  let tokens = tokenize(input)
  parse(tokens)
