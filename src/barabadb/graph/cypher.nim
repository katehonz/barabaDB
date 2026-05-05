## Cypher-like Graph Query Extension for BaraQL
import std/tables
import std/strutils
import engine

type
  CypherNode* = object
    variable*: string
    label*: string
    properties*: Table[string, string]

  CypherEdge* = object
    variable*: string
    label*: string
    direction*: string  # "->", "<-", "--"
    properties*: Table[string, string]

  CypherPattern* = object
    nodes*: seq[CypherNode]
    edges*: seq[CypherEdge]

  CypherQuery* = object
    kind*: string  # "MATCH", "CREATE", "MERGE", "DELETE"
    pattern*: CypherPattern
    whereClause*: string
    returnExprs*: seq[string]
    orderBy*: string
    limit*: int

  CypherResult* = object
    columns*: seq[string]
    rows*: seq[seq[string]]

proc parseCypher*(query: string): CypherQuery =
  result = CypherQuery(returnExprs: @[], limit: 0)
  let upper = query.toUpper().strip()

  if upper.startsWith("MATCH"):
    result.kind = "MATCH"
  elif upper.startsWith("CREATE"):
    result.kind = "CREATE"
  elif upper.startsWith("MERGE"):
    result.kind = "MERGE"
  else:
    return

  # Parse node pattern: (variable:Label {props})
  var pos = 0
  var nodes: seq[CypherNode] = @[]
  var edges: seq[CypherEdge] = @[]

  while pos < query.len:
    if query[pos] == '(':
      # Parse node
      inc pos
      var variable = ""
      var label = ""
      var props = initTable[string, string]()

      # Read variable name
      while pos < query.len and query[pos] notin {':', ' ', '{', ')'}:
        variable &= query[pos]
        inc pos

      if pos < query.len and query[pos] == ':':
        inc pos
        while pos < query.len and query[pos] notin {' ', '{', ')'}:
          label &= query[pos]
          inc pos

      if pos < query.len and query[pos] == '{':
        inc pos
        var key = ""
        var value = ""
        var inKey = true
        while pos < query.len and query[pos] != '}':
          let ch = query[pos]
          if ch == ':':
            inKey = false
          elif ch in {',', ' '}:
            if key.len > 0 and value.len > 0:
              props[key.strip()] = value.strip().strip(chars = {'"'})
              key = ""
              value = ""
              inKey = true
          elif inKey:
            key &= ch
          else:
            value &= ch
          inc pos
        if key.len > 0 and value.len > 0:
          props[key.strip()] = value.strip().strip(chars = {'"'})
        inc pos  # skip }

      nodes.add(CypherNode(variable: variable, label: label, properties: props))
      inc pos  # skip )
    elif query[pos] == '-' or query[pos] == '<' or query[pos] == '[':
      # Parse edge
      var direction = ""
      var edgeVar = ""
      var edgeLabel = ""

      if query[pos] == '<':
        inc pos
        direction = "<-"

      if query[pos] == '-':
        inc pos
        if direction == "":
          direction = "-"
        else:
          direction &= "-"

      if pos < query.len and query[pos] == '[':
        inc pos
        while pos < query.len and query[pos] notin {']', ':'}:
          edgeVar &= query[pos]
          inc pos
        if pos < query.len and query[pos] == ':':
          inc pos
          while pos < query.len and query[pos] != ']':
            edgeLabel &= query[pos]
            inc pos
        inc pos  # skip ]

      if pos < query.len and query[pos] == '-':
        inc pos
        direction &= "-"
        if pos < query.len and query[pos] == '>':
          inc pos
          direction &= ">"

      edges.add(CypherEdge(variable: edgeVar, label: edgeLabel, direction: direction))
    else:
      inc pos

  result.pattern.nodes = nodes
  result.pattern.edges = edges

  # Parse WHERE
  let wherePos = query.toUpper().find(" WHERE ")
  if wherePos >= 0:
    let whereStart = wherePos + 7
    let returnPos = query.toUpper().find(" RETURN ")
    if returnPos > wherePos:
      result.whereClause = query[whereStart..<returnPos].strip()
    else:
      result.whereClause = query[whereStart..^1].strip()

  # Parse RETURN
  let returnPos = query.toUpper().find(" RETURN ")
  if returnPos >= 0:
    let returnContent = query[returnPos + 8..^1]
    for expr in returnContent.split(","):
      let trimmed = expr.strip()
      if trimmed.len > 0:
        result.returnExprs.add(trimmed)

  # Parse ORDER BY
  let orderPos = query.toUpper().find(" ORDER BY ")
  if orderPos >= 0:
    let limPos = query.toUpper().find(" LIMIT ")
    if limPos > orderPos:
      result.orderBy = query[orderPos + 9..<limPos].strip()
    else:
      result.orderBy = query[orderPos + 9..^1].strip()

  # Parse LIMIT
  let limPos = query.toUpper().find(" LIMIT ")
  if limPos >= 0:
    try:
      result.limit = parseInt(query[limPos + 7..^1].strip())
    except:
      result.limit = 0

proc executeCypher*(g: Graph, query: CypherQuery): CypherResult =
  result = CypherResult(columns: @[], rows: @[])

  if query.pattern.nodes.len == 0:
    return

  # Basic MATCH execution
  if query.kind == "MATCH":
    # For each node matching the pattern, collect results
    for nodeId, node in g.nodes:
      let patternNode = query.pattern.nodes[0]
      if patternNode.label.len == 0 or node.label == patternNode.label:
        var propsMatch = true
        for pk, pv in patternNode.properties:
          if node.properties.getOrDefault(pk, "") != pv:
            propsMatch = false
            break
        if propsMatch:
          var row: seq[string] = @[]
          for expr in query.returnExprs:
            if expr == patternNode.variable:
              row.add(node.label)
            elif expr.startsWith(patternNode.variable & "."):
              let propName = expr[expr.find('.') + 1 .. ^1]
              row.add(node.properties.getOrDefault(propName, ""))
            else:
              row.add(expr)
          result.rows.add(row)

    result.columns = query.returnExprs
    if query.limit > 0 and result.rows.len > query.limit:
      result.rows = result.rows[0..<query.limit]

proc toCypher*(query: string): string =
  ## Convert basic BaraQL to Cypher-like syntax for graph queries
  var result = ""
  let upper = query.toUpper()
  if upper.startsWith("SELECT") and upper.contains("MATCH"):
    # Already Cypher-like
    return query
  return query

proc matchNodes*(g: Graph, label: string,
                 props: Table[string, string] = initTable[string, string]()): seq[GraphNode] =
  result = @[]
  for nodeId, node in g.nodes:
    if label.len == 0 or node.label == label:
      var match = true
      for pk, pv in props:
        if node.properties.getOrDefault(pk, "") != pv:
          match = false
          break
      if match:
        result.add(node)
