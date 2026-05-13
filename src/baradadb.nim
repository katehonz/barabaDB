## BaraDB — Multimodal Database Engine
## Main entry point
import std/asyncdispatch
{.push warning[Deprecated]: off.}
import std/threadpool
{.pop.}
import std/locks
import std/os
import std/strutils
import barabadb/core/server
import barabadb/core/httpserver
import barabadb/core/config
import barabadb/core/logging
import barabadb/protocol/ssl
import barabadb/storage/lsm
import barabadb/storage/compaction
import barabadb/core/raft

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
  info("BaraDB TCP listening on " & config.address & ":" & $config.port)
  var server = newServer(config)
  await server.run()

proc main() =
  var config = loadConfig()
  # Init structured logger from config
  let logLvl = parseEnum[LogLevel]("ll" & capitalizeAscii(config.logLevel))
  defaultLogger = newLogger(logLvl, config.logFile)
  info("BaraDB v1.0.0 — Multimodal Database Engine")

  # Security check: warn if JWT secret is not configured
  if config.jwtSecret.len == 0:
    warn("JWT secret not configured! Set BARADB_JWT_SECRET env var or jwt_secret in config. Using default (INSECURE).")

  if config.tlsEnabled:
    if config.certFile.len == 0 or config.keyFile.len == 0 or
       not fileExists(config.certFile) or not fileExists(config.keyFile):
      info("TLS enabled but no certificate found. Generating self-signed certificate...")
      let (cert, key) = generateSelfSignedCert(config.dataDir / "certs")
      if cert.len > 0 and key.len > 0:
        config.certFile = cert
        config.keyFile = key
        info("Generated self-signed certificate: Cert=" & cert & " Key=" & key)
      else:
        warn("Failed to generate self-signed certificate. TLS disabled.")
        config.tlsEnabled = false

  # Start HTTP server (blocking, multi-threaded via hunos) in background thread
  var httpServer = newHttpServer(config)
  spawn httpServer.run(config.port + 440)  # HTTP port = TCP port + 440

  # Start background compaction loop
  let cm = newCompactionManager(httpServer.db)
  asyncCheck cm.startCompactionLoop()

  # Start Raft cluster if enabled
  if config.raftEnabled:
    info("Starting Raft node " & config.raftNodeId & " on port " & $config.raftPort)
    var raftNode = newRaftNode(config.raftNodeId, config.raftPeers, config.raftPort)
    # Wire state machine to apply committed entries to the database
    raftNode.applyCommand = proc(cmd: string, data: seq[byte]) {.gcsafe.} =
      if cmd == "put":
        let parts = cast[string](data).split("\x00")
        if parts.len >= 2:
          httpServer.db.put(parts[0], cast[seq[byte]](parts[1]))
      elif cmd == "delete":
        httpServer.db.delete(cast[string](data))
    var raftNet = newRaftNetwork(raftNode)
    asyncCheck raftNet.run()

  # Start TCP wire protocol server on main thread with async event loop
  waitFor runTcpServer(config)

  # Shutdown
  httpServer.stop()

when isMainModule:
  main()
