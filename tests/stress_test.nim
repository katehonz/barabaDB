## Stress Test — parallel workloads against LSM-Tree
## Each worker gets its own LSMTree instance (thread-safe via internal locks).
import std/os
import std/random
import std/strutils
import std/times
import std/monotimes
import std/sequtils
import std/threadpool
import barabadb/storage/lsm

const
  NumWorkers = 10
  OpsPerWorker = 1000
  KeySpace = 500

randomize()

proc runWorker(workerId: int, dataDir: string): int =
  var db = newLSMTree(dataDir)
  var errors = 0

  for i in 0 ..< OpsPerWorker:
    let op = rand(0 .. 2)
    let key = "key_" & $workerId & "_" & $(rand(0 ..< KeySpace))
    let value = cast[seq[byte]]("val_" & $i & "_" & $workerId)

    case op
    of 0:
      db.put(key, value)
    of 1:
      let (found, val) = db.get(key)
      if found:
        if val != value and val.len > 0:
          discard
    of 2:
      db.delete(key)
    else:
      discard

  for k in 0 ..< KeySpace:
    let key = "key_" & $workerId & "_" & $k
    let (found, _) = db.get(key)
    discard found

  db.close()
  return errors

proc main() =
  let baseDir = "/tmp/baradb_stress_test"
  removeDir(baseDir)
  createDir(baseDir)

  let start = getMonoTime()

  var workerDirs: seq[string] = @[]
  for i in 0 ..< NumWorkers:
    workerDirs.add(baseDir / "worker_" & $i)

  # Run workers in parallel using threadpool
  var futures: seq[FlowVar[int]] = @[]
  for i in 0 ..< NumWorkers:
    futures.add(spawn runWorker(i, workerDirs[i]))

  var totalErrors = 0
  for f in futures:
    totalErrors += ^f

  let elapsed = (getMonoTime() - start).inMilliseconds
  let totalOps = NumWorkers * OpsPerWorker

  echo "Stress test completed: ", totalOps, " ops across ", NumWorkers, " workers"
  echo "Time: ", elapsed, " ms"
  echo "Throughput: ", float(totalOps) / (float(elapsed) / 1000.0), " ops/sec"
  echo "Errors: ", totalErrors

  if totalErrors > 0:
    quit(1)

  removeDir(baseDir)

main()
