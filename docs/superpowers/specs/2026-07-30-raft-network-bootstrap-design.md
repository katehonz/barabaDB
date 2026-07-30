# Networked Raft Bootstrap (C3a) — Design

Date: 2026-07-30
Status: Approved direction (user: "продължи"); implementation follows.

## Problem

Raft in BaraDB is half-wired for real networking. `core/raft.nim` already has
a TCP transport (`RaftNetwork`, binary framing, serialization, election-over-
TCP proven by a test), but in production:

1. `node.peerAddrs` is **never populated** (`baradadb.nim` creates the node
   from `config.raftPeers` but never parses addresses) — all sends silently
   no-op (`raft.nim:560-561`).
2. **No election timer runs** — `tick` is only called from tests; a deployed
   node never starts an election.
3. `handleAppendEntries` on the wire path does **not reset the election
   timer** — even if timers ran, followers would start elections despite a
   healthy leader.
4. Raft **state persistence is disabled** in server startup (`dataDir` not
   passed to `newRaftNode`, `baradadb.nim:333`).
5. Framing reads assume full TCP reads (`recv(4)`/`recv(payloadLen)`,
   `raft.nim:604-611`) — partial reads corrupt the stream.

Result: `BARADB_RAFT_ENABLED=true` today starts a listening socket that can
never elect anyone. This phase wires what exists; it does NOT change the SQL
write path (that is C3b) or add membership/snapshots (C3c).

## Goal

A 3-node BaraDB cluster started with ordinary config elects a leader over
TCP, maintains it with heartbeats, and re-elects after the leader is killed —
verified end-to-end with real server processes.

Non-goals: SQL writes through Raft (C3b), membership changes, snapshots,
reconnect/backoff hardening, TLS/auth on the raft port (C3c).

## Design

### 1. Peer address configuration

- Env (existing mechanism): `BARADB_RAFT_PEERS` entries extended from bare
  `nodeId` to `nodeId@host:port`. Comma-separated, e.g.
  `BARADB_RAFT_PEERS="n1@127.0.0.1:9473,n2@127.0.0.1:9474,n3@127.0.0.1:9475"`.
  Bare entries (no `@`) keep current meaning (peer id, no address).
- Parsing lives in `core/config.nim` next to the existing `BARADB_RAFT_*`
  env handling (config.nim:174-179), producing `raftPeerAddrs: Table[string,
  (string, int)]` on BaraConfig. Malformed entries fail startup with a clear
  error (config-time, not runtime).
- `baradadb.nim` startup copies `config.raftPeerAddrs` into
  `node.peerAddrs` and passes the data dir (see §3).

### 2. Election timer in production

- A `timerLoop` async proc in `core/raft.nim` (next to `heartbeatLoop`,
  raft.nim:625): every 50ms calls `tick(node)`; on election timeout calls
  the existing `startElection` path (raft.nim:659-685), which sends
  RequestVote over `RaftNetwork.send`.
- `RaftNetwork.run` (raft.nim:633) starts `timerLoop` alongside
  `heartbeatLoop` via `asyncCheck` — single place, no baradadb.nim changes
  beyond startup wiring.
- Wire-path timer reset: in the message-receive handling of `RaftNetwork`,
  after a valid AppendEntries (or heartbeat) is processed, reset the
  follower's election timer (`ElectionTimer.lastHeartbeat = now`) — wherever
  the existing handler processes inbound AppendEntries, matching what the
  in-process tests do manually.

### 3. State persistence on

- `baradadb.nim:333`: pass `config.dataDir` (or a raft subdirectory of it —
  check what `newRaftNode` expects; `saveState`/`loadState` write
  `raft_state.bin`) so currentTerm/votedFor/log survive restarts, per the
  Raft spec (and the TLA models).

### 4. Framing robustness

- Replace the `recv(4)` / `recv(payloadLen)` assumptions with the existing
  `recvExact`-style helper pattern used by the main server
  (`core/server.nim:312-329` has `recvExact`/`recvExactWithTimeout` — mirror
  the approach inside raft.nim; do NOT import server.nim into raft.nim).

### 5. What does NOT change

- SQL write path (ReplicationManager, server.nim) — untouched.
- Raft state machine, message format, serialization — untouched (the TLA-
  faithfulness tests pin them).
- `applyCommand` hook in baradadb.nim — stays as-is; committed entries
  (from tests / future C3b) still apply to the default DB.

## Testing

TDD where feasible; the headline test is end-to-end:

1. **Config parsing** (unit, `tests/test_all.nim` or bugfix_test): peers
   with and without `@host:port`, malformed entries error clearly.
2. **Framing** (unit): partial-read feed of a serialized message through the
   new read path (socketpair or chunked strings) — message reassembles.
3. **E2E cluster** (new file `tests/raft_e2e_test.nim`): start 3 real
   `build/baradadb` processes with raft enabled on distinct ports
   (client/raft ports offset per node), wait for a leader (queryable how?
   — simplest: each node logs its role; or a `RAFT STATUS` text command on
   the client port if one exists cheaply — decide in the plan), kill the
   leader, assert a new leader is elected within ~5s. Clean teardown.
4. Existing suites stay green (`nimble test`, 659+ `[OK]`) — especially the
   in-process raft suites and the 3-node election TCP test.

## Risks

- Election-timer/async interactions with the main server's async loop —
  `RaftNetwork.run` already runs under `asyncCheck`; timerLoop follows the
  same pattern. Watch for CPU spin (50ms sleep, not busy loop).
- Port allocation in the E2E test (parallel CI) — use the same
  time-derived port offset pattern as `tests/nimforum_smoke_test.nim`.
- Timer reset wiring point: the inbound message path must reach the node
  the timer ticks — same `RaftNode` instance, verified by the E2E test
  (no spurious elections under a healthy leader).
