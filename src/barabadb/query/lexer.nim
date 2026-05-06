## BaraQL Lexer — tokenization
import std/tables
import std/strutils

type
  TokenKind* = enum
    # Literals
    tkIntLit
    tkFloatLit
    tkStringLit
    tkBoolLit

    # Identifiers
    tkIdent

    # Keywords
    tkSelect
    tkInsert
    tkUpdate
    tkDelete
    tkFrom
    tkWhere
    tkAnd
    tkOr
    tkNot
    tkIn
    tkIs
    tkAs
    tkOn
    tkJoin
    tkLeft
    tkRight
    tkInner
    tkOuter
    tkFull
    tkCross
    tkOrder
    tkBy
    tkAsc
    tkDesc
    tkGroup
    tkHaving
    tkLimit
    tkOffset
    tkSet
    tkInto
    tkValues
    tkCreate
    tkDrop
    tkAlter
    tkTable
    tkIndex
    tkType
    tkLink
    tkProperty
    tkRequired
    tkMulti
    tkSingle
    tkTrue
    tkFalse
    tkNull
    tkIf
    tkThen
    tkElse
    tkEnd
    tkCase
    tkWhen
    tkWith
    tkDistinct
    tkUnion
    tkIntersect
    tkExcept
    tkExists
    tkBetween
    tkLike
    tkILike
    tkReturning
    tkPrimary
    tkKey
    tkForeign
    tkReferences
    tkCascade
    tkUnique
    tkCheck
    tkDefault
    tkAdd
    tkColumn
    tkRename
    tkBegin
    tkCommit
    tkRollback
    tkExplain
    tkCount
    tkSum
    tkAvg
    tkMin
    tkMax
    tkArray
    tkVector
    tkGraph
    tkDocument
    tkSimilar
    tkNearest
    tkTo
    tkBfs
    tkDfs
    tkPath

    # Operators
    tkPlus
    tkMinus
    tkStar
    tkSlash
    tkPercent
    tkPower
    tkEq
    tkNotEq
    tkLt
    tkLtEq
    tkGt
    tkGtEq
    tkAssign
    tkArrow
    tkDoubleColon
    tkColon
    tkDot
    tkComma
    tkSemicolon
    tkLParen
    tkRParen
    tkLBrace
    tkRbrace
    tkLBracket
    tkRBracket
    tkAmp
    tkPipe
    tkTilde
    tkConcat
    tkCoalesce
    tkFloorDiv

    # Special
    tkEof
    tkNewline
    tkInvalid

  Token* = object
    kind*: TokenKind
    value*: string
    line*: int
    col*: int

  Lexer* = object
    input: string
    pos: int
    line: int
    col: int

const keywords*: Table[string, TokenKind] = {
  "select": tkSelect,
  "insert": tkInsert,
  "update": tkUpdate,
  "delete": tkDelete,
  "from": tkFrom,
  "where": tkWhere,
  "and": tkAnd,
  "or": tkOr,
  "not": tkNot,
  "in": tkIn,
  "is": tkIs,
  "as": tkAs,
  "on": tkOn,
  "join": tkJoin,
  "left": tkLeft,
  "right": tkRight,
  "inner": tkInner,
  "outer": tkOuter,
  "full": tkFull,
  "cross": tkCross,
  "order": tkOrder,
  "by": tkBy,
  "asc": tkAsc,
  "desc": tkDesc,
  "group": tkGroup,
  "having": tkHaving,
  "limit": tkLimit,
  "offset": tkOffset,
  "set": tkSet,
  "into": tkInto,
  "values": tkValues,
  "create": tkCreate,
  "drop": tkDrop,
  "alter": tkAlter,
  "table": tkTable,
  "index": tkIndex,
  "type": tkType,
  "link": tkLink,
  "property": tkProperty,
  "required": tkRequired,
  "multi": tkMulti,
  "single": tkSingle,
  "true": tkTrue,
  "false": tkFalse,
  "null": tkNull,
  "if": tkIf,
  "then": tkThen,
  "else": tkElse,
  "end": tkEnd,
  "case": tkCase,
  "when": tkWhen,
  "with": tkWith,
  "distinct": tkDistinct,
  "union": tkUnion,
  "intersect": tkIntersect,
  "except": tkExcept,
  "exists": tkExists,
  "between": tkBetween,
  "like": tkLike,
  "ilike": tkILike,
  "returning": tkReturning,
  "primary": tkPrimary,
  "key": tkKey,
  "foreign": tkForeign,
  "references": tkReferences,
  "cascade": tkCascade,
  "unique": tkUnique,
  "check": tkCheck,
  "default": tkDefault,
  "add": tkAdd,
  "column": tkColumn,
  "rename": tkRename,
  "begin": tkBegin,
  "commit": tkCommit,
  "rollback": tkRollback,
  "explain": tkExplain,
  "count": tkCount,
  "sum": tkSum,
  "avg": tkAvg,
  "min": tkMin,
  "max": tkMax,
  "array": tkArray,
  "vector": tkVector,
  "graph": tkGraph,
  "document": tkDocument,
  "similar": tkSimilar,
  "nearest": tkNearest,
  "to": tkTo,
  "bfs": tkBfs,
  "dfs": tkDfs,
  "path": tkPath,
}.toTable

proc newLexer*(input: string): Lexer =
  Lexer(input: input, pos: 0, line: 1, col: 1)

proc peek(l: Lexer): char =
  if l.pos < l.input.len:
    return l.input[l.pos]
  return '\0'

proc advance(l: var Lexer): char =
  result = l.input[l.pos]
  inc l.pos
  if result == '\n':
    inc l.line
    l.col = 1
  else:
    inc l.col

proc skipWhitespace(l: var Lexer) =
  while l.pos < l.input.len and l.input[l.pos] in {' ', '\t', '\r', '\n'}:
    discard l.advance()

proc skipLineComment(l: var Lexer) =
  while l.pos < l.input.len and l.input[l.pos] != '\n':
    discard l.advance()

proc skipBlockComment(l: var Lexer) =
  discard l.advance()  # skip *
  discard l.advance()  # skip *
  while l.pos < l.input.len - 1:
    if l.input[l.pos] == '*' and l.input[l.pos + 1] == '/':
      discard l.advance()
      discard l.advance()
      return
    discard l.advance()

proc readString(l: var Lexer, quote: char): string =
  result = ""
  while l.pos < l.input.len and l.input[l.pos] != quote:
    if l.input[l.pos] == '\\':
      discard l.advance()
      if l.pos >= l.input.len: break
      case l.input[l.pos]
      of 'n': result.add('\n')
      of 't': result.add('\t')
      of 'r': result.add('\r')
      of '\\': result.add('\\')
      of '\'': result.add('\'')
      of '"': result.add('"')
      else: result.add(l.input[l.pos])
    else:
      result.add(l.input[l.pos])
    discard l.advance()
  if l.pos < l.input.len:
    discard l.advance()  # skip closing quote

proc readNumber(l: var Lexer, startLine, startCol: int): Token =
  var numStr = ""
  var isFloat = false
  while l.pos < l.input.len and (l.input[l.pos] in Digits or l.input[l.pos] == '.'):
    if l.input[l.pos] == '.':
      isFloat = true
    numStr.add(l.input[l.pos])
    discard l.advance()
  if isFloat:
    Token(kind: tkFloatLit, value: numStr, line: startLine, col: startCol)
  else:
    Token(kind: tkIntLit, value: numStr, line: startLine, col: startCol)

proc readIdent(l: var Lexer, startLine, startCol: int): Token =
  var ident = ""
  while l.pos < l.input.len and (l.input[l.pos] in IdentChars or l.input[l.pos] in Digits):
    ident.add(l.input[l.pos])
    discard l.advance()
  let lowerIdent = ident.toLower()
  if lowerIdent in keywords:
    Token(kind: keywords[lowerIdent], value: ident, line: startLine, col: startCol)
  else:
    Token(kind: tkIdent, value: ident, line: startLine, col: startCol)

proc nextToken*(l: var Lexer): Token =
  l.skipWhitespace()
  if l.pos >= l.input.len:
    return Token(kind: tkEof, line: l.line, col: l.col)

  let startLine = l.line
  let startCol = l.col
  let ch = l.peek()

  case ch
  of '/':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '/':
      l.skipLineComment()
      return l.nextToken()
    elif l.pos + 1 < l.input.len and l.input[l.pos + 1] == '*':
      l.skipBlockComment()
      return l.nextToken()
    else:
      discard l.advance()
      return Token(kind: tkSlash, value: "/", line: startLine, col: startCol)
  of '+':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '+':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkConcat, value: "++", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkPlus, value: "+", line: startLine, col: startCol)
  of '-':
    discard l.advance()
    return Token(kind: tkMinus, value: "-", line: startLine, col: startCol)
  of '*':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '*':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkPower, value: "**", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkStar, value: "*", line: startLine, col: startCol)
  of '%':
    discard l.advance()
    return Token(kind: tkPercent, value: "%", line: startLine, col: startCol)
  of '=':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '>':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkArrow, value: "=>", line: startLine, col: startCol)
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '=':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkEq, value: "==", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkEq, value: "=", line: startLine, col: startCol)
  of ':':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '=':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkAssign, value: ":=", line: startLine, col: startCol)
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == ':':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkDoubleColon, value: "::", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkColon, value: ":", line: startLine, col: startCol)
  of '!':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '=':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkNotEq, value: "!=", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkInvalid, value: "!", line: startLine, col: startCol)
  of '<':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '=':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkLtEq, value: "<=", line: startLine, col: startCol)
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '>':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkNotEq, value: "<>", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkLt, value: "<", line: startLine, col: startCol)
  of '>':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '=':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkGtEq, value: ">=", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkGt, value: ">", line: startLine, col: startCol)
  of '?':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '?':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkCoalesce, value: "??", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkInvalid, value: "?", line: startLine, col: startCol)
  of '.':
    if l.pos + 1 < l.input.len and l.input[l.pos + 1] == '<':
      discard l.advance()
      discard l.advance()
      return Token(kind: tkInvalid, value: ".<", line: startLine, col: startCol)
    discard l.advance()
    return Token(kind: tkDot, value: ".", line: startLine, col: startCol)
  of ',':
    discard l.advance()
    return Token(kind: tkComma, value: ",", line: startLine, col: startCol)
  of ';':
    discard l.advance()
    return Token(kind: tkSemicolon, value: ";", line: startLine, col: startCol)
  of '(':
    discard l.advance()
    return Token(kind: tkLParen, value: "(", line: startLine, col: startCol)
  of ')':
    discard l.advance()
    return Token(kind: tkRParen, value: ")", line: startLine, col: startCol)
  of '{':
    discard l.advance()
    return Token(kind: tkLBrace, value: "{", line: startLine, col: startCol)
  of '}':
    discard l.advance()
    return Token(kind: tkRbrace, value: "}", line: startLine, col: startCol)
  of '[':
    discard l.advance()
    return Token(kind: tkLBracket, value: "[", line: startLine, col: startCol)
  of ']':
    discard l.advance()
    return Token(kind: tkRBracket, value: "]", line: startLine, col: startCol)
  of '&':
    discard l.advance()
    return Token(kind: tkAmp, value: "&", line: startLine, col: startCol)
  of '|':
    discard l.advance()
    return Token(kind: tkPipe, value: "|", line: startLine, col: startCol)
  of '~':
    discard l.advance()
    return Token(kind: tkTilde, value: "~", line: startLine, col: startCol)
  of '\'', '"':
    discard l.advance()
    let s = l.readString(ch)
    return Token(kind: tkStringLit, value: s, line: startLine, col: startCol)
  of '#':
    l.skipLineComment()
    return l.nextToken()
  else:
    if ch in Digits:
      return l.readNumber(startLine, startCol)
    elif ch in IdentStartChars:
      return l.readIdent(startLine, startCol)
    else:
      discard l.advance()
      return Token(kind: tkInvalid, value: $ch, line: startLine, col: startCol)

proc tokenize*(input: string): seq[Token] =
  var lexer = newLexer(input)
  result = @[]
  while true:
    let tok = lexer.nextToken()
    result.add(tok)
    if tok.kind == tkEof:
      break
