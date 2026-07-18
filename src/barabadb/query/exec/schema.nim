## Schema catalog persistence — CREATE/DROP/ALTER survive restart
import std/strutils
import std/tables
import std/sequtils
import ../ast
import ../lexer as qlex
import ../parser as qpar
import ../../storage/lsm
import ../../storage/btree
import types
import values

const
  SchemaTablePrefix* = "_schema:tables:"
  SchemaViewPrefix* = "_schema:views:"
  SchemaTriggerPrefix* = "_schema:triggers:"
  SchemaUserPrefix* = "_schema:users:"
  SchemaPolicyPrefix* = "_schema:policies:"
  ## Legacy CREATE TABLE keys (pre-fix) used a migrations: counter suffix
  SchemaLegacyCreatePrefix* = "_schema:migrations:"

proc tableSchemaKey*(tableName: string): string =
  SchemaTablePrefix & tableName

proc litToString(node: Node): string =
  ## Evaluate simple literal defaults for schema materialization (no full expr engine).
  if node == nil: return ""
  case node.kind
  of nkStringLit: return node.strVal
  of nkIntLit: return $node.intVal
  of nkFloatLit: return $node.floatVal
  of nkBoolLit: return $node.boolVal
  of nkNullLit: return "\\N"
  else: return ""

proc serializeTableDdl*(tbl: TableDef): string =
  ## Stable DDL for a table definition (survives restart via LSM).
  var colDefs: seq[string] = @[]
  let multiPk = tbl.pkColumns.len > 1
  for col in tbl.columns:
    var parts: seq[string] = @[col.name, col.colType]
    if col.isPk and not multiPk:
      parts.add("PRIMARY KEY")
    if col.autoIncrement:
      parts.add("AUTO_INCREMENT")
    if col.isNotNull:
      parts.add("NOT NULL")
    if col.isUnique and not col.isPk:
      parts.add("UNIQUE")
    if col.defaultVal.len > 0:
      parts.add("DEFAULT '" & sqlEscapeString(col.defaultVal) & "'")
    if col.fkTable.len > 0:
      parts.add("REFERENCES " & col.fkTable & "(" & col.fkColumn & ")")
      if col.fkOnDelete.len > 0:
        parts.add("ON DELETE " & col.fkOnDelete)
      if col.fkOnUpdate.len > 0:
        parts.add("ON UPDATE " & col.fkOnUpdate)
    colDefs.add(parts.join(" "))
  if multiPk:
    colDefs.add("PRIMARY KEY (" & tbl.pkColumns.join(", ") & ")")
  result = "CREATE TABLE " & tbl.name & " (" & colDefs.join(", ") & ")"

proc persistTableSchema*(ctx: ExecutionContext, tbl: TableDef) =
  ## Write table DDL under a stable key so restore finds it after flush/restart.
  let ddl = serializeTableDdl(tbl)
  ctx.db.put(tableSchemaKey(tbl.name), cast[seq[byte]](ddl))

proc dropTableSchema*(ctx: ExecutionContext, tableName: string) =
  ctx.db.delete(tableSchemaKey(tableName))

proc applyCreateTableStmt*(ctx: ExecutionContext, stmt: Node) =
  ## Materialize CREATE TABLE AST into ctx.tables + empty secondary indexes.
  var tbl = TableDef(name: stmt.crtName, columns: @[], pkColumns: @[],
                     foreignKeys: @[], checks: @[], triggers: @[])
  for col in stmt.crtColumns:
    if col.kind == nkColumnDef:
      var colDef = ColumnDef(name: col.cdName, colType: col.cdType)
      colDef.autoIncrement = col.cdAutoIncrement
      for cst in col.cdConstraints:
        if cst.kind == nkConstraintDef:
          case cst.cstType
          of "pkey":
            colDef.isPk = true
            if col.cdName notin tbl.pkColumns:
              tbl.pkColumns.add(col.cdName)
            ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
          of "notnull": colDef.isNotNull = true
          of "unique":
            colDef.isUnique = true
            ctx.btrees[stmt.crtName & "." & col.cdName] = newBTreeIndex[string, IndexEntry]()
          of "default":
            if cst.cstDefault != nil:
              colDef.defaultVal = litToString(cst.cstDefault)
          of "fkey":
            colDef.fkTable = cst.cstRefTable
            colDef.fkColumn = if cst.cstRefColumns.len > 0: cst.cstRefColumns[0] else: ""
            colDef.fkOnDelete = cst.cstOnDelete
            colDef.fkOnUpdate = cst.cstOnUpdate
          else: discard
      tbl.columns.add(colDef)
  # Table-level constraints
  for cstNode in stmt.crtConstraints:
    if cstNode.kind == nkConstraintDef:
      if cstNode.cstType == "pkey":
        for c in cstNode.cstColumns:
          if c notin tbl.pkColumns:
            tbl.pkColumns.add(c)
          for i, col in tbl.columns:
            if col.name == c:
              tbl.columns[i].isPk = true
              let idxName = stmt.crtName & "." & c
              if idxName notin ctx.btrees:
                ctx.btrees[idxName] = newBTreeIndex[string, IndexEntry]()
      elif cstNode.cstType == "fkey":
        tbl.foreignKeys.add(ForeignKeyDef(
          refTable: cstNode.cstRefTable,
          refColumn: if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: "",
          onDelete: cstNode.cstOnDelete,
          onUpdate: cstNode.cstOnUpdate))
        if cstNode.cstColumns.len > 0:
          for i, c in tbl.columns:
            if c.name in cstNode.cstColumns:
              tbl.columns[i].fkTable = cstNode.cstRefTable
              tbl.columns[i].fkColumn = if cstNode.cstRefColumns.len > 0: cstNode.cstRefColumns[0] else: ""
              tbl.columns[i].fkOnDelete = cstNode.cstOnDelete
              tbl.columns[i].fkOnUpdate = cstNode.cstOnUpdate
      elif cstNode.cstType == "check":
        tbl.checks.add(CheckDef(name: "check_" & $tbl.checks.len, checkNode: cstNode.cstCheck))
  ctx.tables[stmt.crtName] = tbl

proc rebuildSecondaryIndexes*(ctx: ExecutionContext) =
  ## Rebuild in-memory B-Tree indexes from durable row data after schema restore.
  for tableName, tbl in ctx.tables.pairs:
    for col in tbl.columns:
      if col.isPk or col.isUnique:
        let idxName = tableName & "." & col.name
        if idxName notin ctx.btrees:
          ctx.btrees[idxName] = newBTreeIndex[string, IndexEntry]()
    let prefix = tableName & "."
    for (key, value) in ctx.db.scanAll():
      if not key.startsWith(prefix): continue
      if key.startsWith("_schema:"): continue
      let valStr = cast[string](value)
      let rest = key[prefix.len..^1]
      var colVals = initTable[string, string]()
      let eqPos = rest.find('=')
      if eqPos >= 0 and ':' notin rest:
        colVals[rest[0..<eqPos]] = rest[eqPos+1..^1]
      else:
        for part in rest.split(':'):
          let p = part.find('=')
          if p >= 0:
            colVals[part[0..<p]] = part[p+1..^1]
      for k, v in parseRowData(valStr):
        colVals[k] = v
      for colName in ctx.btrees.keys.toSeq():
        if not colName.startsWith(prefix): continue
        let colsPart = colName[tableName.len + 1..^1]
        let idxCols = colsPart.split(".")
        var parts: seq[string] = @[]
        for c in idxCols:
          parts.add(colVals.getOrDefault(c, ""))
        let idxVal = parts.join("|")
        if idxVal.len > 0 and not isNull(idxVal):
          ctx.btrees[colName].insert(idxVal, IndexEntry(lsmKey: key, rowValue: valStr))

proc restoreSchema*(ctx: ExecutionContext) =
  ## Load durable schema from LSM (memtable + SSTables). Stable keys only.
  var tableDdls: seq[string] = @[]
  var otherDdls: seq[string] = @[]

  for (key, value) in ctx.db.scanAll():
    if not key.startsWith("_schema:"): continue
    let ddl = cast[string](value)
    if ddl.len == 0: continue
    if key.startsWith(SchemaTablePrefix):
      tableDdls.add(ddl)
    elif key.startsWith(SchemaLegacyCreatePrefix) and ddl.toUpperAscii().startsWith("CREATE TABLE"):
      tableDdls.add(ddl)
    elif key.startsWith(SchemaViewPrefix) or key.startsWith(SchemaTriggerPrefix) or
         key.startsWith(SchemaUserPrefix) or key.startsWith(SchemaPolicyPrefix):
      otherDdls.add(ddl)
    elif ddl.toUpperAscii().startsWith("CREATE VIEW") or
         ddl.toUpperAscii().startsWith("CREATE TRIGGER") or
         ddl.toUpperAscii().startsWith("CREATE USER") or
         ddl.toUpperAscii().startsWith("CREATE POLICY"):
      otherDdls.add(ddl)

  for ddl in tableDdls:
    try:
      let tokens = qlex.tokenize(ddl)
      let astNode = qpar.parse(tokens)
      if astNode.stmts.len > 0 and astNode.stmts[0].kind == nkCreateTable:
        applyCreateTableStmt(ctx, astNode.stmts[0])
        if astNode.stmts[0].crtName in ctx.tables:
          persistTableSchema(ctx, ctx.tables[astNode.stmts[0].crtName])
    except CatchableError:
      continue

  for ddl in otherDdls:
    var astNode: Node
    try:
      let tokens = qlex.tokenize(ddl)
      astNode = qpar.parse(tokens)
    except CatchableError:
      continue
    if astNode.stmts.len == 0: continue
    let stmt = astNode.stmts[0]
    case stmt.kind
    of nkCreateView:
      ctx.views[stmt.cvName] = stmt.cvQuery
    of nkCreateTrigger:
      if stmt.trigTable in ctx.tables:
        ctx.tables[stmt.trigTable].triggers.add(TriggerDef(
          name: stmt.trigName,
          timing: stmt.trigTiming,
          event: stmt.trigEvent,
          action: stmt.trigAction,
        ))
    of nkCreateUser:
      ctx.users[stmt.cuName] = UserDef(name: stmt.cuName,
          passwordHash: stmt.cuPassword, isSuperuser: stmt.cuSuperuser, roles: @[])
    of nkCreatePolicy:
      var pols = ctx.policies.getOrDefault(stmt.cpTable)
      pols.add(PolicyDef(name: stmt.cpName, tableName: stmt.cpTable,
                         command: stmt.cpCommand, usingExpr: stmt.cpUsing,
                         withCheckExpr: stmt.cpWithCheck))
      ctx.policies[stmt.cpTable] = pols
    else: discard

  rebuildSecondaryIndexes(ctx)
