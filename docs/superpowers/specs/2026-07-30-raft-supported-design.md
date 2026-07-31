# v1.3.0 Raft-Supported — Design Spec

Date: 2026-07-30
Status: Draft
Follows: `2026-07-30-raft-cluster-status.md` (C3a/C3b/C3c-lite shipped),
`2026-07-30-production-ga-design.md` ("After GA" section).

## Goal

Move the raft cluster from **experimental** to **supported** by closing the
four gaps named in the GA plan: failover under load (proven, not assumed),
CI e2e mandatory, a cold-node story, and raft-port TLS.

Non-goals (unchanged from C3 status doc): multi-database raft, membership
change protocol, read consistency levels, `CREATE`/`DROP DATABASE`
replication.

## Current state (verified 2026-07-30)

- `src/barabadb/core/raft.nim` (919 lines): election, AppendEntries,
  safe-prefix compaction, metrics, plain-TCP `RaftNetwork` transport.
- Wiring: `src/baradadb.nim:337-377` (env `BARADB_RAFT_*`, state in
  `dataDir/raft/raft_state.bin`).
- Leader forwarding: `src/barabadb/core/server.nim:210-289`
  (`forwardQueryToLeader`, plain TCP).
- TLS infra exists for the client wire port only:
  `src/barabadb/protocol/ssl.nim` (`TLSConfig`, `TLSContext`, `wrapClient`,
  `wrapServer`); server accept loop wraps at `core/server.nim:876-889`.
- E2E: `tests/raft_e2e_test.nim` (election + failover),
  `tests/raft_writes_e2e_test.nim` (DDL/DML replication, forwarding,
  failover write probe). Both run under `nimble test`, which CI runs.

## Gap analysis

### G1. Failover under load — unproven

The existing failover test (`raft_writes_e2e_test.nim:349-405`) kills the
leader *while idle* and probes a single INSERT afterwards. Nothing tests a
write workload running *during* the leader crash, and nothing verifies that
every client-acknowledged write survives the failover (raft's core promise:
committed entries are never lost).

### G2. CI e2e — present but silently skippable

Both e2e suites `skip()` when `./build/baradadb` is missing
(`raft_writes_e2e_test.nim:413-417`). `nimble test` builds the binary first,
so CI runs them today — but a broken build step or a renamed binary turns a
raft regression into a silent green skip. There is also no dedicated CI job
that names raft e2e as a first-class gate.

### G3. Cold node — two real failure modes

1. **Log growth pinning.** Leader compaction
   (`raft.nim:244-276`, `compactLog`) never discards past any peer's
   `matchIndex`. A peer that is down keeps `matchIndex` stale, so the leader's
   log grows without bound for as long as the node is down.
2. **Unrecoverable laggard.** Once the leader's log no longer contains a
   follower's `nextIndex` (fresh/wiped node, or a node that was down through a
   compaction), the follower rejects every AppendEntries
   (`handleAppendEntries`, `raft.nim:380-394`) and the leader's
   `nextIndex` decrement floor is `lastSnapshotIndex + 1`
   (`handleAppendReply`, `raft.nim:526-531`). The pair is stuck forever: no
   InstallSnapshot path exists.

### G4. Raft port is plaintext

`RaftNetwork` uses bare `newAsyncSocket()` (`raft.nim:748-765`, `857-871`).
Any host that can reach the raft port can inject RequestVote/AppendEntries
frames. The TLS machinery in `protocol/ssl.nim` is not used here; leader
forwarding (`forwardQueryToLeader`) is likewise plaintext.

### G5. Raft write encoding loses empty-value puts (found 2026-07-30)

`appendWriteToRaft` (`core/server.nim:309-330`) encodes an empty value as
`"delete"`, but PK-only-table inserts legitimately produce empty values
(`execInsert`, `query/exec/dml.nim:60-90`) — such inserts are acked after
majority commit and then deleted everywhere on apply. Fixed as plan Task 1a
(explicit `deleted` flag on `ExecResult.keyValuePairs`).

## Design

### D1. Failover-under-load E2E (test-only)

New suite `tests/raft_failover_load_e2e_test.nim`, same process-management
conventions as `raft_writes_e2e_test.nim` (port base `50000 + tstamp mod
4000` to avoid collisions):

1. Boot a 3-node cluster, elect a leader, create `load_test` table via raft
   DDL.
2. Writer thread: sequential `INSERT INTO load_test (id) VALUES (n)`,
   `n = 1, 2, ...`, recording every *acknowledged* id. On error ("not
   leader", commit timeout, connection reset), probe both survivors and
   resume on whichever accepts.
3. At ~50 acknowledged writes, kill the leader.
4. Assert: a survivor accepts a write within **10 s** of the kill
   (availability bound).
5. Assert: after the new leader is stable and the remaining follower has
   caught up, `SELECT id FROM load_test` on **both** survivors contains
   **every acknowledged id** (committed writes never lost). Unacknowledged
   writes may be present or absent — this is documented, not asserted.

Also document the client-visible contract in `docs/en/distributed.md`:
in-flight writes during failover fail fast with an error; clients must
retry; acknowledged writes are durable across failover.

### D2. CI e2e mandatory

- New `raft-e2e` job in `.github/workflows/ci.yml`: setup Nim, build
  `build/baradadb`, run the three raft e2e suites explicitly with `CI=true`
  in the environment.
- Change skip semantics in all raft e2e suites: when `CI` env var is
  non-empty and `./build/baradadb` is missing, **fail** instead of `skip()`.
- Add `raft_failover_load_e2e_test` to the `nimble test` list in
  `baradadb.nimble`.

### D3. Cold node — InstallSnapshot

Extend the raft wire protocol and apply path:

**Protocol.** New message kinds `rmkInstallSnapshot`,
`rmkInstallSnapshotReply`, and new fields on `RaftMessage`:
`snapId: uint64`, `snapOffset: uint64`, `snapData: seq[byte]`,
`snapDone: bool`. `lastSnapshotIndex`/`lastSnapshotTerm` ride on the
existing fields (`prevLogIndex`/`prevLogTerm` are reused as the snapshot
base for this kind). Serialization appends the new fields with `atEnd`
guards (same backward-compatible pattern as `loadState`,
`raft.nim:163-167`); `RaftProtoVersion` stays 1 — mixed-version clusters
simply never send the new kind (old leaders never trigger it).

**Leader side.** Track consecutive AppendEntries rejections per peer. When
`nextIndex[peer]` has hit the `lastSnapshotIndex + 1` floor and the peer
still rejects, the peer is unrecoverably behind:

1. Build a snapshot archive of the **default database** data dir with the
   existing backup machinery (`backupDataDir` in
   `src/barabadb/core/backup.nim:225`) into a temp file.
2. Stream it in chunks (`BARADB_RAFT_SNAP_CHUNK_KB`, default 256 KB) as
   `rmkInstallSnapshot` messages over the existing peer socket.
3. On final ack, set `matchIndex[peer] = lastSnapshotIndex`,
   `nextIndex[peer] = lastSnapshotIndex + 1`, resume normal AppendEntries.

**Follower side.** On `rmkInstallSnapshot`:

1. Buffer chunks to a temp file under `dataDir/raft/snap_incoming/`.
2. On `snapDone`, hand the archive to a new injected callback
   `restoreSnapshot: proc(archivePath: string): bool {.gcsafe.}` (wired in
   `baradadb.nim` where the `DatabaseRegistry` lives): close the default
   DB, `restoreDataDir` (`backup.nim:263`) into the default DB dir, reopen,
   and swap execution context.
3. Set `lastSnapshotIndex`/`lastSnapshotTerm`/`commitIndex`/`lastApplied`
   from the message, clear the log, `saveState`.

**Unpinning compaction.** Once InstallSnapshot exists, `compactLog` on the
leader compacts through `lastApplied` for peers whose `matchIndex` was
updated within the last `BARADB_RAFT_PEER_STALE_MS` (default 30 000);
long-dead peers no longer pin the log — they get a snapshot when they
return. Follower compaction is unchanged.

**Fresh-node join** falls out for free: a wiped node rejects at the floor
and receives a snapshot.

### D4. Raft TLS

Config (env, mirroring existing `BARADB_TLS_*`):

| Env | Config field | Default |
|-----|--------------|---------|
| `BARADB_RAFT_TLS_ENABLED` | `raftTlsEnabled: bool` | false |
| `BARADB_RAFT_TLS_CERT_FILE` | `raftTlsCertFile: string` | "" |
| `BARADB_RAFT_TLS_KEY_FILE` | `raftTlsKeyFile: string` | "" |
| `BARADB_RAFT_TLS_CA_FILE` | `raftTlsCaFile: string` | "" |
| `BARADB_RAFT_TLS_VERIFY_PEER` | `raftTlsVerifyPeer: bool` | false |

- `RaftNetwork` gains `tls: TLSContext` (nil = plaintext, current
  behavior). `connectToPeer` wraps with `wrapClient`; the accept loop in
  `run` wraps with `wrapServer` before `receiveLoop` (same pattern as
  `core/server.nim:876-889`). `verifyPeer` + CA file gives mutual auth.
- Fail closed: `raftEnabled and raftTlsEnabled` with missing cert/key →
  refuse to start (raise at startup, like the JWT check in
  `newServerWithRegistry`, `core/server.nim:58-63`).
- Leader SQL forwarding (`forwardQueryToLeader`) wraps its socket with the
  **client** TLS context when `BARADB_TLS_ENABLED` is on (it dials the
  client wire port, which is already TLS-capable).
- E2E: TLS variant cluster test — generate self-signed certs with
  `generateSelfSignedCert` (`protocol/ssl.nim:79`), boot a 3-node cluster
  with raft TLS on, assert election + one replicated write; assert a
  plaintext peer cannot join (its frames are rejected and the cluster
  elects among the TLS nodes).

## Rollout / phases

| Phase | Deliverable | Risk |
|-------|-------------|------|
| P1 | D1 failover-load e2e | none (test-only) |
| P2 | D2 CI e2e job | none |
| P3 | D4 raft TLS | medium (transport) |
| P4 | D3 InstallSnapshot + compaction unpin | high (protocol + apply) |

P3 before P4 so snapshot transfer ships already-encryptable. Each phase is
independently mergeable; P4 is the v1.3.0 gate for calling raft
"supported".

## Acceptance (v1.3.0)

- Failover-under-load e2e green locally and in CI, in the mandatory gate.
- Killed-node-returns and wiped-node-join scenarios converge without manual
  intervention (covered by new e2e phases).
- Leader log length stays bounded while a peer is down > `PEER_STALE_MS`
  (assert via `baradb_raft_log_entries` metric in e2e).
- Raft port TLS: cluster runs fully over TLS; plaintext injection fails.
- `docs/en/distributed.md` + `known-limitations.md` updated: raft no longer
  "experimental" for the covered scope; remaining non-goals listed.
