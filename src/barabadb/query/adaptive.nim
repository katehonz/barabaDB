## Adaptive Query Execution — runtime query plan adaptation
import std/tables
import std/monotimes
import std/algorithm
import std/strutils

type
  ExecutionStats* = object
    rowsRead*: int
    rowsWritten*: int
    ioOperations*: int
    cpuTime*: int64   # nanoseconds
    wallTime*: int64   # nanoseconds
    memoryUsed*: int   # bytes
    cacheHits*: int
    cacheMisses*: int

  AdaptiveConfig* = object
    enableAdaptive*: bool
    enableParallel*: bool
    maxParallelism*: int
    reoptimizeThreshold*: float64  # if cost estimate is off by X%, re-optimize
    learnCardinality*: bool
    collectStats*: bool

  QueryPlan* = ref object
    plan*: string
    estimatedCost*: float64
    estimatedRows*: int64
    actualCost*: float64
    actualRows*: int64
    stats*: ExecutionStats

  AdaptivePlanner* = ref object
    config: AdaptiveConfig
    planCache: Table[string, QueryPlan]  # query hash -> cached plan
    cardinalityEst: Table[string, float64]  # table -> estimated row count
    lastReoptimize: int64

proc defaultAdaptiveConfig*(): AdaptiveConfig =
  AdaptiveConfig(
    enableAdaptive: true,
    enableParallel: true,
    maxParallelism: 4,
    reoptimizeThreshold: 3.0,  # 3x cost difference triggers re-optimize
    learnCardinality: true,
    collectStats: true,
  )

proc newAdaptivePlanner*(config: AdaptiveConfig = defaultAdaptiveConfig()): AdaptivePlanner =
  AdaptivePlanner(
    config: config,
    planCache: initTable[string, QueryPlan](),
    cardinalityEst: initTable[string, float64](),
    lastReoptimize: 0,
  )

proc hashQuery*(query: string): string =
  # Simple hash for plan caching
  var h: uint64 = 5381
  for ch in query:
    h = ((h shl 5) + h) + uint64(ord(ch))
  return $h

proc updateCardinality*(planner: AdaptivePlanner, table: string, rowCount: int64) =
  if planner.config.learnCardinality:
    if table in planner.cardinalityEst:
      # Exponential moving average
      let alpha: float64 = 0.3
      planner.cardinalityEst[table] = alpha * float64(rowCount) +
                                       (1.0 - alpha) * planner.cardinalityEst[table]
    else:
      planner.cardinalityEst[table] = float64(rowCount)

proc estimateRows*(planner: AdaptivePlanner, table: string): int64 =
  if table in planner.cardinalityEst:
    return int64(planner.cardinalityEst[table])
  return 1000  # default estimate

proc shouldReoptimize*(planner: AdaptivePlanner, estimatedRowCount, actualRowCount: int64): bool =
  if not planner.config.enableAdaptive:
    return false
  if estimatedRowCount <= 0 or actualRowCount <= 0:
    return false
  let ratio = float64(actualRowCount) / float64(estimatedRowCount)
  return ratio > planner.config.reoptimizeThreshold or
         (1.0 / ratio) > planner.config.reoptimizeThreshold

proc beginExecution*(planner: AdaptivePlanner, plan: var QueryPlan): int64 =
  let start = getMonoTime().ticks()
  plan.stats = ExecutionStats()
  plan.stats.wallTime = start
  return start

proc endExecution*(planner: AdaptivePlanner, plan: var QueryPlan) =
  plan.stats.wallTime = getMonoTime().ticks() - plan.stats.wallTime
  plan.actualCost = float64(plan.stats.wallTime) / 1_000_000_000.0

proc cachePlan*(planner: AdaptivePlanner, query: string, plan: QueryPlan) =
  let hash = hashQuery(query)
  planner.planCache[hash] = plan

proc getCachedPlan*(planner: AdaptivePlanner, query: string): QueryPlan =
  let hash = hashQuery(query)
  return planner.planCache.getOrDefault(hash, nil)

proc evictCache*(planner: AdaptivePlanner) =
  planner.planCache.clear()

proc cacheSize*(planner: AdaptivePlanner): int = planner.planCache.len

# Query execution contexts with parallelism hints
type
  ExecutionNode* = enum
    enScan
    enFilter
    enProject
    enJoin
    enAggregate
    enSort
    enLimit

  ParallelHint* = object
    canParallelize*: bool
    partitionKey*: string
    estimatedPartitions*: int
    dataSize*: int64  # bytes

  ExecutionContext* = ref object
    node*: ExecutionNode
    table*: string
    filterExpr*: string
    estimatedRows*: int64
    children*: seq[ExecutionContext]
    parallelHint*: ParallelHint
    completed*: bool

proc newExecutionContext*(node: ExecutionNode): ExecutionContext =
  ExecutionContext(node: node, children: @[], completed: false,
                   estimatedRows: 0)

proc addChild*(ctx: ExecutionContext, child: ExecutionContext) =
  ctx.children.add(child)

proc canParallelize*(ctx: ExecutionContext): bool =
  case ctx.node
  of enScan:
    return ctx.parallelHint.dataSize > 1_000_000  # parallelize if > 1MB
  of enFilter, enProject:
    return ctx.parallelHint.canParallelize
  of enJoin:
    # Hash joins can be parallelized
    return true
  of enAggregate:
    # Partial aggregation can be parallelized
    return ctx.parallelHint.estimatedPartitions > 1
  of enSort:
    return false  # Sorting is hard to parallelize
  of enLimit:
    return false

proc estimateParallelism*(ctx: ExecutionContext, maxParallel: int): int =
  if not ctx.canParallelize():
    return 1
  return min(ctx.parallelHint.estimatedPartitions, maxParallel)

proc totalCost*(ctx: ExecutionContext): float64 =
  result = 1.0
  for child in ctx.children:
    result += child.totalCost()
  case ctx.node
  of enScan: result *= 10.0
  of enFilter: result *= 2.0
  of enJoin: result *= 5.0
  of enSort: result *= 3.0
  of enAggregate: result *= 2.0
  else: result *= 1.0

proc explain*(ctx: ExecutionContext, indent: int = 0): string =
  result = " ".repeat(indent) & $ctx.node
  if ctx.table.len > 0:
    result &= " table=" & ctx.table
  result &= " rows=" & $ctx.estimatedRows
  if ctx.parallelHint.canParallelize:
    result &= " [parallel: " & $ctx.parallelHint.estimatedPartitions & "]"
  result &= "\n"
  for child in ctx.children:
    result &= child.explain(indent + 2)
