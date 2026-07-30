## Raft failover-under-load E2E — real 3-node cluster over the TCP transport.
## A writer thread hammers the current leader with INSERTs; once 50 writes
## have been acknowledged the leader is killed mid-load. Asserts:
##   A (availability): a survivor accepts an INSERT within 10s of the kill.
##   B (durability):   every acknowledged id is present on BOTH survivors
##                     once the new leader is stable and the remaining
##                     follower has caught up.
## Process-management conventions follow tests/raft_writes_e2e_test.nim;
## client access follows tests/nimforum_smoke_test.nim.
##
## NOTE: load_test deliberately has a non-PK column. A table whose only
## column is the PK stores an EMPTY LSM value per row (execInsert drops PK
## columns from the value), and the raft write path (appendWriteToRaft in
## src/barabadb/core/server.nim) encodes empty values as "delete" entries —
## so on commit every node applies a delete over the just-inserted row and
## it vanishes everywhere. That is a v1.2.0 product bug in the raft entry
## encoding (put/delete must not be inferred from value emptiness); until it
## is fixed in src/, this test exercises the two-column row shape that the
## current encoding handles correctly.
import std/unittest
import std/osproc
import std/os
import std/strtabs
import std/strutils
import std/sequtils
import std/times
import std/net
import std/posix
import std/sets
import std/locks
import std/typedthreads

import ../adaptors/nim/baradb_sqlite as sqlite

const
  BinaryPath = "./build/baradadb"
  LeaderMarker = "became leader"
  AckTarget = 50        # kill the leader once this many writes are acked
  ProbeId = 1000001     # availability-probe row id (clear of writer's 1..N)

type
  NodeProc = object
    id: string
    clientPort: int
    p: Process
    dataDir: string
    output: string
    alive: bool

# Shared writer-thread state, passed by pointer into the thread (same
# convention as tests/test_storage_hardening.nim); all access goes through
# the lock.
type
  WriterArgs = object
    lock: ptr Lock
    acked: ptr seq[int]  # ids whose INSERT was acknowledged by the cluster
    stop: ptr bool       # main thread sets this to end the writer loop
    ports: array[3, int] # candidate client ports (leader first, then survivors)

proc drainOutput(n: var NodeProc) =
  ## Reads whatever the child has written so far. The pipe was set O_NONBLOCK
  ## at start, so this never blocks — a hung read is impossible here.
  var tmp: array[8192, char]
  while true:
    let count = posix.read(n.p.outputHandle.cint, tmp[0].addr, tmp.len)
    if count <= 0: break
    for i in 0 ..< count: n.output.add tmp[i]

proc drainAll(nodes: var seq[NodeProc]) =
  for n in nodes.mitems:
    if n.p != nil: n.drainOutput()

proc dumpAll(nodes: var seq[NodeProc]) =
  ## Debuggability: on failure, everything the nodes said.
  nodes.drainAll()
  for n in nodes:
    echo "===== output of ", n.id, " (port ", n.clientPort, ") ====="
    echo n.output

proc portOpen(port: int): bool =
  var s: Socket
  try:
    s = newSocket()
    s.connect("127.0.0.1", Port(port), timeout = 250)
    s.close()
    result = true
  except CatchableError:
    if s != nil: s.close()
    result = false

proc killNode(n: var NodeProc) =
  if n.p != nil and n.alive:
    try:
      n.p.terminate()
      discard n.p.waitForExit()
    except CatchableError:
      discard
    n.alive = false

proc leaderTerms(output: string): seq[int] =
  ## All terms this node logged leadership for ("became leader for term T").
  var pos = 0
  while true:
    let idx = output.find(LeaderMarker, pos)
    if idx < 0: break
    let tIdx = output.find("term ", idx)
    if tIdx < 0: break
    let numStart = tIdx + 5
    var numEnd = numStart
    while numEnd < output.len and output[numEnd] in Digits: inc numEnd
    if numEnd > numStart:
      result.add(parseInt(output[numStart ..< numEnd]))
    pos = numEnd

proc maxLeader(nodes: seq[NodeProc]): tuple[idx, term: int] =
  ## Node that logged leadership for the highest term seen so far.
  result = (-1, 0)
  for i in 0 ..< nodes.len:
    for t in leaderTerms(nodes[i].output):
      if t > result.term: result = (i, t)

proc drainFor(nodes: var seq[NodeProc], ms: int) =
  let start = getTime()
  while getTime() - start < initDuration(milliseconds = ms):
    nodes.drainAll()
    sleep(50)

proc openClient(port: int): DbConn =
  ## Connect with retries — the port may accept TCP before the DB is usable.
  for i in 0 ..< 50:
    try:
      return open("127.0.0.1:" & $port, "", "", "default")
    except CatchableError:
      sleep(100)
  raise newException(IOError, "cannot connect to port " & $port)

proc countRows(port: int): int =
  ## Row count of load_test on `port`, or -1 on any error (not ready yet).
  result = -1
  try:
    let db = openClient(port)
    try:
      result = parseInt(db.getValue(sql"SELECT count(*) FROM load_test"))
    finally:
      db.close()
  except CatchableError:
    discard

proc allIds(port: int): HashSet[int] =
  ## Every id in load_test on `port`. Raises on error.
  let db = openClient(port)
  try:
    for row in db.getAllRows(sql"SELECT id FROM load_test"):
      if row.len >= 1 and row[0].len > 0:
        result.incl(parseInt(row[0]))
  finally:
    db.close()

proc writerLoop(args: WriterArgs) {.thread.} =
  ## INSERTs n = 1, 2, ... against the cluster. Every acknowledged n is
  ## appended to args.acked. On any error the client is dropped and reopened
  ## against the next candidate port — the documented client retry contract.
  ## Writes against followers are forwarded to the leader by the server.
  var n = 1
  var portIdx = 0
  var db: DbConn
  while true:
    withLock args.lock[]:
      if args.stop[]: break
    if cast[pointer](db) == nil:
      let port = args.ports[portIdx]
      try:
        db = open("127.0.0.1:" & $port, "", "", "default")
      except CatchableError:
        portIdx = (portIdx + 1) mod args.ports.len
        sleep(50)
        continue
    try:
      db.exec(sql("INSERT INTO load_test (id, n) VALUES (" & $n & ", " & $n & ")"))
      withLock args.lock[]:
        args.acked[].add n
      inc n
    except CatchableError:
      if cast[pointer](db) != nil:
        try: db.close()
        except CatchableError: discard
      db = default(DbConn)
      portIdx = (portIdx + 1) mod args.ports.len
      sleep(50)
  if cast[pointer](db) != nil:
    try: db.close()
    except CatchableError: discard

proc runFailoverLoadScenario() =
  ## Fatal phase failures dump all captured node output, record a test
  ## failure, and return; cleanup happens in the finally below either way.
  let tstamp = getTime().toUnix.int
  # Port bases: distinct from nimforum_smoke_test (35000+mod10000),
  # raft_e2e_test (41000+mod5000) and raft_writes_e2e_test (46000+mod4000).
  # Client ports are spaced by 10 because the server derives HTTP (port+440),
  # WS (port+441) and gossip (raftPort+100) ports — consecutive client ports
  # collide.
  let cbase = 50000 + (tstamp mod 4000)
  let rbase = cbase + 100
  let peers = "n1@127.0.0.1:" & $(rbase + 1) &
              ",n2@127.0.0.1:" & $(rbase + 2) &
              ",n3@127.0.0.1:" & $(rbase + 3)
  # SQL client ports for transparent leader write forwarding.
  let clientPeers = "n1@127.0.0.1:" & $(cbase + 10) &
                    ",n2@127.0.0.1:" & $(cbase + 20) &
                    ",n3@127.0.0.1:" & $(cbase + 30)

  var nodes: seq[NodeProc]
  for i in 1 .. 3:
    let id = "n" & $i
    let dataDir = getTempDir() / "baradb_raft_failover_load_e2e_" & $tstamp & "_" & id
    createDir(dataDir)
    var env = newStringTable()
    for key, val in envPairs():
      env[key] = val
    env["BARADB_PORT"] = $(cbase + i * 10)
    env["BARADB_RAFT_ENABLED"] = "true"
    env["BARADB_RAFT_PORT"] = $(rbase + i)
    env["BARADB_RAFT_NODE_ID"] = id
    env["BARADB_RAFT_PEERS"] = peers
    env["BARADB_RAFT_CLIENT_PEERS"] = clientPeers
    env["BARADB_DATA_DIR"] = dataDir
    env["BARADB_LOG_LEVEL"] = "info"
    let p = startProcess(BinaryPath, env = env,
                         options = {poStdErrToStdOut, poDaemon})
    discard fcntl(p.outputHandle.cint, F_SETFL,
                  fcntl(p.outputHandle.cint, F_GETFL) or O_NONBLOCK)
    nodes.add NodeProc(id: id, clientPort: cbase + i * 10, p: p,
                       dataDir: dataDir, alive: true)

  var
    writer: Thread[WriterArgs]
    writerStarted = false
    wLock: Lock
    wAcked: seq[int]
    wStop = false
  initLock(wLock)
  try:
    # Readiness: all three client ports accept TCP connections (10s each).
    for i in 0 ..< nodes.len:
      let readyStart = getTime()
      var ok = false
      while getTime() - readyStart < initDuration(seconds = 10):
        if portOpen(nodes[i].clientPort):
          ok = true
          break
        sleep(100)
      if not ok:
        echo "node ", nodes[i].id, " never became ready"
        dumpAll(nodes)
        fail()
        return

    # Election: timeouts are 150-300ms, heartbeat 50ms — a leader should
    # emerge within ~2s; 10s deadline for margin.
    var elected = false
    let electStart = getTime()
    while getTime() - electStart < initDuration(seconds = 10):
      nodes.drainAll()
      if maxLeader(nodes).idx >= 0:
        elected = true
        break
      sleep(50)
    if not elected:
      echo "no leader elected within 10s"
      dumpAll(nodes)
      fail()
      return

    # Settle and require stability, same as raft_writes_e2e_test.
    nodes.drainFor(2000)
    let (leaderIdx, leaderTerm) = maxLeader(nodes)
    nodes.drainFor(1000)
    let (stableIdx, stableTerm) = maxLeader(nodes)
    if stableIdx != leaderIdx or stableTerm != leaderTerm:
      echo "cluster unstable: leadership moved from ", nodes[leaderIdx].id,
           " (term ", leaderTerm, ") to ", nodes[stableIdx].id,
           " (term ", stableTerm, ")"
      dumpAll(nodes)
      fail()
      return
    echo "leader elected: ", nodes[leaderIdx].id, " (term ", leaderTerm, ")"

    # Schema goes through the raft ddl log on the leader (C3c).
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        db.exec(sql"CREATE TABLE load_test (id INT PRIMARY KEY, n INT)")
      except CatchableError as e:
        echo "leader CREATE TABLE failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo "leader schema committed via raft ddl"

    # Load phase: sustained INSERTs from a background writer thread.
    let wArgs = WriterArgs(
      lock: addr wLock, acked: addr wAcked, stop: addr wStop,
      ports: [nodes[leaderIdx].clientPort,
              nodes[(leaderIdx + 1) mod 3].clientPort,
              nodes[(leaderIdx + 2) mod 3].clientPort])
    createThread(writer, writerLoop, wArgs)
    writerStarted = true

    # Wait until AckTarget writes are acknowledged (30s deadline).
    var ackedAtKill = 0
    let loadStart = getTime()
    while getTime() - loadStart < initDuration(seconds = 30):
      withLock wLock:
        ackedAtKill = wAcked.len
      if ackedAtKill >= AckTarget: break
      sleep(20)
    if ackedAtKill < AckTarget:
      echo "only ", ackedAtKill, " writes acked within 30s (need ", AckTarget, ")"
      dumpAll(nodes)
      fail()
      return
    echo "load phase: ", ackedAtKill, " writes acknowledged, killing leader ",
         nodes[leaderIdx].id

    # Kill the leader mid-load.
    killNode(nodes[leaderIdx])
    let killTime = getTime()

    # Assert A (availability): a survivor accepts an INSERT within 10s of
    # the kill. Probe both survivors; keep the one that answers. Each attempt
    # uses a fresh id: an attempt may commit but lose its response during the
    # failover, and retrying the same id would then loop on UNIQUE violations.
    var writerSurvivor = -1
    var writeErr = ""
    var probeAttempt = 0
    while getTime() - killTime < initDuration(seconds = 10):
      for i in 0 ..< nodes.len:
        if i == leaderIdx: continue
        inc probeAttempt
        let probeId = ProbeId + probeAttempt
        try:
          let db = openClient(nodes[i].clientPort)
          try:
            db.exec(sql("INSERT INTO load_test (id, n) VALUES (" & $probeId & ", " & $probeId & ")"))
            writerSurvivor = i
          finally:
            db.close()
          if writerSurvivor >= 0: break
        except CatchableError as e:
          writeErr = e.msg
          # "not leader" / commit timeout / connection blips — keep probing.
      if writerSurvivor >= 0: break
      sleep(100)
    if writerSurvivor < 0:
      echo "ASSERT A FAILED: no survivor accepted a write within 10s of the kill",
           (if writeErr.len > 0: " (last error: " & writeErr & ")" else: "")
      dumpAll(nodes)
      fail()
      return
    let availMs = inMilliseconds(getTime() - killTime)
    echo "availability: ", nodes[writerSurvivor].id,
         " accepted a write ", availMs, "ms after the kill"

    # Stop the writer thread and snapshot what was acknowledged.
    withLock wLock:
      wStop = true
    joinThreads(writer)
    writerStarted = false
    withLock wLock:
      ackedAtKill = wAcked.len
    echo "writer stopped; ", ackedAtKill, " total acknowledged writes"

    # Let the new leader stabilize and the remaining follower catch up:
    # poll until both survivors agree on a row count that covers every
    # acknowledged write (10s deadline). The >= ackedAtKill guard prevents
    # a trivial 0 == 0 pass before any raft entries have been applied.
    let survivorIdx = [0, 1, 2].filterIt(it != leaderIdx)
    var caughtUp = false
    let cuStart = getTime()
    while getTime() - cuStart < initDuration(seconds = 10):
      let c0 = countRows(nodes[survivorIdx[0]].clientPort)
      let c1 = countRows(nodes[survivorIdx[1]].clientPort)
      if c0 >= ackedAtKill and c0 == c1:
        caughtUp = true
        break
      sleep(100)
    if not caughtUp:
      echo "survivors never reached equal row counts within 10s (",
           countRows(nodes[survivorIdx[0]].clientPort), " vs ",
           countRows(nodes[survivorIdx[1]].clientPort), ")"
      dumpAll(nodes)
      fail()
      return
    echo "survivors caught up: equal row counts"

    # Assert B (durability): every acknowledged id must be present on BOTH
    # survivors.
    var acked: HashSet[int]
    withLock wLock:
      acked = toHashSet(wAcked)
    for i in survivorIdx:
      var ids: HashSet[int]
      try:
        ids = allIds(nodes[i].clientPort)
      except CatchableError as e:
        echo "ASSERT B FAILED: could not read ids from ", nodes[i].id,
             ": ", e.msg
        dumpAll(nodes)
        fail()
        return
      let missing = acked - ids
      if missing.len > 0:
        echo "ASSERT B FAILED: ", nodes[i].id, " is missing ",
             missing.len, " acknowledged ids"
        dumpAll(nodes)
        fail()
        return
      echo "durability: ", nodes[i].id, " contains all ",
           acked.len, " acknowledged ids"

    check acked.len >= AckTarget
  finally:
    if writerStarted:
      withLock wLock:
        wStop = true
      joinThreads(writer)
    deinitLock(wLock)
    for n in nodes.mitems:
      n.killNode()
      if n.p != nil: n.p.close()
      removeDir(n.dataDir)

suite "Raft failover under load E2E":
  test "committed writes survive a leader kill under sustained write load":
    if not fileExists(BinaryPath):
      echo "[SKIP] ", BinaryPath, " missing — run `nimble test` (builds the server first)"
      skip()
    else:
      runFailoverLoadScenario()
