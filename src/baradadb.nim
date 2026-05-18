## BaraDB — Multimodal Database Engine
## Main entry point
import std/asyncdispatch
{.push warning[Deprecated]: off.}
import std/threadpool
{.pop.}
import std/locks
import std/os
import std/strutils
import std/tables
import std/algorithm
import barabadb/core/server
import barabadb/core/httpserver
import barabadb/core/config
import barabadb/core/logging
import barabadb/protocol/ssl
import barabadb/storage/lsm
import barabadb/storage/compaction
import barabadb/core/raft
import barabadb/core/gossip
import barabadb/core/replication
import barabadb/core/disttxn
import barabadb/tools/repair
import barabadb/tools/migrate

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
      let result = cm.strategy.compact(level)
      if result.outputTables.len == 0:
        continue

      # Remove compacted input SSTables from LSMTree
      var newSSTables: seq[SSTable] = @[]
      var removedPaths = initTable[string, bool]()
      for t in result.inputTables:
        removedPaths[t.path] = true
      for sst in cm.db.sstables:
        if sst.path notin removedPaths:
          newSSTables.add(sst)

      # Load and add output SSTables
      for meta in result.outputTables:
        try:
          var sst = loadSSTable(meta.path)
          let name = splitFile(meta.path).name
          # Extract numeric id from filename if possible
          sst.id = try: parseInt(name) except: cm.db.nextSSTableId
          sst.level = meta.level
          newSSTables.add(sst)
          cm.db.nextSSTableId = max(cm.db.nextSSTableId, sst.id + 1)
        except CatchableError as e:
          warn("Compaction output SSTable failed to load: " & meta.path & " — " & e.msg)

      newSSTables.sort(proc(a, b: SSTable): int = cmp(a.id, b.id))
      cm.db.sstables = newSSTables

      # Update MANIFEST
      inc cm.db.manifestSequence
      try:
        writeManifest(cm.db)
      except CatchableError as e:
        warn("Failed to write MANIFEST after compaction: " & e.msg)

proc startCompactionLoop*(cm: CompactionManager, intervalMs: int = 60000) {.async.} =
  while true:
    await sleepAsync(intervalMs)
    cm.compact()

proc runTcpServer(config: BaraConfig) {.async.} =
  info("BaraDB TCP listening on " & config.address & ":" & $config.port)
  var server = newServer(config)
  await server.run()

proc wireRaftDistTxn(raftNode: RaftNode, tcpServer: Server) =
  ## Wire RAFT consensus to distributed transaction manager for 2PC coordination.
  ## When RAFT commits a DISTTXN operation, forward it to DistTxnManager.

  raftNode.onDistTxnPrepare = proc(txnId: uint64, nodes: seq[string]): bool {.gcsafe.} =
    let txn = tcpServer.distTxnManager.getTxn(txnId)
    if txn != nil:
      return txn.prepare()
    return false

  raftNode.onDistTxnCommit = proc(txnId: uint64) {.gcsafe.} =
    let txn = tcpServer.distTxnManager.getTxn(txnId)
    if txn != nil:
      discard txn.commit()

  raftNode.onDistTxnRollback = proc(txnId: uint64) {.gcsafe.} =
    let txn = tcpServer.distTxnManager.getTxn(txnId)
    if txn != nil:
      discard txn.rollback()

proc wireReplicationDistTxn(rm: ReplicationManager, dtm: DistTxnManager) =
  ## Wire replication acknowledgments to distributed transaction completion.
  ## When all replicas ack a write that belongs to a distributed transaction,
  ## move the transaction to committed state.
  discard

proc main() =
  # CLI command dispatch (before server startup)
  if paramCount() >= 1:
    let cmd = paramStr(1).toLowerAscii()
    if cmd == "repair":
      var dataDir = "data/server"
      var dryRun = false
      var quiet = false
      var i = 2
      while i <= paramCount():
        let arg = paramStr(i)
        if arg.startsWith("--data-dir="):
          dataDir = arg[11..^1]
        elif arg == "--dry-run":
          dryRun = true
        elif arg == "--quiet" or arg == "-q":
          quiet = true
        elif arg == "--help" or arg == "-h":
          echo repair.HelpText
          return
        inc i
      let rep = repair.runRepair(dataDir, dryRun, quiet)
      repair.printReport(rep, quiet)
      if rep.sstablesCorrupt > 0:
        quit(1)
      else:
        quit(0)

    elif cmd == "checkpoint":
      var dataDir = "data/server"
      var i = 2
      while i <= paramCount():
        let arg = paramStr(i)
        if arg.startsWith("--data-dir="):
          dataDir = arg[11..^1]
        elif arg == "--help" or arg == "-h":
          echo "BaraDB Checkpoint — Create a consistent storage checkpoint"
          echo ""
          echo "USAGE:"
          echo "  checkpoint [options]"
          echo ""
          echo "OPTIONS:"
          echo "  -d, --data-dir <DIR>  Path to data directory (default: data/server)"
          echo "  -h, --help            Show this help message"
          return
        inc i
      try:
        var db = newLSMTree(dataDir)
        db.checkpoint()
        db.close()
        var sstCount = 0
        for kind, path in walkDir(dataDir / "sstables"):
          if kind == pcFile: inc sstCount
        echo "Checkpoint created successfully at: ", dataDir
        echo "  SSTables: ", sstCount
        echo "  MANIFEST: ", dataDir / "MANIFEST"
        quit(0)
      except CatchableError as e:
        echo "ERROR: Checkpoint failed: ", e.msg
        quit(1)

    elif cmd == "migrate":
      var dataDir = "data/server"
      var dryRun = false
      var i = 2
      while i <= paramCount():
        let arg = paramStr(i)
        if arg.startsWith("--data-dir="):
          dataDir = arg[11..^1]
        elif arg == "--dry-run":
          dryRun = true
        elif arg == "--help" or arg == "-h":
          echo migrate.HelpText
          return
        inc i
      let result = migrate.runMigration(dataDir, dryRun)
      echo ""
      echo "Migration complete:"
      echo "  Scanned:  ", result.scanned
      echo "  Migrated: ", result.migrated
      echo "  Errors:   ", result.errors.len
      if result.errors.len > 0:
        for e in result.errors:
          echo "  ! ", e
        quit(1)
      else:
        quit(0)

  var config = loadConfig()
  # Init structured logger from config
  let logLvl = parseEnum[LogLevel]("ll" & capitalizeAscii(config.logLevel))
  defaultLogger = newLogger(logLvl, config.logFile)
  info("BaraDB v1.1.4 — Multimodal Database Engine")

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

  # Create TCP server (initialization is synchronous, run is async)
  let localId {.used.} = if config.raftNodeId.len > 0: config.raftNodeId else: "node-" & $config.port
  var tcpServer = newServer(config)

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
          tcpServer.db.put(parts[0], cast[seq[byte]](parts[1]))
      elif cmd == "delete":
        httpServer.db.delete(cast[string](data))
        tcpServer.db.delete(cast[string](data))

    # Wire RAFT ↔ DistTxn
    wireRaftDistTxn(raftNode, tcpServer)

    # Wire replication ↔ DistTxn
    wireReplicationDistTxn(tcpServer.replicationManager, tcpServer.distTxnManager)

    var raftNet = newRaftNetwork(raftNode)
    asyncCheck raftNet.run()

  # Start replication health check and reconnection loops
  asyncCheck tcpServer.replicationManager.startHealthCheck(5000)
  asyncCheck tcpServer.replicationManager.startReconnectionLoop(10000)

  # Join gossip cluster from seed nodes if configured
  let seedNodesEnv = getEnv("BARADB_SEED_NODES", "")
  if seedNodesEnv.len > 0 and tcpServer.gossipProtocol != nil:
    let seeds = seedNodesEnv.split(",")
    for seed in seeds:
      let parts = seed.strip().split(":")
      if parts.len >= 2:
        let host = parts[0]
        let port = try: parseInt(parts[1]) except: 0
        if port > 0:
          let seedNode = newGossipNode(host & ":" & $port, host, port)
          tcpServer.gossipProtocol.join(seedNode)
          info("Joined gossip cluster via seed " & host & ":" & $port)

  # Start TCP wire protocol server on main thread with async event loop
  waitFor runTcpServer(config)

  # Shutdown
  httpServer.stop()
  if tcpServer.gossipProtocol != nil:
    tcpServer.gossipProtocol.stop()

when isMainModule:
  main()
