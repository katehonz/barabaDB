# Networked Raft Bootstrap (C3a) — Design

Date: 2026-07-30  
Status: **Done** (merged to `main`). See also `2026-07-30-raft-cluster-status.md`.

## Problem

Raft in BaraDB was half-wired for real networking. `core/raft.nim` already had
a TCP transport, but production never populated `peerAddrs`, never ran an
election timer, did not reset timers on AppendEntries, skipped state
persistence, and used unsafe partial frame reads.

## Goal

A 3-node BaraDB cluster elects a leader over TCP, maintains it with heartbeats,
and re-elects after the leader is killed — verified with real processes
(`tests/raft_e2e_test.nim`).

## Delivered

| Item | Implementation |
|------|----------------|
| Peer addresses | `BARADB_RAFT_PEERS=id@host:port` → `raftPeerAddrs` |
| Election timer | `timerLoop` inside `RaftNetwork.run` |
| Heartbeat reset | `processMessage` resets timer on AppendEntries with valid term |
| State persistence | `dataDir` → `raft_state.bin` |
| Partial reads | `recvExact` frame reassembly |
| E2E | `tests/raft_e2e_test.nim` (election + failover) |

## Non-goals (handled later)

SQL writes (C3b), DDL/forward/compact/metrics (post-C3b / C3c-lite) — all
shipped; see cluster status doc. Still open: membership, InstallSnapshot SM
payload, multi-DB raft.
