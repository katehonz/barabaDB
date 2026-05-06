## BaraDB — Multimodal Database Engine
## Main entry point
import std/asyncdispatch
import std/threadpool
import std/locks
import barabadb/core/server
import barabadb/core/httpserver
import barabadb/core/config
import barabadb/storage/lsm
import barabadb/storage/compaction

type
  CompactionManager* = ref object
    db*: LSMTree
    strategy*: compaction.CompactionStrategy

proc newCompactionManager*(db: LSMTree): CompactionManager =
  result = CompactionManager(db: db, strategy: compaction.newCompactionStrategy(db.dir))
  for sst in db.sstables:
    let meta = compaction.SSTableMeta(
      path: sst.path,
      level: sst.level,
      minKey: sst.minKey,
      maxKey: sst.maxKey,
      entryCount: sst.entryCount,
      sizeBytes: sst.entryCount * 64,
      createdAt: 0,
    )
    result.strategy.addTable(meta)
  for sst in db.sstables:
    let meta = SSTableMeta(
      path: sst.path,
      level: sst.level,
      minKey: sst.minKey,
      maxKey: sst.maxKey,
      entryCount: sst.entryCount,
      sizeBytes: sst.entryCount * 64,
      createdAt: 0,
    )
    result.strategy.addTable(meta)

proc compact*(cm: CompactionManager) =
  acquire(cm.db.lock)
  defer: release(cm.db.lock)
  for level in 0 ..< compaction.MaxLevel:
    if cm.strategy.needsCompaction(level):
      discard cm.strategy.compact(level)

proc startCompactionLoop*(cm: CompactionManager, intervalMs: int = 60000) {.async.} =
  while true:
    await sleepAsync(intervalMs)
    cm.compact()

proc runTcpServer(config: BaraConfig) {.async.} =
  echo "BaraDB TCP listening on ", config.address, ":", config.port
  var server = newServer(config)
  await server.run()

proc main() =
  let config = loadConfig()
  echo "BaraDB v0.1.0 — Multimodal Database Engine"

  # Start HTTP server (blocking, multi-threaded via hunos) in background thread
  var httpServer = newHttpServer(config)
  spawn httpServer.run(config.port + 440)  # HTTP port = TCP port + 440

  # Start background compaction loop
  let cm = newCompactionManager(httpServer.db)
  asyncCheck cm.startCompactionLoop()

  # Start TCP wire protocol server on main thread with async event loop
  waitFor runTcpServer(config)

  # Shutdown
  httpServer.stop()

when isMainModule:
  main()
