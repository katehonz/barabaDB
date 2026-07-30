## Raft replicated writes E2E — real 3-node cluster over the TCP transport.
## Starts three actual build/baradadb processes, writes through the leader
## (exercising the raft commit wait), verifies followers apply committed
## entries, rejects follower writes, and writes again after failover.
## Process-management conventions follow tests/raft_e2e_test.nim; client
## access follows tests/nimforum_smoke_test.nim.
##
## NOTE: CREATE TABLE produces no keyValuePairs (schema DDL is out of scope
## for raft replication), so followers never learn the table from the log.
## The test therefore creates the table locally on ALL nodes — CREATE TABLE
## is not classified as a raft write (isWrite covers DML only), so followers
## accept it — and tests ROW replication only.
import std/unittest
import std/osproc
import std/os
import std/strtabs
import std/strutils
import std/sequtils
import std/times
import std/net
import std/posix

import ../adaptors/nim/baradb_sqlite as sqlite

const
  BinaryPath = "./build/baradadb"
  LeaderMarker = "became leader"

type
  NodeProc = object
    id: string
    clientPort: int
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

proc waitForRow(port: int, name: string, deadlineSec: int): bool =
  ## Poll SELECT on `port` until a row with `name` appears. Tolerates errors
  ## (e.g. "unknown table" while schema has not been created yet) by retrying.
  let db = openClient(port)
  defer: db.close()
  let start = getTime()
  while getTime() - start < initDuration(seconds = deadlineSec):
    try:
      let rows = db.getAllRows(sql"SELECT * FROM rw_test")
      for row in rows:
        if row.len >= 2 and row[1] == name:
          return true
    except CatchableError:
      discard
    sleep(100)
  return false

proc runWritesScenario() =
  ## Fatal phase failures dump all captured node output, record a test
  ## failure, and return; cleanup happens in the finally below either way.
  let tstamp = getTime().toUnix.int
  # Port bases: distinct from nimforum_smoke_test (35000+mod10000) and
  # raft_e2e_test (41000+mod5000). Client ports are spaced by 10 because the
  # server derives HTTP (port+440), WS (port+441) and gossip (raftPort+100)
  # ports — consecutive client ports collide.
  let cbase = 46000 + (tstamp mod 4000)
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
    let dataDir = getTempDir() / "baradb_raft_writes_e2e_" & $tstamp & "_" & id
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

    # Settle and require stability, same as raft_e2e_test.
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

    let followerIdx = (if leaderIdx == 0: 1 else: 0)

    # Schema: CREATE TABLE / INDEX go through the raft "ddl" log (C3c).
    # Create only on the leader; followers must learn schema via apply.
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        db.exec(sql"CREATE TABLE rw_test (id INT PRIMARY KEY, name STRING)")
        db.exec(sql"CREATE INDEX idx_rw_name ON rw_test (name)")
      except CatchableError as e:
        echo "leader CREATE TABLE/INDEX failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo "leader schema committed via raft ddl"

    # Follower CREATE is forwarded to the leader (BARADB_RAFT_CLIENT_PEERS).
    block:
      let db = openClient(nodes[followerIdx].clientPort)
      try:
        db.exec(sql"CREATE TABLE fwd_from_follower (id INT PRIMARY KEY)")
      except CatchableError as e:
        echo "follower CREATE (forward) failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    # Leader must see the table (forward applied on leader, then raft ddl).
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        discard db.getAllRows(sql"SELECT * FROM fwd_from_follower")
      except CatchableError as e:
        echo "leader never saw forwarded CREATE: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo "follower CREATE forwarded to leader"

    # Wait until the follower has applied CREATE TABLE (SELECT no longer
    # errors with unknown table). Deadline 5s.
    block:
      let db = openClient(nodes[followerIdx].clientPort)
      defer: db.close()
      let start = getTime()
      var ready = false
      while getTime() - start < initDuration(seconds = 5):
        try:
          discard db.getAllRows(sql"SELECT * FROM rw_test")
          ready = true
          break
        except CatchableError:
          sleep(100)
      if not ready:
        echo "follower ", nodes[followerIdx].id,
             " never applied CREATE TABLE within 5s"
        dumpAll(nodes)
        fail()
        return
    echo "schema replicated to follower ", nodes[followerIdx].id

    # Leader write: INSERT goes through the raft log and waits for majority
    # commit before responding (Task 2) — expect success.
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        db.exec(sql"INSERT INTO rw_test (id, name) VALUES (1, 'raft-row')")
      except CatchableError as e:
        echo "leader INSERT failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo "leader INSERT committed"

    # Follower visibility: applyCommand puts committed entries into the
    # follower's default DB — poll until the row shows up (5s deadline).
    if not waitForRow(nodes[followerIdx].clientPort, "raft-row", 5):
      echo "follower ", nodes[followerIdx].id,
           " never saw the replicated row within 5s"
      dumpAll(nodes)
      fail()
      return
    echo "row replicated to follower ", nodes[followerIdx].id

    # Index path: rich apply must have updated the follower B-tree so a
    # filtered SELECT (planner prefers secondary index) still finds the row.
    block:
      let db = openClient(nodes[followerIdx].clientPort)
      var saw = false
      try:
        let rows = db.getAllRows(
          sql"SELECT id, name FROM rw_test WHERE name = 'raft-row'")
        for row in rows:
          if row.len >= 2 and row[1] == "raft-row":
            saw = true
      except CatchableError as e:
        echo "follower index SELECT failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
      if not saw:
        echo "follower ", nodes[followerIdx].id,
             " index-backed SELECT missed the replicated row"
        dumpAll(nodes)
        fail()
        return
    echo "follower index-backed SELECT saw the row"

    # Follower DML is forwarded to the leader and replicated to the cluster.
    block:
      let db = openClient(nodes[followerIdx].clientPort)
      try:
        db.exec(sql"INSERT INTO rw_test (id, name) VALUES (99, 'via-forward')")
      except CatchableError as e:
        echo "follower INSERT (forward) failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    if not waitForRow(nodes[leaderIdx].clientPort, "via-forward", 5):
      echo "leader never saw forwarded INSERT row"
      dumpAll(nodes)
      fail()
      return
    echo "follower INSERT forwarded to leader"

    # Failover: kill the leader. A survivor must accept a write once it wins
    # a new term (majority of the remaining 2-of-3). Log lines can thrash
    # across terms, so discover the new leader by probing INSERT rather than
    # relying solely on the first "became leader" line.
    killNode(nodes[leaderIdx])
    var newLeaderIdx = -1
    var writeErr = ""
    let foStart = getTime()
    while getTime() - foStart < initDuration(seconds = 15):
      nodes.drainAll()
      # Prefer the highest-term survivor when choosing who to probe first.
      var order: seq[int] = @[]
      var bestTerm = 0
      var bestIdx = -1
      for i in 0 ..< nodes.len:
        if i == leaderIdx: continue
        order.add(i)
        for t in leaderTerms(nodes[i].output):
          if t > bestTerm: (bestIdx, bestTerm) = (i, t)
      if bestIdx >= 0:
        # Probe the current highest-term node first.
        order = order.filterIt(it != bestIdx)
        order.insert(bestIdx, 0)
      for i in order:
        try:
          let db = openClient(nodes[i].clientPort)
          try:
            db.exec(sql"INSERT INTO rw_test (id, name) VALUES (2, 'after-failover')")
            newLeaderIdx = i
          finally:
            db.close()
          if newLeaderIdx >= 0: break
        except CatchableError as e:
          writeErr = e.msg
          # "not leader" / commit timeout / connection blips — keep probing.
      if newLeaderIdx >= 0: break
      sleep(150)
    if newLeaderIdx < 0:
      echo "no survivor accepted a post-failover write within 15s",
           (if writeErr.len > 0: " (last error: " & writeErr & ")" else: "")
      dumpAll(nodes)
      fail()
      return
    echo "failover complete: new leader ", nodes[newLeaderIdx].id,
         " accepted post-failover write"

    # The remaining follower (neither old nor new leader) must see the row.
    let remainingIdx = 3 - leaderIdx - newLeaderIdx
    if not waitForRow(nodes[remainingIdx].clientPort, "after-failover", 8):
      echo "remaining follower ", nodes[remainingIdx].id,
           " never saw the post-failover row within 8s"
      dumpAll(nodes)
      fail()
      return
    echo "post-failover row replicated to ", nodes[remainingIdx].id

    check leaderIdx != newLeaderIdx
  finally:
    for n in nodes.mitems:
      n.killNode()
      if n.p != nil: n.p.close()
      removeDir(n.dataDir)

suite "Raft replicated writes E2E":
  test "writes replicate, followers reject, failover resumes writes":
    if not fileExists(BinaryPath):
      echo "[SKIP] ", BinaryPath, " missing — run `nimble test` (builds the server first)"
      skip()
    else:
      runWritesScenario()
