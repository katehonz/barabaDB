## BaraDB CLI — interactive query shell
import std/terminal
import std/strutils
import std/tables
import ../query/lexer
import ../query/parser

const
  Version = "0.1.0"
  Prompt = "bara> "
  ContinuationPrompt = "  .. > "

type
  CliState* = object
    history: seq[string]
    verbose: bool
    connected: bool
    database: string

proc newCliState*(): CliState =
  CliState(
    history: @[],
    verbose: false,
    connected: false,
    database: "default",
  )

proc printBanner*() =
  styledEcho fgCyan, "╔════════════════════════════════════════╗"
  styledEcho fgCyan, "║", fgYellow, "  BaraDB ", fgWhite, "v", Version,
              fgCyan, " — Multimodal Database    ", fgCyan, "║"
  styledEcho fgCyan, "║", fgGreen, "  Type 'help' for commands             ", fgCyan, "║"
  styledEcho fgCyan, "║", fgGreen, "  Type 'quit' to exit                  ", fgCyan, "║"
  styledEcho fgCyan, "╚════════════════════════════════════════╝"
  echo ""

proc printHelp*() =
  styledEcho fgYellow, "Commands:"
  styledEcho fgWhite, "  help          ", fgGray, "— show this help"
  styledEcho fgWhite, "  quit/exit     ", fgGray, "— exit the shell"
  styledEcho fgWhite, "  version       ", fgGray, "— show version"
  styledEcho fgWhite, "  tables        ", fgGray, "— list all tables/types"
  styledEcho fgWhite, "  describe <t>  ", fgGray, "— describe a type"
  styledEcho fgWhite, "  history       ", fgGray, "— show query history"
  styledEcho fgWhite, "  verbose       ", fgGray, "— toggle verbose mode"
  styledEcho fgWhite, "  clear         ", fgGray, "— clear screen"
  styledEcho fgWhite, "  status        ", fgGray, "— show connection status"
  echo ""
  styledEcho fgYellow, "Query Language (BaraQL):"
  styledEcho fgWhite, "  SELECT <fields> FROM <type> [WHERE <cond>] [LIMIT <n>]"
  styledEcho fgWhite, "  INSERT <type> { <fields> }"
  styledEcho fgWhite, "  UPDATE <type> SET <fields> [WHERE <cond>]"
  styledEcho fgWhite, "  DELETE <type> [WHERE <cond>]"
  styledEcho fgWhite, "  CREATE TYPE <name> { <properties> }"
  echo ""

proc formatResult*(columns: seq[string], rows: seq[seq[string]]): string =
  if columns.len == 0:
    return "(no results)"

  var widths: seq[int] = @[]
  for col in columns:
    widths.add(col.len)
  for row in rows:
    for i, val in row:
      if i < widths.len and val.len > widths[i]:
        widths[i] = val.len

  result = ""
  # Header
  for i, col in columns:
    result &= col
    result &= " ".repeat(widths[i] - col.len + 2)
  result &= "\n"

  # Separator
  for i, col in columns:
    result &= "─".repeat(widths[i])
    result &= "  "
  result &= "\n"

  # Rows
  for row in rows:
    for i, val in row:
      if i < widths.len:
        result &= val
        result &= " ".repeat(widths[i] - val.len + 2)
    result &= "\n"

  result &= "(" & $rows.len & " rows)"

proc processCommand*(state: var CliState, input: string): string =
  let cmd = input.strip().toLower()

  case cmd
  of "help", "\\h", "\\?":
    printHelp()
    return ""
  of "quit", "exit", "\\q":
    return "__EXIT__"
  of "version", "\\v":
    return "BaraDB v" & Version
  of "tables", "\\dt":
    return "No tables defined yet. Use CREATE TYPE to create types."
  of "history", "\\history":
    if state.history.len == 0:
      return "(no history)"
    var result = ""
    for i, h in state.history:
      result &= "  " & $(i + 1) & ": " & h & "\n"
    return result
  of "verbose":
    state.verbose = not state.verbose
    return "Verbose mode: " & (if state.verbose: "ON" else: "OFF")
  of "clear", "\\c":
    eraseScreen()
    cursorUp(999)
    return ""
  of "status", "\\conninfo":
    return "Database: " & state.database & "\nConnected: " & $state.connected
  else:
    if cmd.startsWith("describe ") or cmd.startsWith("\\d "):
      let typeName = cmd.split(" ")[^1]
      return "Type '" & typeName & "' not found."
    if cmd.startsWith("\\"):
      return "Unknown command: " & cmd & ". Type 'help' for help."

    # It's a query — validate syntax
    try:
      let tokens = tokenize(input)
      let ast = parse(tokens)
      if ast.stmts.len > 0:
        state.history.add(input)
        return "(query parsed OK — execution not connected)"
      else:
        return "(empty query)"
    except CatchableError as e:
      return "Syntax error: " & e.msg

proc runShell*() =
  printBanner()
  var state = newCliState()
  state.connected = true

  while true:
    styledWrite stdout, fgGreen, Prompt
    var input = readLine(stdin)

    if input.strip().len == 0:
      continue

    # Handle multi-line input (ending with ;)
    while not input.strip().endsWith(";") and
          not input.strip().toLower().in(["quit", "exit", "help", "tables",
                                          "history", "clear", "status", "verbose"]):
      styledWrite stdout, fgGreen, ContinuationPrompt
      var continuation = readLine(stdin)
      if continuation.strip().len == 0:
        break
      input &= " " & continuation

    let result = state.processCommand(input)
    if result == "__EXIT__":
      styledEcho fgYellow, "Goodbye!"
      break
    if result.len > 0:
      echo result
