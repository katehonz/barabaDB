## Raft E2E — real 3-node cluster over the TCP transport.
## Starts three actual build/baradadb processes, waits for one to log
## leadership, kills it, and waits for a survivor to take over.
## Process-management conventions follow tests/nimforum_smoke_test.nim.
import std/unittest
import std/osproc
import std/os
import std/strtabs
import std/strutils
import std/times
import std/net
import std/posix

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

proc runClusterScenario() =
  ## Fatal phase failures dump all captured node output, record a test
  ## failure, and return; cleanup happens in the finally below either way.
  let tstamp = getTime().toUnix.int
  # Port bases: distinct from nimforum_smoke_test (35000+mod10000) and from
  # the in-process raft tests in test_all (29011-29025). Client ports are
  # spaced by 10 because the server derives HTTP (port+440), WS (port+441)
  # and gossip (raftPort+100) ports — consecutive client ports collide.
  let cbase = 41000 + (tstamp mod 5000)
  let rbase = cbase + 100
  let peers = "n1@127.0.0.1:" & $(rbase + 1) &
              ",n2@127.0.0.1:" & $(rbase + 2) &
              ",n3@127.0.0.1:" & $(rbase + 3)

  var nodes: seq[NodeProc]
  for i in 1 .. 3:
    let id = "n" & $i
    let dataDir = getTempDir() / "baradb_raft_e2e_" & $tstamp & "_" & id
    createDir(dataDir)
    var env = newStringTable()
    for key, val in envPairs():
      env[key] = val
    env["BARADB_PORT"] = $(cbase + i * 10)
    env["BARADB_RAFT_ENABLED"] = "true"
    env["BARADB_RAFT_PORT"] = $(rbase + i)
    env["BARADB_RAFT_NODE_ID"] = id
    env["BARADB_RAFT_PEERS"] = peers
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

    # Simultaneous boot often causes a split first election — a normal Raft
    # retry, not a bug. Settle, take the highest-term leader, then require
    # stability: no higher term (i.e. no new election) for another second.
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

    # Failover: kill the leader; a survivor must win a HIGHER term within 10s.
    killNode(nodes[leaderIdx])
    var newLeaderIdx = -1
    let foStart = getTime()
    while getTime() - foStart < initDuration(seconds = 10):
      for i in 0 ..< nodes.len:
        if i == leaderIdx: continue
        nodes[i].drainOutput()
        for t in leaderTerms(nodes[i].output):
          if t > leaderTerm:
            newLeaderIdx = i
            break
        if newLeaderIdx >= 0: break
      if newLeaderIdx >= 0: break
      sleep(50)
    if newLeaderIdx < 0:
      echo "no failover leader within 10s after killing ", nodes[leaderIdx].id
      dumpAll(nodes)
      fail()
      return
    echo "failover complete: new leader ", nodes[newLeaderIdx].id

    check leaderIdx != newLeaderIdx
  finally:
    for n in nodes.mitems:
      n.killNode()
      if n.p != nil: n.p.close()
      removeDir(n.dataDir)

suite "Raft E2E cluster":
  test "3-node election and failover":
    if not fileExists(BinaryPath):
      echo "[SKIP] ", BinaryPath, " missing — run `nimble test` (builds the server first)"
      skip()
    else:
      runClusterScenario()
