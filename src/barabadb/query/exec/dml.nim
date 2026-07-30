## DML row operations — INSERT/DELETE/UPDATE row-level execution.
##
## Extracted from `executor.nim` (Task 9 of the executor split).
import std/strutils
import std/tables
import std/sequtils
import ../../storage/lsm
import ../../storage/btree
import ../../core/types
import ../../core/mvcc
import ../../fts/engine as fts
import ../../vector/engine as vengine
import ../../graph/engine as gengine
import ../../ai/embed as embedmod
import types
import values
import helpers
import rls

# ----------------------------------------------------------------------
# Table storage
# ----------------------------------------------------------------------

proc execInsert*(ctx: ExecutionContext, table: string, fields: seq[string], values: seq[seq[string]],
                  kvPairs: var seq[(string, seq[byte])]): int =
  if not hasPrivilege(ctx, table, "INSERT"):
    return 0
  let tblDef = if table in ctx.tables: ctx.tables[table] else: TableDef()
  var count = 0
  for rowVals in values:
    var key = ""
    var keyFound = false
    var valParts: seq[string] = @[]
    # Build composite PK key from all PK columns
    if tblDef.pkColumns.len > 0:
      var pkParts: seq[string] = @[]
      for pkCol in tblDef.pkColumns:
        let pkVal = getValue(rowVals, fields, pkCol)
        pkParts.add(pkCol & "=" & escapeRowVal(pkVal))
      key = pkParts.join(":")
      keyFound = true
    for i, f in fields:
      if i < rowVals.len:
        if not keyFound:
          key = f & "=" & escapeRowVal(rowVals[i])
          keyFound = true
        elif tblDef.pkColumns.len == 0 or f.toLower() notin tblDef.pkColumns.mapIt(it.toLower()):
          valParts.add(f & "=" & escapeRowVal(rowVals[i]))
      elif f.len > 0:
        if tblDef.pkColumns.len == 0 or f.toLower() notin tblDef.pkColumns.mapIt(it.toLower()):
          valParts.add(f & "=")
    let valStr = valParts.join(",")
    let fullKey = table & "." & key

    # Build row for RLS WITH CHECK
    var row = initTable[string, Value]()
    for i, f in fields:
      if i < rowVals.len:
        row[f] = rowVals[i]
    if not checkInsertPolicy(ctx, table, row):
      continue

    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](valStr))
    else:
      ctx.db.put(fullKey, cast[seq[byte]](valStr))
      kvPairs.add((fullKey, cast[seq[byte]](valStr)))

    for colName in ctx.btrees.keys.toSeq():
      if colName.startsWith(table & "."):
        let colsPart = colName[table.len + 1..^1]
        let idxCols = colsPart.split(".")
        var colVals: seq[string] = @[]
        for c in idxCols:
          colVals.add(getValue(rowVals, fields, c))
        let idxVal = colVals.join("|")
        if idxVal.len > 0 and not isNull(idxVal):
          ctx.btrees[colName].insert(idxVal, IndexEntry(lsmKey: fullKey, rowValue: valStr))

    # Update FTS indexes
    for ftsKey, ftsIdx in ctx.ftsIndexes:
      if ftsKey.startsWith(table & "."):
        let colName = ftsKey[table.len + 1..^1]
        let text = getValue(rowVals, fields, colName)
        if text.len > 0:
          var docId: uint64 = 0
          for ch in fullKey:
            docId = docId * 31 + uint64(ord(ch))
          ftsIdx.addDocument(docId, text)

    # Update Vector indexes
    for vecKey, vecIdx in ctx.vectorIndexes:
      if vecKey.startsWith(table & "."):
        let colName = vecKey[table.len + 1..^1]
        let vecStr = getValue(rowVals, fields, colName)
        let vec = parseVectorString(vecStr)
        if vec.len > 0:
          var docId: uint64 = 0
          for ch in fullKey:
            docId = docId * 31 + uint64(ord(ch))
          var meta = initTable[string, string]()
          meta["key"] = fullKey
          for col, val in row:
            if col.len > 0 and col != "$key" and col != "$value":
              meta[col] = valueToString(val)
          vengine.insert(vecIdx, docId, vec, meta)

    # Auto-embed: if table has VECTOR column with null value but TEXT column
    # with content, and embedder is configured, generate embedding
    if ctx.embedder != nil and ctx.embedder.config.enabled:
      for vecKey in ctx.vectorIndexes.keys:
        if not vecKey.startsWith(table & "."): continue
        let vecCol = vecKey[table.len + 1..^1]
        let vecStr = getValue(rowVals, fields, vecCol)
        if vecStr.len == 0 or vecStr == "null" or vecStr == "[]":
          var sourceText = ""
          for i, f in fields:
            if i < rowVals.len and (f == "text" or f == "content" or f == "body"):
              sourceText = rowVals[i]
              break
          if sourceText.len > 0:
            let vec = embedmod.embed(ctx.embedder, sourceText)
            if vec.len > 0:
              let vecStr2 = "[" & vec.mapIt($it).join(",") & "]"
              var updateKey = ""
              var updateVals: seq[string] = @[]
              for i, f in fields:
                if i < rowVals.len:
                  if f == vecCol:
                    updateVals.add(f & "=" & escapeRowVal(vecStr2))
                  elif updateKey.len == 0:
                    updateKey = f & "=" & escapeRowVal(rowVals[i])
                  else:
                    updateVals.add(f & "=" & escapeRowVal(rowVals[i]))
                elif f == vecCol:
                  updateVals.add(f & "=" & escapeRowVal(vecStr2))
              if updateVals.len > 0:
                let fullKey = table & "." & updateKey
                let valStr = updateVals.join(",")
                if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
                  discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](valStr))
                else:
                  ctx.db.put(fullKey, cast[seq[byte]](valStr))
                var docId: uint64 = 0
                for ch in fullKey:
                  docId = docId * 31 + uint64(ord(ch))
                var meta = initTable[string, string]()
                meta["key"] = fullKey
                for col, val in row:
                  if col.len > 0 and col != "$key" and col != "$value":
                    meta[col] = valueToString(val)
                meta[vecCol] = vecStr2
                vengine.insert(ctx.vectorIndexes[vecKey], docId, vec, meta)

    # Update Graph objects for graph node/edge tables
    for graphName, graph in ctx.graphs:
      if table == graphName & "_nodes":
        var nodeIdStr = ""
        for i, f in fields:
          if f == "id" and i < rowVals.len:
            nodeIdStr = rowVals[i]
            break
        if nodeIdStr.len > 0:
          let nid = gengine.NodeId(parseUInt(nodeIdStr))
          var label = ""
          var props = initTable[string, string]()
          for i, f in fields:
            if i < rowVals.len:
              if f == "node_label":
                label = rowVals[i]
              elif f != "id" and f != "properties":
                props[f] = rowVals[i]
          try:
            gengine.addNodeWithId(graph, nid, label, props)
          except CatchableError:
            discard
      elif table == graphName & "_edges":
        var srcStr = ""
        var dstStr = ""
        var label = ""
        var weight = 1.0
        for i, f in fields:
          if i < rowVals.len:
            if f == "source_id": srcStr = rowVals[i]
            elif f == "dest_id": dstStr = rowVals[i]
            elif f == "edge_label": label = rowVals[i]
            elif f == "weight":
              try: weight = parseFloat(rowVals[i]) except CatchableError: discard
        if srcStr.len > 0 and dstStr.len > 0:
          let srcId = gengine.NodeId(parseUInt(srcStr))
          let dstId = gengine.NodeId(parseUInt(dstStr))
          try:
            gengine.addEdgeWithId(graph, srcId, dstId, label, weight)
          except CatchableError:
            discard

    inc count
  return count

proc execDelete*(ctx: ExecutionContext, table: string, key: string,
                  kvPairs: var seq[(string, seq[byte])]): int =
  if not hasPrivilege(ctx, table, "DELETE"):
    return 0
  let fullKey = table & "." & key
  let (found, existingVal) = ctx.db.get(fullKey)
  if found:
    # RLS USING check on existing row
    var oldRow = parseRowDataToValueRow(cast[string](existingVal))
    let eqPos = key.find('=')
    if eqPos >= 0:
      oldRow[key[0..<eqPos]] = key[eqPos+1..^1]
    if not passesPolicy(ctx, table, "DELETE", oldRow):
      return 0
    if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
      discard ctx.txnManager.delete(ctx.pendingTxn, fullKey)
    else:
      ctx.db.delete(fullKey)
      kvPairs.add((fullKey, @[]))
    # Update BTree indexes
    for colName in ctx.btrees.keys.toSeq():
      if colName.startsWith(table & "."):
        let colsPart = colName[table.len + 1..^1]
        let idxCols = colsPart.split(".")
        var oldVals: seq[string] = @[]
        for c in idxCols:
          if c in oldRow:
            oldVals.add(valueToString(oldRow[c]))
          else:
            oldVals.add("\\N")
        let oldIdxVal = oldVals.join("|")
        if oldIdxVal.len > 0 and not isNull(oldIdxVal):
          ctx.btrees[colName].remove(oldIdxVal, IndexEntry(lsmKey: fullKey, rowValue: cast[string](existingVal)))
    # Update FTS indexes
    for ftsKey, ftsIdx in ctx.ftsIndexes:
      if ftsKey.startsWith(table & "."):
        var docId: uint64 = 0
        for ch in fullKey:
          docId = docId * 31 + uint64(ord(ch))
        ftsIdx.removeDocument(docId)
    return 1
  return 0

proc execUpdateRow*(ctx: ExecutionContext, table: string, key: string, sets: Table[string, string],
                     kvPairs: var seq[(string, seq[byte])]): int =
  if not hasPrivilege(ctx, table, "UPDATE"):
    return 0
  let fullKey = table & "." & key
  let (found, existing) = ctx.db.get(fullKey)
  if not found: return 0
  var oldRow = parseRowDataToValueRow(cast[string](existing))
  let eqPos = key.find('=')
  if eqPos >= 0:
    oldRow[key[0..<eqPos]] = key[eqPos+1..^1]
  # RLS USING check on old row
  if not passesPolicy(ctx, table, "UPDATE", oldRow):
    return 0
  var parsed = parseRowDataToValueRow(cast[string](existing))
  for col, val in sets:
    parsed[col] = val
  # RLS WITH CHECK on new row
  if not checkInsertPolicy(ctx, table, parsed):
    return 0
  var parts: seq[string] = @[]
  for col, val in parsed:
    parts.add(col & "=" & escapeRowVal(valueToString(val)))
  let newVal = parts.join(",")
  # Update indexes: remove old, insert new
  for colName in ctx.btrees.keys.toSeq():
    if colName.startsWith(table & "."):
      let colsPart = colName[table.len + 1..^1]
      let idxCols = colsPart.split(".")
      var oldVals: seq[string] = @[]
      var newVals: seq[string] = @[]
      for c in idxCols:
        if c in oldRow:
          oldVals.add(valueToString(oldRow[c]))
        else:
          oldVals.add("\\N")
        if c in parsed:
          newVals.add(valueToString(parsed[c]))
        else:
          newVals.add("\\N")
      let oldIdxVal = oldVals.join("|")
      if oldIdxVal.len > 0 and not isNull(oldIdxVal):
        ctx.btrees[colName].remove(oldIdxVal, IndexEntry(lsmKey: fullKey, rowValue: cast[string](existing)))
      let newIdxVal = newVals.join("|")
      if newIdxVal.len > 0 and not isNull(newIdxVal):
        ctx.btrees[colName].insert(newIdxVal, IndexEntry(lsmKey: fullKey, rowValue: newVal))
  if ctx.pendingTxn != nil and ctx.pendingTxn.state == tsActive:
    discard ctx.txnManager.write(ctx.pendingTxn, fullKey, cast[seq[byte]](newVal))
  else:
    ctx.db.put(fullKey, cast[seq[byte]](newVal))
    kvPairs.add((fullKey, cast[seq[byte]](newVal)))
  # Update FTS indexes: remove old doc, add new
  for ftsKey, ftsIdx in ctx.ftsIndexes:
    if ftsKey.startsWith(table & "."):
      var docId: uint64 = 0
      for ch in fullKey:
        docId = docId * 31 + uint64(ord(ch))
      ftsIdx.removeDocument(docId)
      let colName = ftsKey[table.len + 1..^1]
      let newText = if colName in parsed: parsed[colName] else: Value(kind: vkNull)
      if newText.kind == vkString and newText.strVal.len > 0:
        ftsIdx.addDocument(docId, newText.strVal)
  # Update Vector indexes: add new vector (no remove support in current HNSW)
  for vecKey, vecIdx in ctx.vectorIndexes:
    if vecKey.startsWith(table & "."):
      let colName = vecKey[table.len + 1..^1]
      let vecStr = if colName in parsed: parsed[colName] else: Value(kind: vkNull)
      if vecStr.kind == vkString and vecStr.strVal.len > 0:
        let vec = parseVectorString(vecStr.strVal)
        if vec.len > 0:
          var docId: uint64 = 0
          for ch in fullKey:
            docId = docId * 31 + uint64(ord(ch))
          var meta = initTable[string, string]()
          meta["key"] = fullKey
          vengine.insert(vecIdx, docId, vec, meta)
  return 1
