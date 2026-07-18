## Executor types — shared by all exec/* modules and executor.nim
import std/tables
import std/locks
import ../ast
import ../ir
import ../../core/types
import ../../storage/lsm
import ../../storage/btree
import ../../core/mvcc
import ../../fts/engine as fts
import ../../vector/engine as vengine
import ../../graph/engine as gengine
import ../../ai/embed as embedmod
import ../../ai/llm as llmmod
import ../../core/registry

type
  IndexEntry* = ref object
    lsmKey*: string
    rowValue*: string

  ChangeKind* = enum
    ckInsert, ckUpdate, ckDelete

  ChangeEvent* = object
    table*: string
    kind*: ChangeKind
    key*: string
    data*: string

  UserDef* = object
    name*: string
    passwordHash*: string
    isSuperuser*: bool
    roles*: seq[string]

  PrivilegeDef* = object
    tableName*: string
    command*: string  # SELECT, INSERT, UPDATE, DELETE, ALL

  PolicyDef* = object
    name*: string
    tableName*: string
    command*: string   # ALL, SELECT, INSERT, UPDATE, DELETE
    usingExpr*: Node   # parsed USING expression
    withCheckExpr*: Node  # parsed WITH CHECK expression

  SharedLock* = ref object
    lock*: Lock

  ForeignKeyDef* = object
    refTable*: string
    refColumn*: string
    onDelete*: string  # CASCADE, SET NULL, RESTRICT
    onUpdate*: string  # CASCADE, SET NULL, RESTRICT

  CheckDef* = object
    name*: string
    expr*: string  # stored expression string
    checkNode*: Node  # AST for runtime evaluation

  TriggerDef* = object
    name*: string
    timing*: string   # BEFORE, AFTER
    event*: string    # INSERT, UPDATE, DELETE
    action*: Node     # SQL statement AST

  ColumnDef* = object
    name*: string
    colType*: string
    isPk*: bool
    isNotNull*: bool
    isUnique*: bool
    defaultVal*: string
    fkTable*: string
    fkColumn*: string
    fkOnDelete*: string
    fkOnUpdate*: string
    autoIncrement*: bool

  TableDef* = object
    name*: string
    columns*: seq[ColumnDef]
    pkColumns*: seq[string]
    foreignKeys*: seq[ForeignKeyDef]
    checks*: seq[CheckDef]
    triggers*: seq[TriggerDef]

  Row* = Table[string, Value]

  ExecutionContext* = ref object
    db*: LSMTree
    tables*: Table[string, TableDef]
    btrees*: Table[string, BTreeIndex[string, IndexEntry]]
    views*: Table[string, Node]  # view name -> SELECT AST
    cteTables*: Table[string, seq[Row]]  # CTE name -> rows
    ftsIndexes*: Table[string, fts.InvertedIndex]  # table.col -> FTS index
    vectorIndexes*: Table[string, vengine.HNSWIndex]  # table.col -> HNSW index
    graphs*: Table[string, gengine.Graph]  # graph name -> Graph object
    embedder*: embedmod.Embedder  # optional embedding service client
    llmClient*: llmmod.LLMClient  # optional LLM client for NL->SQL
    txnManager*: TxnManager
    pendingTxn*: Transaction
    onChange*: proc(ev: ChangeEvent) {.closure.}
    users*: Table[string, UserDef]
    policies*: Table[string, seq[PolicyDef]]  # table name -> policies
    currentUser*: string
    currentRole*: string
    sessionVars*: Table[string, string]
    autoIncCounters*: Table[string, int64]
    sequences*: Table[string, int64]
    sharedLock*: SharedLock  # shared across cloned contexts
    outerRow*: Table[string, string]  # outer query row for correlated subqueries
    subqueryPlan*: IRPlan  # current subquery plan being evaluated
    currentDatabase*: string  # name of the currently selected database
    registry*: DatabaseRegistry  # nil for single-DB mode

  MigrationRecord* = object
    name*: string
    checksum*: string
    appliedAt*: int64
    appliedBy*: string
    durationMs*: int
    rolledBack*: bool

  ExecResult* = object
    success*: bool
    columns*: seq[string]
    rows*: seq[Row]
    affectedRows*: int
    message*: string
    keyValuePairs*: seq[(string, seq[byte])]

proc `==`*(a, b: IndexEntry): bool =
  a.lsmKey == b.lsmKey and a.rowValue == b.rowValue

proc okResult*(rows: seq[Row] = @[], cols: seq[string] = @[], affected: int = 0, msg: string = "",
               kvPairs: seq[(string, seq[byte])] = @[]): ExecResult =
  ExecResult(success: true, columns: cols, rows: rows, affectedRows: affected, message: msg,
             keyValuePairs: kvPairs)

proc errResult*(msg: string): ExecResult =
  ExecResult(success: false, columns: @[], rows: @[], affectedRows: 0, message: msg)
