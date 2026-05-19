## Stress Test — parallel workloads against shared LSM-Tree
## Validates correctness under concurrent access.
import std/os
import std/random
import std/strutils
import std/times
import std/monotimes
import std/locks
import barabadb/storage/lsm

const
  NumWorkers = 16
  OpsPerWorker = 2000
  KeySpace = 1000

type
  WorkerArgs = tuple
    workerId: int
    db: ptr LSMTree
    errors: ptr int
    lock: ptr Lock

randomize()

proc runWorker(args: WorkerArgs) {.thread.} =
  var localErrors = 0
  var rng = initRand(args.workerId)

  for i in 0 ..< OpsPerWorker:
    let op = rng.rand(0 .. 3)
    let key = "key_" & $(rng.rand(0 ..< KeySpace))
    let value = cast[seq[byte]]("val_" & $i & "_" & $args.workerId)

    case op
    of 0:
      # Put
      acquire(args.lock[])
      try:
        args.db[].put(key, value)
      except:
        localErrors.inc
      finally:
        release(args.lock[])
    of 1:
      # Get and verify (if found, value should be from some worker)
      acquire(args.lock[])
      var found = false
      var val: seq[byte]
      try:
        (found, val) = args.db[].get(key)
      except:
        localErrors.inc
      finally:
        release(args.lock[])
      if found:
        let valStr = cast[string](val)
        if not valStr.startsWith("val_"):
          localErrors.inc
    of 2:
      # Delete
      acquire(args.lock[])
      try:
        args.db[].delete(key)
      except:
        localErrors.inc
      finally:
        release(args.lock[])
    of 3:
      # Overwrite
      acquire(args.lock[])
      try:
        args.db[].put(key, value)
      except:
        localErrors.inc
      finally:
        release(args.lock[])
    else:
      discard

  args.errors[] = localErrors

proc main() =
  let baseDir = "/tmp/baradb_stress_test_shared"
  removeDir(baseDir)
  createDir(baseDir)

  let start = getMonoTime()

  # Single shared database
  var db = newLSMTree(baseDir)
  var dbPtr = addr db
  var dbLock: Lock
  initLock(dbLock)
  var lockPtr = addr dbLock

  # Run workers in parallel using std/threads
  var threadArr: array[NumWorkers, Thread[WorkerArgs]]
  var errorCounts: array[NumWorkers, int]

  for i in 0 ..< NumWorkers:
    let args: WorkerArgs = (workerId: i, db: dbPtr, errors: addr errorCounts[i], lock: lockPtr)
    createThread(threadArr[i], runWorker, args)

  var totalErrors = 0
  for i in 0 ..< NumWorkers:
    joinThread(threadArr[i])
    totalErrors += errorCounts[i]

  # Verify: scan all keys and ensure no corruption
  var scanErrors = 0
  for k in 0 ..< KeySpace:
    let key = "key_" & $k
    let (found, val) = db.get(key)
    if found:
      let valStr = cast[string](val)
      if not valStr.startsWith("val_"):
        scanErrors.inc

  db.close()

  let elapsed = (getMonoTime() - start).inMilliseconds
  let totalOps = NumWorkers * OpsPerWorker

  echo "Stress test completed: ", totalOps, " ops across ", NumWorkers, " workers"
  echo "Time: ", elapsed, " ms"
  echo "Throughput: ", float(totalOps) / (float(elapsed) / 1000.0), " ops/sec"
  echo "Runtime errors: ", totalErrors
  echo "Scan errors: ", scanErrors

  if totalErrors > 0 or scanErrors > 0:
    quit(1)

  removeDir(baseDir)

main()
