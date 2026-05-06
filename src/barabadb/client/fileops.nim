## Import/Export — JSON, CSV, Parquet-like formats
import std/strutils
import std/sequtils

type
  ExportFormat* = enum
    efJson = "json"
    efCsv = "csv"
    efNdjson = "ndjson"  # newline-delimited JSON

  ImportFormat* = enum
    ifJson = "json"
    ifCsv = "csv"
    ifNdjson = "ndjson"

  ExportOptions* = object
    format*: ExportFormat
    delimiter*: char
    includeHeader*: bool
    nullValue*: string
    dateFormat*: string

  ImportOptions* = object
    format*: ImportFormat
    delimiter*: char
    hasHeader*: bool
    nullValue*: string
    skipRows*: int
    maxRows*: int

proc defaultExportOptions*(): ExportOptions =
  ExportOptions(format: efJson, delimiter: ',', includeHeader: true,
                nullValue: "", dateFormat: "yyyy-MM-dd")

proc defaultImportOptions*(): ImportOptions =
  ImportOptions(format: ifJson, delimiter: ',', hasHeader: true,
                nullValue: "", skipRows: 0, maxRows: -1)

# JSON export
proc toJson*(columns: seq[string], rows: seq[seq[string]]): string =
  var items: seq[string] = @[]
  for row in rows:
    var fields: seq[string] = @[]
    for i, col in columns:
      let val = if i < row.len: row[i] else: ""
      fields.add("\"" & col & "\": \"" & val.replace("\"", "\\\"") & "\"")
    items.add("{" & fields.join(", ") & "}")
  return "[" & items.join(",\n  ") & "]"

proc toJsonLines*(columns: seq[string], rows: seq[seq[string]]): string =
  result = ""
  for row in rows:
    var fields: seq[string] = @[]
    for i, col in columns:
      let val = if i < row.len: row[i] else: ""
      fields.add("\"" & col & "\": \"" & val.replace("\"", "\\\"") & "\"")
    result &= "{" & fields.join(", ") & "}\n"

# CSV export
proc toCsv*(columns: seq[string], rows: seq[seq[string]],
            delimiter: char = ',', includeHeader: bool = true): string =
  result = ""
  if includeHeader:
    result &= columns.join($delimiter) & "\n"
  for row in rows:
    var fields: seq[string] = @[]
    for val in row:
      if val.contains(delimiter) or val.contains('"') or val.contains('\n'):
        fields.add("\"" & val.replace("\"", "\"\"") & "\"")
      else:
        fields.add(val)
    result &= fields.join($delimiter) & "\n"

# JSON import
proc parseJsonTable*(json: string): (seq[string], seq[seq[string]]) =
  var columns: seq[string] = @[]
  var rows: seq[seq[string]] = @[]

  # Simple JSON array parser
  let trimmed = json.strip()
  if not trimmed.startsWith("["):
    return (columns, rows)

  # Find first object to extract columns
  let firstObjStart = trimmed.find('{')
  let firstObjEnd = trimmed.find('}', firstObjStart)
  if firstObjStart < 0 or firstObjEnd < 0:
    return (columns, rows)

  let firstObj = trimmed[firstObjStart+1 .. firstObjEnd-1]
  for pair in firstObj.split(","):
    let kv = pair.split(":", 1)
    if kv.len == 2:
      columns.add(kv[0].strip().strip(chars = {'"'}))

  # Parse all objects
  var pos = 0
  while pos < trimmed.len:
    let objStart = trimmed.find('{', pos)
    if objStart < 0:
      break
    let objEnd = trimmed.find('}', objStart)
    if objEnd < 0:
      break
    let obj = trimmed[objStart+1 .. objEnd-1]
    var row: seq[string] = @[]
    for pair in obj.split(","):
      let kv = pair.split(":", 1)
      if kv.len == 2:
        row.add(kv[1].strip().strip(chars = {'"'}))
    rows.add(row)
    pos = objEnd + 1

  return (columns, rows)

# CSV import
proc parseCsvTable*(csv: string, delimiter: char = ',',
                    hasHeader: bool = true): (seq[string], seq[seq[string]]) =
  var columns: seq[string] = @[]
  var rows: seq[seq[string]] = @[]

  let lines = csv.splitLines()
  if lines.len == 0:
    return (columns, rows)

  var startLine = 0
  if hasHeader:
    columns = lines[0].split(delimiter).mapIt(it.strip().strip(chars = {'"'}))
    startLine = 1

  for i in startLine..<lines.len:
    let line = lines[i].strip()
    if line.len == 0:
      continue
    var row: seq[string] = @[]
    var field = ""
    var inQuotes = false
    for ch in line:
      if ch == '"':
        inQuotes = not inQuotes
      elif ch == delimiter and not inQuotes:
        row.add(field.strip())
        field = ""
      else:
        field &= ch
    row.add(field.strip())
    rows.add(row)

  # If no header, generate column names
  if not hasHeader and rows.len > 0:
    for i in 0..<rows[0].len:
      columns.add("column_" & $(i + 1))

  return (columns, rows)

# NDJSON export
proc toNdjson*(columns: seq[string], rows: seq[seq[string]]): string =
  result = ""
  for row in rows:
    var fields: seq[string] = @[]
    for i, col in columns:
      let val = if i < row.len: row[i] else: ""
      fields.add("\"" & col & "\": \"" & val.replace("\"", "\\\"") & "\"")
    result &= "{" & fields.join(", ") & "}\n"

# NDJSON import
proc parseNdjsonTable*(ndjson: string): (seq[string], seq[seq[string]]) =
  var columns: seq[string] = @[]
  var rows: seq[seq[string]] = @[]

  for line in ndjson.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or not trimmed.startsWith("{"):
      continue

    # Parse object fields
    let content = trimmed[1..^2]  # remove { }
    var row: seq[string] = @[]
    for pair in content.split(","):
      let kv = pair.split(":", 1)
      if kv.len == 2:
        let key = kv[0].strip().strip(chars = {'"'}).replace("\\\"", "\"")
        let val = kv[1].strip().strip(chars = {'"'}).replace("\\\"", "\"")
        if columns.len == 0 or columns.len <= rows.len:
          # First row: extract column names
          if rows.len == 0:
            columns.add(key)
        row.add(val)
    rows.add(row)

  return (columns, rows)

# Write to file
proc exportToFile*(path: string, columns: seq[string], rows: seq[seq[string]],
                   options: ExportOptions = defaultExportOptions()) =
  let content = case options.format
    of efJson: toJson(columns, rows)
    of efCsv: toCsv(columns, rows, options.delimiter, options.includeHeader)
    of efNdjson: toNdjson(columns, rows)
  writeFile(path, content)

# Read from file
proc importFromFile*(path: string, options: ImportOptions = defaultImportOptions()
                    ): (seq[string], seq[seq[string]]) =
  let content = readFile(path)
  case options.format
  of ifJson: return parseJsonTable(content)
  of ifCsv: return parseCsvTable(content, options.delimiter, options.hasHeader)
  of ifNdjson: return parseNdjsonTable(content)
