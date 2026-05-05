## BaraQL Parser — recursive descent parser
import std/strutils
import lexer
import ast

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
    Node(kind: nkIdent, identName: tok.value, line: tok.line, col: tok.col)
  of tkLParen:
    discard p.advance()
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
  of tkCount:
    discard p.advance()
    discard p.expect(tkLParen)
    var args: seq[Node] = @[]
    if p.peek().kind != tkRParen:
      args.add(p.parseExpr())
    discard p.expect(tkRParen)
    Node(kind: nkFuncCall, funcName: "count", funcArgs: args, line: tok.line, col: tok.col)
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

proc parseSelect(p: var Parser): Node =
  let tok = p.expect(tkSelect)
  result = Node(kind: nkSelect, line: tok.line, col: tok.col)

  if p.peek().kind == tkDistinct:
    discard p.advance()
    result.selDistinct = true

  result.selResult = @[]
  result.selResult.add(p.parseExpr())
  while p.match(tkComma):
    result.selResult.add(p.parseExpr())

  if p.match(tkFrom):
    let tableTok = p.expect(tkIdent)
    var alias = ""
    if p.match(tkAs):
      alias = p.expect(tkIdent).value
    elif p.peek().kind == tkIdent:
      alias = p.advance().value
    result.selFrom = Node(kind: nkFrom, fromTable: tableTok.value,
                          fromAlias: alias, line: tableTok.line, col: tableTok.col)

  if p.match(tkWhere):
    result.selWhere = Node(kind: nkWhere, whereExpr: p.parseExpr())

  if p.match(tkLimit):
    result.selLimit = Node(kind: nkLimit, limitExpr: p.parseExpr())

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

proc parseDelete(p: var Parser): Node =
  let tok = p.expect(tkDelete)
  let target = p.expect(tkIdent).value
  result = Node(kind: nkDelete, delTarget: target, line: tok.line, col: tok.col)

proc parseCreateType(p: var Parser): Node =
  let tok = p.expect(tkCreate)
  discard p.expect(tkType)
  let name = p.expect(tkIdent).value
  result = Node(kind: nkCreateType, ctName: name, line: tok.line, col: tok.col)

proc parseStatement*(p: var Parser): Node =
  case p.peek().kind
  of tkSelect: p.parseSelect()
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
