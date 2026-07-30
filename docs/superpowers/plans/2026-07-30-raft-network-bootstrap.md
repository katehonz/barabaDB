# Networked Raft Bootstrap (C3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 3-node BaraDB cluster started with ordinary config elects a leader over TCP, maintains it with heartbeats, and re-elects after the leader is killed.

**Architecture:** Wire the existing half-built pieces: parse `id@host:port` peers into `node.peerAddrs` (config → startup), run a real election-timer loop inside `RaftNetwork.run` (with timer reset on inbound AppendEntries), pass `dataDir` for raft state persistence, and make frame reads partial-read-safe. SQL write path untouched (C3b); no membership/snapshots (C3c).

**Tech Stack:** Nim 2.2.10, ARC, unittest, real server processes for E2E.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-30-raft-network-bootstrap-design.md` (read first).
- Test command per task: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all` — exit 0, 461+ `[OK]`. Final task: full `nimble test` (659+ `[OK]`).
- The Raft state machine, message format, and serialization are FROZEN (TLA-faithfulness tests pin them) — changes only in: config parsing, startup wiring, timer loop, timer reset, frame reading.
- No new dependencies. Env-only config for this phase (no JSON config section).
- Commits per task after green; source files only; no push (controller merges+pushes).
- Verified facts to use:
  - `newRaftNode*(id, peers, raftPort, dataDir)` (raft.nim:139-161) — dataDir enables saveState/loadState (`raft_state.bin`).
  - `RaftNetwork` (raft.nim:546-557) has node/socket/running/peerSockets; `run` (633-645) starts heartbeatLoop; `processMessage` (588-599) dispatches inbound; `receiveLoop` (601-623) has the unsafe `recv(4)`/`recv(payloadLen)` reads.
  - `ElectionTimer` (raft.nim:430-452) wraps a node with its own `timeoutMs`; `newElectionTimer(node, timeoutMs)`; `resetTimeout` sets lastHeartbeat; `tick(timer, net)` (668-685) drives election start; `startElection` (659-666).
  - `node.electionTimeout` is 150+rand(150)ms (raft.nim:154); heartbeatTimeout 50ms. Pass `node.electionTimeout` as the timer's timeoutMs.
  - Startup: `src/baradadb.nim:330-352` — creates node WITHOUT dataDir, never sets peerAddrs, `asyncCheck raftNet.run()`.
  - Config: `core/config.nim:37-40` (raft fields), env parsing at `174-179` (`BARADB_RAFT_PEERS` comma-split).
  - recvExact pattern to mirror: `core/server.nim:312-329` (mirror the approach inside raft.nim; do NOT import server.nim into raft.nim).
  - Heartbeats ARE AppendEntries messages (`heartbeatLoop` → `node.appendEntries(peer)` → rmkAppendEntries), so resetting the timer on rmkAppendEntries covers heartbeats.
  - Existing TCP election test: `tests/test_all.nim:2350-2391` (manual peerAddrs + manual ticks) — must stay green.

---

### Task 1: Peer address config + startup wiring

**Files:**
- Modify: `src/barabadb/core/config.nim` (raftPeerAddrs field + env parsing)
- Modify: `src/baradadb.nim` (pass peerAddrs + dataDir to the raft node)
- Test: `tests/bugfix_test.nim` (config parsing tests — it imports config already; check) or a small new suite in `tests/test_all.nim` if config import cycles arise (prefer bugfix_test; it already imports `barabadb/core/config`)

**Interfaces:**
- Consumes: existing `BARADB_RAFT_PEERS` env parsing (config.nim:176-178).
- Produces:
  - `raftPeerAddrs*: Table[string, tuple[host: string, port: int]]` on BaraConfig (init in defaultConfig).
  - Parsing rule: each comma entry `id@host:port` → peers gets `id`, raftPeerAddrs gets `id → (host, port)`; bare `id` → peers only. Malformed entries (empty id, `@` without host, non-numeric port) raise `ValueError` with the offending entry in the message (fail at config time).
  - `cfg.raftPeers` contains ONLY ids after parsing (strip the `@host:port` part).

- [ ] **Step 1: Failing tests**

New suite in `tests/bugfix_test.nim`:

```nim
suite "Raft peer address parsing":
  test "id@host:port entries populate raftPeerAddrs":
    # set env BARADB_RAFT_PEERS="n1@127.0.0.1:9473,n2@10.0.0.5:9474,n3"
    # call loadConfigFromEnv on a defaultConfig
    # check raftPeers == @["n1", "n2", "n3"]
    # check raftPeerAddrs["n1"] == ("127.0.0.1", 9473); "n3" notin raftPeerAddrs
  test "malformed peer entries raise with the entry in the message":
    # "n1@:9473" / "n1@host:notaport" / "@host:9473" → expect ValueError containing the entry
```

(Use `putEnv`/`delEnv` around `loadConfigFromEnv(cfg)`; check its signature at config.nim:~150-179. Restore env after each test.)

- [ ] **Step 2: Run, watch them fail**

Expected: compile error or assertion failure — `raftPeerAddrs` does not exist yet.

- [ ] **Step 3: Implement**

1. config.nim: add `raftPeerAddrs*` field + init; parse in loadConfigFromEnv right after the existing peersEnv split (strip, split on last `@` — IPv4/hostnames have no `@`; validate host non-empty and port parseInt 1..65535).
2. baradadb.nim:330-352: after `newRaftNode(config.raftNodeId, config.raftPeers, config.raftPort, dataDir = config.dataDir / "raft")` — create the subdir if newRaftNode doesn't (`createDir`); then `raftNode.peerAddrs = config.raftPeerAddrs`.

- [ ] **Step 4: Run, watch them pass**

`tests/bugfix_test` green; `tests/test_all` green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/core/config.nim src/baradadb.nim tests/bugfix_test.nim
git commit -m "feat(raft): parse id@host:port peers, enable raft state persistence"
```

---

### Task 2: Production election timer + reset on inbound AppendEntries

**Files:**
- Modify: `src/barabadb/core/raft.nim` (timer field on RaftNetwork, timerLoop, reset in processMessage, start timerLoop in run)
- Test: `tests/test_all.nim` (add to the existing raft/election suites)

**Interfaces:**
- Consumes: ElectionTimer/tick/startElection (raft.nim:659-685), processMessage (588-599), run (633-645).
- Produces:
  - `RaftNetwork.timer*: ElectionTimer` (created in `newRaftNetwork` with `node.electionTimeout`).
  - `timerLoop(net: RaftNetwork) {.async.}` — while net.running: `tick(net.timer, net)`, `await sleepAsync(50)`.
  - `run` starts `asyncCheck net.timerLoop()` next to heartbeatLoop; `stop` stops the timer.
  - In `processMessage`, `of rmkAppendEntries:` — `net.timer.resetTimeout()` when the message's term is >= node's currentTerm (i.e., a plausible current leader; do NOT reset on stale-term messages — check handleAppendEntries' term logic and mirror its acceptance condition).

- [ ] **Step 1: Failing tests**

Add to the raft suites in `tests/test_all.nim`:

```nim
  test "timerLoop elects a leader without manual ticks":
    # 3 in-process RaftNodes with peerAddrs pointed at each other via real TCP
    # (mirror the existing "3-node election over TCP" setup at test_all.nim:2350-2391
    #  but do NOT call tick manually — rely on timerLoop)
    # start nets with run(); wait up to ~3s until some node.state == rsLeader
    # assert exactly one leader; stop all nets
  test "inbound AppendEntries resets the election timer":
    # node A (follower) with net + timer; craft a valid AppendEntries from "leader"
    # with term >= A.currentTerm; set timer.lastHeartbeat far in the past;
    # await net.processMessage(msg); assert not timer.checkTimeout()
```

(If the 2350-2391 test's setup helpers are reusable, reuse them; the key difference: no manual ticking.)

- [ ] **Step 2: Run, watch them fail**

Expected: first test — no leader elected within timeout (no timerLoop exists); second — timer still timed out after processMessage.

- [ ] **Step 3: Implement**

Per Produces above. Keep `newRaftNetwork(node)` creating the timer (existing constructions keep working). Ensure `stop` also stops the timer so the new test doesn't leak loops.

- [ ] **Step 4: Run, watch them pass**

`tests/test_all` green, including the pre-existing manual-tick TCP election test.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/core/raft.nim tests/test_all.nim
git commit -m "feat(raft): run election timer in production, reset on AppendEntries"
```

---

### Task 3: Partial-read-safe framing

**Files:**
- Modify: `src/barabadb/core/raft.nim` (receiveLoop reads)
- Test: `tests/test_all.nim`

**Interfaces:**
- Consumes: receiveLoop (raft.nim:601-623), serialize/deserializeRaftMessage (494-539).
- Produces: `recvExact(client: AsyncSocket, size: int): Future[string] {.async.}` LOCAL to raft.nim (mirror core/server.nim:312-319 semantics: loop recv until size bytes or EOF returning short string); receiveLoop uses it for both the 4-byte header and the payload; EOF mid-frame → clean break, no exception escape.

- [ ] **Step 1: Failing test**

```nim
  test "framing reassembles chunked messages":
    # socketpair (std/net or asyncnet) or a real loopback listener:
    # serialize a RequestVote message; send it in 3 chunks with tiny sleeps;
    # the receive path must deliver exactly one intact message
    # (assert via a node handler effect, e.g. a vote reply, or by calling
    #  the read helper directly and deserializing)
```

(Pick the simplest reliable harness; a direct test of the local recvExact + deserialize is acceptable if full receiveLoop testing is awkward without a running net.)

- [ ] **Step 2: Run, watch it fail**

Expected: with raw `recv`, a chunked send yields a short read → break/no message (simulate or assert on the helper's absence via compile error — acceptable red state).

- [ ] **Step 3: Implement**

Add the local recvExact; rewire receiveLoop to use it for header and payload; keep the rest of receiveLoop byte-identical.

- [ ] **Step 4: Run, watch it pass**

`tests/test_all` green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/core/raft.nim tests/test_all.nim
git commit -m "fix(raft): partial-read-safe frame reassembly"
```

---

### Task 4: E2E 3-node cluster test + full verification

**Files:**
- Create: `tests/raft_e2e_test.nim`
- Modify: `baradadb.nimble` (add raft_e2e_test to the test task list)
- Modify: possibly `src/barabadb/core/raft.nim` (add an `info` log line in becomeLeader/becomeCandidate if none exists — check first; needed for the E2E to observe elections via process output)

**Interfaces:**
- Consumes: Tasks 1-3; `build/baradadb` binary (nimble test builds it first); port-offset pattern from `tests/nimforum_smoke_test.nim:16-30` (time-derived ports, env config, startProcess with poStdErrToStdOut + poDaemon, readiness poll).
- Produces: `tests/raft_e2e_test.nim` suite "Raft E2E cluster":
  - Node i (1..3): temp dataDir; env `BARADB_PORT=<base+i>`, `BARADB_RAFT_ENABLED=true`, `BARADB_RAFT_PORT=<rbase+i>`, `BARADB_RAFT_NODE_ID=n<i>`, `BARADB_RAFT_PEERS="n1@127.0.0.1:<rbase+1>,n2@127.0.0.1:<rbase+2>,n3@127.0.0.1:<rbase+3>"`, `BARADB_DATA_DIR=<tmp>`, `BARADB_LOG_LEVEL=info`.
  - Start all 3; within ~10s exactly one logs becoming leader (read process pipes non-blockingly — nimforum_smoke_test has the pattern).
  - Kill the leader process; within ~10s one of the survivors logs becoming leader.
  - Teardown: kill remaining processes, remove temp dirs. On any assertion failure, dump captured output to aid debugging.

- [ ] **Step 1: Write the test**

Follow nimforum_smoke_test.nim's process-management conventions. Guard total runtime < 60s with explicit timeouts; skip cleanly (with a printed reason) if `build/baradadb` is missing.

- [ ] **Step 2: Run it standalone**

`nim c -d:ssl --threads:on --path:src -o:tests/raft_e2e_test tests/raft_e2e_test.nim && ./tests/raft_e2e_test`
Expected: PASS (this is the feature acceptance test — if Tasks 1-3 are correct it passes; if the leader is never elected, debug via the dumped output — check peerAddrs wiring and timer first).

- [ ] **Step 3: Wire into nimble test**

Add "raft_e2e_test" to the test task list in baradadb.nimble AFTER nimforum_smoke_test (it also needs the server binary).

- [ ] **Step 4: Full suite**

`nimble test` — exit 0, 659+ `[OK]` (count grows with the new tests), 0 failed.

- [ ] **Step 5: Commit**

```bash
git add tests/raft_e2e_test.nim baradadb.nimble src/barabadb/core/raft.nim
git commit -m "test(raft): end-to-end 3-node cluster election and failover"
```

---

## Self-Review Notes

- Spec coverage: §1 peers → Task 1; §2 timer → Task 2; §3 dataDir → Task 1; §4 framing → Task 3; §5 testing E2E → Task 4. Frozen state machine honored — no handler changes.
- The timer reset condition (term >= currentTerm) mirrors handleAppendEntries' acceptance — Task 2's second test pins it; a wrong condition shows up as spurious elections in the E2E.
- Election timeout uses node.electionTimeout (randomized 150-300ms) → E2E expectations (10s) have wide margin; heartbeat 50ms keeps leaders stable.
- Risk flagged in spec (async CPU spin) — timerLoop sleeps 50ms per iteration, no busy loop.
