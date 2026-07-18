## Global storage gate — exclusive multi-thread entry to LSM / executor.
##
## Why: Hunos HTTP runs handlers on a worker-thread pool (`spawn` + internal
## workers). The TCP server runs on the main async loop. Both share the same
## `LSMTree` / `ExecutionContext` refs. Nim's default ORC memory manager is not
## safe for concurrent refcount ops on the same objects from multiple OS threads.
##
## Holding this gate for the full duration of a query/compaction/DDL ensures
## only one thread mutates or reads GC-managed storage state at a time.
##
## Ordering: always acquire StorageGate **before** any per-DB `LSMTree.lock`.
## Call `initStorageGate()` once from main before accepting connections.
import std/locks

var
  gGate: Lock
  gInited*: bool

proc initStorageGate*() =
  ## Idempotent when called from a single thread at startup.
  if not gInited:
    initLock(gGate)
    gInited = true

proc acquireStorageGate*() {.inline.} =
  ## Prefer calling initStorageGate() once at process start (main).
  ## Lazy-init is allowed for unit tests (single-threaded).
  if not gInited:
    initStorageGate()
  acquire(gGate)

proc releaseStorageGate*() {.inline.} =
  release(gGate)

template withStorageGate*(body: untyped) =
  ## Exclusive ownership of the storage engine for `body`.
  acquireStorageGate()
  try:
    body
  finally:
    releaseStorageGate()
