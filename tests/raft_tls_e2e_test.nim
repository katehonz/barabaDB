## Raft TLS E2E — real 3-node cluster with TLS on the raft transport.
## Starts three actual build/baradadb processes with per-node self-signed
## certs (BARADB_RAFT_TLS_ENABLED + CERT/KEY_FILE), asserts election and
## replicated writes work over the encrypted transport, then starts a 4th
## plaintext node pointed at the same peers and asserts it never becomes
## leader (its frames are undecryptable) while the TLS cluster keeps
## operating among its 3 members.
## Process-management conventions follow tests/raft_writes_e2e_test.nim
## (copying is the repo's e2e convention — do not factor out).
##
## NOTE: only the raft port is TLS here. The SQL client port stays
## plaintext (BARADB_TLS_ENABLED is the client wire port — a different
## feature), so the baradb_sqlite adaptor connects as usual.
import std/unittest
import std/osproc
import std/os
import std/strtabs
import std/strutils
import std/times
import std/net
import std/posix

import ../adaptors/nim/baradb_sqlite as sqlite
import barabadb/protocol/ssl

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

proc waitForRow(port: int, table, name: string, deadlineSec: int): bool =
  ## Poll SELECT on `port` until a row with `name` appears. Tolerates errors
  ## (e.g. "unknown table" while schema has not been created yet) by retrying.
  let db = openClient(port)
  defer: db.close()
  let start = getTime()
  while getTime() - start < initDuration(seconds = deadlineSec):
    try:
      let rows = db.getAllRows(sql("SELECT * FROM " & table))
      for row in rows:
        if row.len >= 2 and row[1] == name:
          return true
    except CatchableError:
      discard
    sleep(100)
  return false

proc startNode(id: string, clientPort, raftPort: int, peers, clientPeers: string,
               tlsEnabled: bool): NodeProc =
  ## Boots one build/baradadb process. When tlsEnabled, a self-signed cert
  ## (CN = node id) is generated into the node's data dir first.
  let tstamp = getTime().toUnix.int
  let dataDir = getTempDir() / "baradb_raft_tls_e2e_" & $tstamp & "_" & id
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
  env["BARADB_DATA_DIR"] = dataDir
  env["BARADB_LOG_LEVEL"] = "info"
  if tlsEnabled:
    let (certFile, keyFile) = generateSelfSignedCert(dataDir, id)
    doAssert certFile.len > 0 and keyFile.len > 0,
      "openssl cert generation failed for " & id
    env["BARADB_RAFT_TLS_ENABLED"] = "true"
    env["BARADB_RAFT_TLS_CERT_FILE"] = certFile
    env["BARADB_RAFT_TLS_KEY_FILE"] = keyFile
  let p = startProcess(BinaryPath, env = env,
                       options = {poStdErrToStdOut, poDaemon})
  discard fcntl(p.outputHandle.cint, F_SETFL,
                fcntl(p.outputHandle.cint, F_GETFL) or O_NONBLOCK)
  NodeProc(id: id, clientPort: clientPort, p: p, dataDir: dataDir, alive: true)

proc runTlsScenario() =
  ## Fatal phase failures dump all captured node output, record a test
  ## failure, and return; cleanup happens in the finally below either way.
  let tstamp = getTime().toUnix.int
  # Port base per the T6 brief: distinct from raft_writes_e2e_test
  # (46000+mod4000). Client ports are spaced by 10 because the server
  # derives HTTP (port+440), WS (port+441) and gossip (raftPort+100)
  # ports — consecutive client ports collide.
  let cbase = 54000 + (tstamp mod 4000)
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
    nodes.add startNode("n" & $i, cbase + i * 10, rbase + i,
                        peers, clientPeers, tlsEnabled = true)

  # Negative-case node: same peers, raft TLS DISABLED, own dir and ports
  # (4th port in each base range). Started later, after the TLS cluster is
  # up, so the positive assertions are not polluted by its noise.
  var rogue: NodeProc

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

    # Election over TLS: timeouts are 150-300ms, heartbeat 50ms — a leader
    # should emerge within ~2s; 10s deadline for margin.
    var elected = false
    let electStart = getTime()
    while getTime() - electStart < initDuration(seconds = 10):
      nodes.drainAll()
      if maxLeader(nodes).idx >= 0:
        elected = true
        break
      sleep(50)
    if not elected:
      echo "no leader elected within 10s over TLS"
      dumpAll(nodes)
      fail()
      return

    # Settle and require stability, same as raft_writes_e2e_test.
    nodes.drainFor(2000)
    let (leaderIdx, leaderTerm) = maxLeader(nodes)
    nodes.drainFor(1000)
    let (stableIdx, stableTerm) = maxLeader(nodes)
    if stableIdx != leaderIdx or stableTerm != leaderTerm:
      echo "TLS cluster unstable: leadership moved from ", nodes[leaderIdx].id,
           " (term ", leaderTerm, ") to ", nodes[stableIdx].id,
           " (term ", stableTerm, ")"
      dumpAll(nodes)
      fail()
      return
    echo "TLS leader elected: ", nodes[leaderIdx].id, " (term ", leaderTerm, ")"

    let followerIdx = (if leaderIdx == 0: 1 else: 0)

    # Schema: CREATE TABLE goes through the raft "ddl" log (C3c) — this
    # proves raft DDL replication works over the TLS transport.
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        db.exec(sql"CREATE TABLE tls_test (id INT PRIMARY KEY, name STRING)")
      except CatchableError as e:
        echo "leader CREATE TABLE failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo "leader schema committed via raft ddl over TLS"

    # Wait until the follower has applied CREATE TABLE (SELECT no longer
    # errors with unknown table). Deadline 5s.
    block:
      let db = openClient(nodes[followerIdx].clientPort)
      defer: db.close()
      let start = getTime()
      var ready = false
      while getTime() - start < initDuration(seconds = 5):
        try:
          discard db.getAllRows(sql"SELECT * FROM tls_test")
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
    echo "schema replicated to follower ", nodes[followerIdx].id, " over TLS"

    # Leader write: INSERT goes through the raft log and waits for majority
    # commit before responding — expect success over TLS.
    block:
      let db = openClient(nodes[leaderIdx].clientPort)
      try:
        db.exec(sql"INSERT INTO tls_test (id, name) VALUES (1, 'tls-row')")
      except CatchableError as e:
        echo "leader INSERT failed: ", e.msg
        dumpAll(nodes)
        fail()
        return
      db.close()
    echo "leader INSERT committed over TLS"

    # Follower visibility: poll until the row shows up (5s deadline).
    if not waitForRow(nodes[followerIdx].clientPort, "tls_test", "tls-row", 5):
      echo "follower ", nodes[followerIdx].id,
           " never saw the replicated row within 5s"
      dumpAll(nodes)
      fail()
      return
    echo "row replicated to follower ", nodes[followerIdx].id, " over TLS"

    # Negative scenario: start the plaintext node pointed at the same peers.
    # Its TLS-less frames are undecryptable to the cluster, so it can never
    # collect votes and must never become leader.
    rogue = startNode("n4", cbase + 40, rbase + 4, peers, clientPeers,
                      tlsEnabled = false)
    block:
      let readyStart = getTime()
      var ok = false
      while getTime() - readyStart < initDuration(seconds = 10):
        if portOpen(rogue.clientPort):
          ok = true
          break
        sleep(100)
      if not ok:
        echo "plaintext node never became ready"
        rogue.drainOutput()
        echo "===== output of ", rogue.id, " (port ", rogue.clientPort, ") ====="
        echo rogue.output
        dumpAll(nodes)
        fail()
        return
    echo "plaintext node n4 started against the TLS peers"

    # Give n4 many election cycles (timeouts 150-300ms) to try its luck.
    # The TLS cluster must keep operating among its 3 members meanwhile.
    nodes.drainFor(6000)

    # Cluster still elects/operates: leader among the 3 TLS nodes accepts a
    # write and it replicates to a follower, with n4 running.
    nodes.drainAll()
    let (leaderIdx2, leaderTerm2) = maxLeader(nodes)
    if leaderIdx2 < 0:
      echo "TLS cluster lost its leader after plaintext node joined"
      dumpAll(nodes)
      fail()
      return
    let followerIdx2 = (if leaderIdx2 == 0: 1 else: 0)
    block:
      let db = openClient(nodes[leaderIdx2].clientPort)
      try:
        db.exec(sql"INSERT INTO tls_test (id, name) VALUES (2, 'still-tls')")
      except CatchableError as e:
        echo "post-plaintext INSERT failed on ", nodes[leaderIdx2].id,
             " (term ", leaderTerm2, "): ", e.msg
        rogue.drainOutput()
        echo "===== output of ", rogue.id, " (port ", rogue.clientPort, ") ====="
        echo rogue.output
        dumpAll(nodes)
        fail()
        return
      db.close()
    if not waitForRow(nodes[followerIdx2].clientPort, "tls_test", "still-tls", 5):
      echo "post-plaintext row never replicated to ", nodes[followerIdx2].id
      dumpAll(nodes)
      fail()
      return
    echo "TLS cluster kept operating with plaintext node present"

    # Final negative assertion: n4 never won an election.
    rogue.drainOutput()
    if rogue.output.contains(LeaderMarker):
      echo "plaintext node became leader — TLS isolation broken"
      echo "===== output of ", rogue.id, " (port ", rogue.clientPort, ") ====="
      echo rogue.output
      dumpAll(nodes)
      fail()
      return
    echo "plaintext node never became leader (TLS rejection confirmed)"

    check leaderIdx2 >= 0
  finally:
    for n in nodes.mitems:
      n.killNode()
      if n.p != nil: n.p.close()
      removeDir(n.dataDir)
    if rogue.p != nil:
      rogue.killNode()
      rogue.p.close()
      removeDir(rogue.dataDir)

suite "Raft TLS E2E":
  test "3-node TLS cluster elects and replicates; plaintext node rejected":
    if not fileExists(BinaryPath):
      if getEnv("CI").len > 0:
        echo "[FAIL] ", BinaryPath, " missing under CI — build step broken?"
        fail()
      else:
        echo "[SKIP] ", BinaryPath, " missing — run `nimble test` (builds the server first)"
        skip()
    else:
      runTlsScenario()
