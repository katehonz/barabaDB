# SQL Writes Through Raft (C3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Raft is enabled, SQL writes commit through the Raft log before the client sees success; followers reject writes naming the leader and apply committed entries via the existing applyCommand loop.

**Architecture:** Intercept at the server-level `executeQuery` (core/server.nim:206-227) — same hook point and same data source (`res.keyValuePairs`) the legacy ReplicationManager uses. Leader: execute locally, append one raft entry per KV pair (`"put"` = `key\x00value`, `"delete"` = `key` — the exact format baradadb.nim's applyCommand already consumes), poll `node.commitIndex` until the last appended index commits (no raft.nim changes — state machine stays TLA-frozen). Follower: reject before execution.

**Tech Stack:** Nim 2.2.10, ARC, unittest, real server processes for E2E.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-30-raft-sql-writes-design.md` (read first).
- Test command per task: `nim c -d:ssl --threads:on --path:src -o:tests/test_all tests/test_all.nim && ./tests/test_all` — exit 0. Final task: full `nimble test` (673+ `[OK]`).
- **raft.nim stays FROZEN** (state machine, handlers, message format, serialization — TLA-faithfulness tests pin them). All changes in server.nim / config.nim / exec/params.nim / executor.nim / baradadb.nim / tests.
- Non-raft deployments (`server.raftNode == nil`): byte-identical behavior — verify the raft code path is fully gated.
- No new dependencies. Commits per task after green; source files only; no push (controller merges+pushes).
- Verified facts to use:
  - Server hook: `core/server.nim:206-227` — parse at :213, `executor.executeQuery` at :218, legacy replication ship at :219-227 (`replication.writeLsn(data)` with `key\0value`). `executeQuery(db, ctx, query, params, replication)` is called from handleClient (:567 plain, :587 prepared).
  - Statement kinds: `nkInsert/nkUpdate/nkDelete/nkMerge` write directly; `nkCommitTxn` emits kvPairs at COMMIT (executor.nim:968-979); BEGIN/ROLLBACK are connection-local.
  - appendLog (raft.nim:355): `appendLog*(node, command, data): LogEntry` — returns empty entry (index 0) when not leader; replication ships on the next heartbeat (50ms); commit advances via handleAppendReply → applyCommitted (raft.nim:195-215, 407-421).
  - applyCommand format (baradadb.nim:336-343): `cmd == "put"` → data = `key \x00 value`; `cmd == "delete"` → data = `key`.
  - Delete kvPair convention: non-txn DELETE emits `(fullKey, @[])` (exec/dml.nim:241). **OPEN ITEM for Task 2: txn COMMIT emits `(key, version.value)` even when `version.isDelete` (executor.nim:971-976) — check whether version.value is empty for deletes (read core/mvcc.nim writeSet/VersionedValue); if not, change the COMMIT loop to emit `(key, @[])` for deletes so the raft "empty value = delete" rule holds.**
  - Config env parsing: core/config.nim:177-206 (BARADB_RAFT_* section).

---

### Task 1: isWrite helper + Server.raftNode + follower rejection

**Files:**
- Modify: `src/barabadb/query/exec/params.nim` (isWrite helper next to isDDL)
- Modify: `src/barabadb/core/server.nim` (raftNode field + rejection in executeQuery)
- Modify: `src/baradadb.nim` (assign server.raftNode when raft enabled)
- Test: `tests/bugfix_test.nim`

**Interfaces:**
- Produces:
  - `proc isWrite*(stmt: Node): bool` in exec/params.nim — true for `nkInsert, nkUpdate, nkDelete, nkMerge, nkCommitTxn` (check exact enum names in query/ast.nim; nkCommitTxn included because COMMIT emits kvPairs).
  - `Server.raftNode*: RaftNode` (nil default) — server.nim imports core/raft (verify no cycle: raft.nim must not import server.nim).
  - Rejection in server-level executeQuery (core/server.nim:206+): right after parse and the empty-stmts check, BEFORE `executor.executeQuery`:
    ```nim
    if server.raftNode != nil and isWrite(astNode.stmts[0]):
      let node = server.raftNode
      if node.state != rsLeader:
        let who = if node.leaderId.len > 0: node.leaderId else: "none elected"
        return (false, QueryResult(), "not leader; leader is '" & who & "'")
    ```
    (Adjust to the proc's actual error-return convention and to how it accesses the Server — if executeQuery is not a method, thread the raft node the same way `replication` is threaded; check the handleClient call sites at :567/:587 first and pick the smaller change.)

- [ ] **Step 1: Failing tests**

New suite in tests/bugfix_test.nim:

```nim
suite "Raft write classification":
  test "isWrite classifies DML and COMMIT":
    check isWrite(parse("INSERT INTO t (id) VALUES (1)").stmts[0])
    check isWrite(parse("UPDATE t SET id = 2").stmts[0])
    check isWrite(parse("DELETE FROM t WHERE id = 1").stmts[0])
    check isWrite(parse("COMMIT").stmts[0])
    check not isWrite(parse("SELECT * FROM t").stmts[0])
    check not isWrite(parse("CREATE TABLE t (id INT)").stmts[0])
    check not isWrite(parse("BEGIN").stmts[0])
    check not isWrite(parse("ROLLBACK").stmts[0])
```

(Adapt to bugfix_test.nim's imports — it has parser already.)

- [ ] **Step 2: Run, watch it fail**

Expected: compile error — `isWrite` undeclared.

- [ ] **Step 3: Implement**

The helper, the Server field, the rejection, the baradadb.nim assignment (`tcpServer.raftNode = raftNode` — check the actual server variable name and that raftNet/raftNode are in scope; they were hoisted in the C3a fix wave).

- [ ] **Step 4: Run, watch it pass**

bugfix_test green; test_all green (461+ [OK]).

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/query/exec/params.nim src/barabadb/core/server.nim src/baradadb.nim tests/bugfix_test.nim
git commit -m "feat(raft): classify writes, reject them on follower nodes"
```

---

### Task 2: Leader write path — append + wait-for-commit

**Files:**
- Modify: `src/barabadb/core/server.nim` (raft append + commit wait, replacing the legacy ship when raft active)
- Modify: `src/barabadb/core/config.nim` (raftWriteTimeoutMs + env)
- Modify: possibly `src/barabadb/query/executor.nim` (COMMIT delete kvPair convention — see OPEN ITEM)
- Test: `tests/test_all.nim` (in-process leader path)

**Interfaces:**
- Consumes: Task 1's isWrite + server.raftNode; appendLog; applyCommand format.
- Produces:
  - In server executeQuery after `res.success` (replacing the legacy replication ship when raftNode != nil):
    ```nim
    if server.raftNode != nil and res.keyValuePairs.len > 0:
      let node = server.raftNode
      var lastIdx = 0'u64
      for (key, value) in res.keyValuePairs:
        let entry = if value.len > 0:
            node.appendLog("put", cast[seq[byte]](key & "\x00" & cast[string](value)))
          else:
            node.appendLog("delete", cast[seq[byte]](key))
        if entry.index == 0:
          return (false, QueryResult(), "lost leadership during raft append")
        lastIdx = entry.index
      # wait for commit
      let deadline = getMonoTime() + initDuration(milliseconds = config.raftWriteTimeoutMs)
      while node.commitIndex < lastIdx and getMonoTime() < deadline:
        await sleepAsync(10)   # or the sync equivalent — check whether executeQuery is async; if it is NOT async, use os.sleep in a bounded loop
      if node.commitIndex < lastIdx:
        return (false, QueryResult(), "raft commit timeout")
    else if replication != nil and res.keyValuePairs.len > 0:
      <existing legacy ship, unchanged>
    ```
    CRITICAL: check whether server-level executeQuery (server.nim:206) is a sync proc under withStorageGate — if sync, the wait must not block the async event loop; use short os.sleep polling and keep the timeout small, or document. Match the codebase's reality, not this sketch.
  - `raftWriteTimeoutMs*: int` on BaraConfig (default 5000) + `BARADB_RAFT_WRITE_TIMEOUT_MS` env parsing in the raft section of loadConfigFromEnv.
  - COMMIT delete convention resolved (OPEN ITEM above): version.value empty for deletes, or executor.nim COMMIT loop fixed to emit `(key, @[])` for isDelete entries.

- [ ] **Step 1: Failing test**

In tests/test_all.nim (raft suites):

```nim
  test "leader append+commit wait round-trips through applyCommand":
    # 3 in-process nodes over TCP (reuse the "timerLoop elects a leader" setup from C3a Task 2)
    # wait for a leader; on the leader: appendLog("put", "users.1\x00alice")
    # poll leader.commitIndex until >= entry.index (deadline 3s)
    # assert a follower's applyCommand got invoked with ("put", data)
    #   (wire applyCommand on each node to record calls — check how baradadb.nim wires it)
  test "txn COMMIT delete kvPairs are empty-valued":
    # embedded ctx: BEGIN; INSERT; DELETE same row; COMMIT
    # assert res.keyValuePairs for the deleted key has value.len == 0
```

- [ ] **Step 2: Run, watch them fail**

Expected: first — no server-side helper exists yet (compile error or assertion); second — may already pass or fail depending on the OPEN ITEM finding; record which.

- [ ] **Step 3: Implement**

Per Produces. Resolve the sync/async question by reading server.nim:206-227 and its callers first; keep the wait bounded and simple.

- [ ] **Step 4: Run, watch them pass**

test_all green.

- [ ] **Step 5: Commit**

```bash
git add src/barabadb/core/server.nim src/barabadb/core/config.nim src/barabadb/query/executor.nim tests/test_all.nim
git commit -m "feat(raft): leader appends writes to raft log and waits for commit"
```

---

### Task 3: E2E — replicated writes across a real 3-node cluster

**Files:**
- Create: `tests/raft_writes_e2e_test.nim` (or extend tests/raft_e2e_test.nim — pick the cleaner; new file preferred to keep runtimes isolated)
- Modify: `baradadb.nimble` (wire into test task)

**Interfaces:**
- Consumes: Tasks 1-2; the E2E process harness from tests/raft_e2e_test.nim (port base, env setup, leader detection via the "became leader" log line, teardown); the Nim client via `adaptors/nim/baradb_sqlite` (pattern from tests/nimforum_smoke_test.nim: `open("127.0.0.1:" & $port, "", "", "default")`, `db.exec(sql"...")`, `db.getAllRows`).
- Produces: suite "Raft replicated writes E2E":
  1. Boot 3 nodes (raft enabled), wait for leader (log line).
  2. On the LEADER's client port: CREATE TABLE + INSERT a row (expect success).
  3. On a FOLLOWER's client port: poll `SELECT` until the row appears (deadline 5s; follower applies committed entries via applyCommand to its default DB).
  4. On a FOLLOWER: `INSERT` → expect an error containing "not leader".
  5. Kill the leader; wait for new leader; INSERT on the new leader succeeds; the row becomes visible on the remaining follower.
  6. Teardown all processes; dump captured output on any failure.

- [ ] **Step 1: Write the test**

Follow raft_e2e_test.nim conventions (O_NONBLOCK output drains, deadlines, skip-with-reason if build/baradadb missing, different port base from both nimforum_smoke_test and raft_e2e_test). Note: applyCommand applies to the DEFAULT database — use database "default" in the client.

- [ ] **Step 2: Run standalone (twice)**

`nim c -d:ssl --threads:on --path:src -o:tests/raft_writes_e2e_test tests/raft_writes_e2e_test.nim && ./tests/raft_writes_e2e_test`
Expected: PASS twice consecutively. If the follower never sees the row, debug order: raft commit wait (Task 2) → applyCommand wiring → default-DB targeting. Dump output on failure.

- [ ] **Step 3: Wire into nimble test + full suite**

Add to baradadb.nimble test list after raft_e2e_test; add the binary name to .gitignore next to tests/raft_e2e_test. Run `nimble test` — exit 0, 673+ `[OK]`.

- [ ] **Step 4: Commit**

```bash
git add tests/raft_writes_e2e_test.nim baradadb.nimble .gitignore
git commit -m "test(raft): E2E replicated writes, follower rejection, failover writes"
```

---

### Task 4: Docs + close-out

**Files:**
- Modify: `docs/superpowers/specs/2026-07-30-raft-sql-writes-design.md` (status → done)
- Modify: README.md only if it claims raft/replication behavior that changed (check `grep -n -i 'raft\|replicat' README.md | head -20` — update only now-false lines, minimally)

- [ ] **Step 1: Update docs**

- [ ] **Step 2: Commit**

```bash
git add docs/ README.md
git commit -m "docs: SQL writes through raft (C3b) done"
```

---

## Self-Review Notes

- Spec coverage: write classification → T1; follower rejection → T1; leader append+wait → T2; config → T2; E2E → T3; docs → T4. Non-goals honored (no forwarding, no DDL replication, raft.nim frozen).
- The COMMIT delete-convention open item is the main correctness risk (a deleted key resurrected on followers) — T2's second test pins it before it can ship.
- Double application on the leader is idempotent by KV semantics; T3's follower-visibility assertions prove the real path end-to-end.
