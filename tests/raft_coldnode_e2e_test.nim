## Raft cold-node E2E — real 3-node cluster; end-to-end proof of the
## InstallSnapshot work (compaction, snapshot build/send, follower restore).
## Starts three actual build/baradadb processes with a tiny raft log
## (BARADB_RAFT_LOG_MAX_ENTRIES=16) and a short stale window
## (BARADB_RAFT_PEER_STALE_MS=3000) so the leader compacts quickly past a
## downed peer's matchIndex.
##
## Scenario A: a node is killed, 100 rows are written through the leader
## (forcing compaction past its matchIndex), the node restarts with its
## intact data dir and must catch up via InstallSnapshot within 15 s.
## Scenario B: the node is stopped, its data dir is WIPED, it rejoins with
## the same node id and must serve the full row set within 20 s.
##
## Process-management conventions follow tests/raft_writes_e2e_test.nim
## (copying is the repo's e2e convention — do not factor out).
import std/unittest
import std/osproc
import std/os
import std/strtabs
import std/strutils
import std/times
import std/net
import std/posix
import std/httpclient

import ../adaptors/nim/baradb_sqlite as sqlite

const
  BinaryPath = "./build/baradadb"
  LeaderMarker = "became leader"
  SnapshotMarker = "Installing snapshot"
  TableName = "cold_test"
  RowCount = 100

type
  NodeProc = object
    id: string
    clientPort: int
    raftPort: int
    peers: string
    clientPeers: string
    p: Process
    dataDir: string
    output: string
    alive: bool

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

proc rowCountOn(port: int): int =
  ## SELECT COUNT(*) — raises while the table is not there yet (e.g. before
  ## the snapshot restore has landed); callers poll and tolerate that.
  let db = openClient(port)
  defer: db.close()
  parseInt(db.getValue(sql("SELECT COUNT(*) FROM " & TableName)))

proc fetchMetric(port: int, name: string): int =
  ## GET /metrics on the node's HTTP port (clientPort + 440) and parse
  ## `name{...} <value>`. Returns -1 on any error or when absent.
  let client = newHttpClient(timeout = 1500)
  defer: client.close()
  try:
    let body = client.getContent("http://127.0.0.1:" & $(port + 440) & "/metrics")
    for line in body.splitLines():
      if line.startsWith(name & "{"):
        let parts = line.splitWhitespace()
        if parts.len >= 2:
          return parseInt(parts[^1])
  except CatchableError:
    discard
  return -1

proc startNode(id, dataDir: string, clientPort, raftPort: int,
               peers, clientPeers: string): NodeProc =
  ## Boots one build/baradadb process. Takes the data dir explicitly so a
  ## node can be restarted with the same dir (scenario A) or a wiped dir
  ## (scenario B). Compaction/stale-window env goes on EVERY node.
  createDir(dataDir)
  var env = newStringTable()
  for key, val in envPairs():
    env[key] = val
  env["BARADB_PORT"] = $clientPort
  env["BARADB_RAFT_ENABLED"] = "true"
  env["BARADB_RAFT_PORT"] = $raftPort
  env["BARADB_RAFT_NODE_ID"] = id
  env["BARADB_RAFT_PEERS"] = peers
  env["BARADB_RAFT_CLIENT_PEERS"] = clientPeers
  env["BARADB_RAFT_LOG_MAX_ENTRIES"] = "16"
  env["BARADB_RAFT_PEER_STALE_MS"] = "3000"
  env["BARADB_DATA_DIR"] = dataDir
  env["BARADB_LOG_LEVEL"] = "info"
  let p = startProcess(BinaryPath, env = env,
                       options = {poStdErrToStdOut, poDaemon})
  discard fcntl(p.outputHandle.cint, F_SETFL,
                fcntl(p.outputHandle.cint, F_GETFL) or O_NONBLOCK)
  NodeProc(id: id, clientPort: clientPort, raftPort: raftPort,
           peers: peers, clientPeers: clientPeers, p: p,
           dataDir: dataDir, alive: true)

proc restartNode(n: var NodeProc, wipe: bool) =
  ## Kill, then boot the same node id again. wipe=false keeps the data dir
  ## (cold-node return); wipe=true deletes it first (fresh node rejoin).
  n.killNode()
  if n.p != nil: n.p.close()
  if wipe:
    removeDir(n.dataDir)
  let fresh = startNode(n.id, n.dataDir, n.clientPort, n.raftPort,
                        n.peers, n.clientPeers)
  n.p = fresh.p
  n.alive = true

proc waitReady(n: NodeProc, deadlineSec: int): bool =
  let start = getTime()
  while getTime() - start < initDuration(seconds = deadlineSec):
    if portOpen(n.clientPort):
      return true
    sleep(100)
  return false

proc runColdNodeScenario() =
  ## Fatal phase failures dump all captured node output, record a test
  ## failure, and return; cleanup happens in the finally below either way.
  let tstamp = getTime().toUnix.int
  # Port base per the T11 brief: distinct from raft_writes_e2e_test
  # (46000+mod4000) and raft_tls_e2e_test (54000+mod4000). Client ports are
  # spaced by 10 because the server derives HTTP (port+440), WS (port+441)
  # and gossip (raftPort+100) ports — consecutive client ports collide.
  let cbase = 58000 + (tstamp mod 4000)
  let rbase = cbase + 100
  let peers = "n1@127.0.0.1:" & $(rbase + 1) &
              ",n2@127.0.0.1:" & $(rbase + 2) &
              ",n3@127.0.0.1:" & $(rbase + 3)
  # SQL client ports for transparent leader write forwarding.
  let clientPeers = "n1@127.0.0.1:" & $(cbase + 10) &
                    ",n2@127.0.0.1:" & $(cbase + 20) &
                    ",n3@127.0.0.1:" & $(cbase + 30)

  var nodes: seq[NodeProc]

  try:
    # Node starts live inside the try so a raise from start #2/#3 still
    # reaches the cleanup in the finally below.
    for i in 1 .. 3:
      let id = "n" & $i
      let dataDir = getTempDir() / "baradb_raft_coldnode_e2e_" & $tstamp & "_" & id
      nodes.add startNode(id, dataDir, cbase + i * 10, rbase + i,
                          peers, clientPeers)

    # Readiness: all three client ports accept TCP connections (10s each).
    for i in 0 ..< nodes.len:
      if not waitReady(nodes[i], 10):
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

    # The cold node: n3 unless n3 is the leader (then n1) — it must be a
    # follower so killing it never forces a re-election.
    let coldIdx = (if leaderIdx == 2: 0 else: 2)
    let otherIdx = 3 - leaderIdx - coldIdx
    echo "cold node: ", nodes[coldIdx].id, "; surviving follower: ",
         nodes[otherIdx].id

    # Schema: CREATE TABLE goes through the raft "ddl" log (C3c). Create on
    # the leader; wait until the cold node has applied it before killing it.
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        db.exec(sql("CREATE TABLE " & TableName & " (id INT PRIMARY KEY, name STRING)"))
      except CatchableError as e:
        echo "leader CREATE TABLE failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    block:
      let start = getTime()
      var ready = false
      while getTime() - start < initDuration(seconds = 5):
        try:
          discard rowCountOn(nodes[coldIdx].clientPort)
          ready = true
          break
        except CatchableError:
          sleep(100)
      if not ready:
        echo "cold node ", nodes[coldIdx].id,
             " never applied CREATE TABLE within 5s"
        dumpAll(nodes)
        fail()
        return
    echo "schema replicated to cold node ", nodes[coldIdx].id

    # ---- Kill the cold node; write 100 rows through the leader. ----
    # With logMaxEntries=16 and peerStaleMs=3000 the leader compacts past the
    # dead node's matchIndex partway through the writes, so the node can only
    # catch up via InstallSnapshot on return.
    killNode(nodes[coldIdx])
    echo "cold node ", nodes[coldIdx].id, " killed; writing ", RowCount, " rows"
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      var atRow = 0
      try:
        for i in 1 .. RowCount:
          atRow = i
          db.exec(sql("INSERT INTO " & TableName & " (id, name) VALUES (" &
                      $i & ", 'row-" & $i & "')"))
      except CatchableError as e:
        echo "leader INSERT failed at row ", atRow, ": ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo RowCount, " rows committed with ", nodes[coldIdx].id, " down"

    # Compaction evidence on the leader: the in-memory log stayed bounded
    # (<= 64, far below the 100 entries written) and the snapshot base moved.
    nodes.drainAll()
    let leaderLogLen = fetchMetric(nodes[leaderIdx].clientPort,
                                   "baradb_raft_log_entries")
    let leaderSnapIdx = fetchMetric(nodes[leaderIdx].clientPort,
                                    "baradb_raft_snapshot_index")
    echo "leader after writes: log_entries=", leaderLogLen,
         " snapshot_index=", leaderSnapIdx
    if leaderLogLen < 0 or leaderLogLen > 64:
      echo "leader raft log not bounded: baradb_raft_log_entries=",
           leaderLogLen, " (want <= 64)"
      dumpAll(nodes)
      fail()
      return
    if leaderSnapIdx <= 0:
      echo "leader never compacted: baradb_raft_snapshot_index=",
           leaderSnapIdx, " (want > 0)"
      dumpAll(nodes)
      fail()
      return
    echo "leader log stayed bounded and compaction advanced"

    # Sanity: leader and surviving follower agree on the row count.
    let wantCount = rowCountOn(nodes[leaderIdx].clientPort)
    if wantCount != RowCount:
      echo "leader count=", wantCount, " want ", RowCount
      dumpAll(nodes)
      fail()
      return

    # ---- Scenario A: cold node returns with its intact data dir. ----
    nodes[coldIdx].output.setLen(0)  # fresh log for the snapshot marker scan
    restartNode(nodes[coldIdx], wipe = false)
    if not waitReady(nodes[coldIdx], 10):
      echo "cold node ", nodes[coldIdx].id, " never became ready after restart"
      dumpAll(nodes)
      fail()
      return
    echo "scenario A: ", nodes[coldIdx].id, " restarted with intact data dir"

    # Within 15s: snapshot evidence (metric on the cold node, or its restore
    # log line) AND data convergence with the leader.
    block:
      let start = getTime()
      var snapSeen = false
      var converged = false
      while getTime() - start < initDuration(seconds = 15):
        nodes.drainAll()
        if not snapSeen:
          snapSeen = fetchMetric(nodes[coldIdx].clientPort,
                                 "baradb_raft_snapshot_index") > 0 or
                     nodes[coldIdx].output.contains(SnapshotMarker)
        if not converged:
          try:
            converged = rowCountOn(nodes[coldIdx].clientPort) == wantCount
          except CatchableError:
            discard
        if snapSeen and converged: break
        sleep(200)
      if not snapSeen:
        echo "scenario A: no snapshot evidence on ", nodes[coldIdx].id,
             " (baradb_raft_snapshot_index stayed 0, no restore log line)"
        dumpAll(nodes)
        fail()
        return
      if not converged:
        echo "scenario A: ", nodes[coldIdx].id,
             " count did not converge to ", wantCount, " within 15s"
        dumpAll(nodes)
        fail()
        return
    echo "scenario A: snapshot installed, count converged to ", wantCount

    # Spot-check a few ids survived the snapshot round-trip.
    block:
      let db = openClient(nodes[coldIdx].clientPort)
      defer: db.close()
      for i in [1, 42, RowCount]:
        let v = db.getValue(sql("SELECT name FROM " & TableName &
                                " WHERE id = " & $i))
        if v != "row-" & $i:
          echo "scenario A: spot-check id=", i, " got '", v,
               "' want 'row-", i, "'"
          dumpAll(nodes)
          fail()
          return
    echo "scenario A: spot-checks passed"

    # ---- Scenario B: wiped node rejoins with the same node id. ----
    nodes[coldIdx].output.setLen(0)
    restartNode(nodes[coldIdx], wipe = true)
    if not waitReady(nodes[coldIdx], 10):
      echo "wiped node ", nodes[coldIdx].id, " never became ready after restart"
      dumpAll(nodes)
      fail()
      return
    echo "scenario B: ", nodes[coldIdx].id, " restarted with a wiped data dir"

    # Within 20s: snapshot → catch-up, then the full row set.
    block:
      let start = getTime()
      var snapSeen = false
      var converged = false
      while getTime() - start < initDuration(seconds = 20):
        nodes.drainAll()
        if not snapSeen:
          snapSeen = fetchMetric(nodes[coldIdx].clientPort,
                                 "baradb_raft_snapshot_index") > 0 or
                     nodes[coldIdx].output.contains(SnapshotMarker)
        if not converged:
          try:
            converged = rowCountOn(nodes[coldIdx].clientPort) == wantCount
          except CatchableError:
            discard
        if snapSeen and converged: break
        sleep(200)
      if not snapSeen:
        echo "scenario B: no snapshot evidence on wiped ", nodes[coldIdx].id
        dumpAll(nodes)
        fail()
        return
      if not converged:
        echo "scenario B: wiped ", nodes[coldIdx].id,
             " count did not converge to ", wantCount, " within 20s"
        dumpAll(nodes)
        fail()
        return
    echo "scenario B: wiped node converged to ", wantCount, " rows"

    # Spot-check again on the wiped node.
    block:
      let db = openClient(nodes[coldIdx].clientPort)
      defer: db.close()
      for i in [1, 42, RowCount]:
        let v = db.getValue(sql("SELECT name FROM " & TableName &
                                " WHERE id = " & $i))
        if v != "row-" & $i:
          echo "scenario B: spot-check id=", i, " got '", v,
               "' want 'row-", i, "'"
          dumpAll(nodes)
          fail()
          return
    echo "scenario B: spot-checks passed"
  finally:
    for n in nodes.mitems:
      n.killNode()
      if n.p != nil: n.p.close()
      removeDir(n.dataDir)

suite "Raft cold-node E2E":
  test "compacted-away node and wiped node rejoin and converge":
    if not fileExists(BinaryPath):
      if getEnv("CI").len > 0:
        echo "[FAIL] ", BinaryPath, " missing under CI — build step broken?"
        fail()
      else:
        echo "[SKIP] ", BinaryPath, " missing — run `nimble test` (builds the server first)"
        skip()
    else:
      runColdNodeScenario()
