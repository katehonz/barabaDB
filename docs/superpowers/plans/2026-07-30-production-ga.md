# Production GA v1.2.0 — Implementation Plan

> **For agentic workers:** implement task-by-task; checkboxes track progress.
> Spec first: `docs/superpowers/specs/2026-07-30-production-ga-design.md`.

**Goal:** Close the “never production” loop: tagged **v1.2.0**, secure prod
compose, proven backup/restore, runbook + known limitations — **single-node
GA**. Raft stays documented experimental for multi-node.

**Architecture:** No new database features. Work is release engineering, ops
scripts, doc honesty, and small fail-closed security defaults for prod.

**Tech stack:** existing Nim binary, Docker, `core/backup.nim`, compose, unittest.

---

## Global constraints

- Spec: `docs/superpowers/specs/2026-07-30-production-ga-design.md`.
- Do **not** expand Raft/SQL surface unless a bug blocks backup/release.
- Prefer scripts under `scripts/` over one-off shell history.
- Commits: small, green where possible; **tag only after Task 6** (or controller tags after review).
- Branch: work on `main` (or short `chore/v1.2.0-ga` merged same day).
- Test baseline: `nimble test` or documented equivalent; at least
  `test_all` + `bugfix_test` + schema persist + one e2e if binary present.

---

## Phase map

| Phase | Tasks | Outcome |
|-------|-------|---------|
| **P0 Freeze** | T1 | Scope freeze + limitations draft |
| **P1 Secure prod** | T2–T3 | Auth fail-closed + compose hardened |
| **P2 Recoverability** | T4–T5 | Backup/restore script + CI-able drill |
| **P3 Release** | T6–T7 | Version bump, CHANGELOG, tag, image |
| **P4 Docs** | T8–T9 | Runbook + limitations + README GA claim |
| **P5 Optional** | T10 | App smoke on release binary |

---

### Task 1: Scope freeze + known-limitations draft

**Files:**
- Create: `docs/en/known-limitations.md`
- Create: `docs/bg/known-limitations.md` (short mirror)
- Modify: `docs/superpowers/specs/2026-07-30-production-ga-design.md` (status → In progress)

**Content (en) must state clearly:**

| Area | GA (v1.2.0) | Experimental / later |
|------|-------------|----------------------|
| Single-node SQL + storage | Supported | — |
| Auth + JWT | Supported when configured | — |
| Raft 3-node | Experimental ops | InstallSnapshot, multi-DB, membership |
| Multi-database | Supported non-raft | Raft only `default` |
| Follower reads + indexes | Best-effort after apply | Linearizable read API |
| ORC multi-thread | Not supported (ARC default) | — |

- [ ] **Step 1:** Write both limitation pages (link from index if any).
- [ ] **Step 2:** Link from `docs/en/deployment.md` and `docs/en/distributed.md` top.
- [ ] **Step 3:** Commit  
  `docs: known-limitations for v1.2.0 production GA scope`

---

### Task 2: Production auth fail-closed

**Files:**
- Modify: `docker-compose.prod.yml` (auth **on** by default via env required)
- Modify: `src/barabadb/core/config.nim` and/or `src/baradadb.nim` **only if** needed:
  - When `BARADB_ENV=production` or `BARADB_AUTH_REQUIRED=true`: refuse start if `authEnabled` false or `jwtSecret` empty/default
- Prefer env-only compose change first; code gate if compose alone is insufficient

**Acceptance:**
- Prod compose documents `BARADB_JWT_SECRET` as required (use `${BARADB_JWT_SECRET:?set me}` compose syntax).
- `BARADB_AUTH_ENABLED=true` uncommented / default true in prod file.
- Dev `docker-compose.yml` unchanged (still easy local).

- [ ] **Step 1:** Harden `docker-compose.prod.yml`.
- [ ] **Step 2:** Optional start-time check for production profile.
- [ ] **Step 3:** Manual: compose config fails without secret.
- [ ] **Step 4:** Commit  
  `fix(prod): require JWT secret and auth in production compose`

---

### Task 3: Fix prod compose footguns

**Files:**
- Modify: `docker-compose.prod.yml`
- Modify: `docs/en/deployment.md` (ports: HTTP = TCP+440, not fictional BARADB_HTTP_PORT if wrong)

**Checks:**
- Healthcheck hits real `/health` port (9472+440=9912 already — verify matches binary).
- WAL/sync env names match `config.nim` (`BARADB_WAL_*` etc.).
- systemd snippet in deployment.md uses correct env vars (fix `BARADB_HTTP_PORT` myth if present).
- Resource limits OK for compose v2 (note `deploy` may be ignored outside swarm — document).

- [ ] **Step 1:** Align env names + docs.
- [ ] **Step 2:** Commit  
  `docs(prod): align compose and deployment ports/env with runtime`

---

### Task 4: Backup/restore drill script

**Files:**
- Create: `scripts/backup-restore-drill.sh` (or `.nim` if better)
- Uses: `build/baradadb` or docker + `build/backup` / `src/barabadb/core/backup.nim`

**Script behavior:**
1. Create temp data dir; start server (or use offline backup of prepared dir).
2. Insert known row via client/curl/HTTP or wire (prefer simplest: HTTP if no auth in drill mode, or use backup tool offline after writing with embedded test).
3. Run full backup to `backup_$$.tar.gz`.
4. Stop server; **wipe** data dir.
5. Restore archive.
6. Start server; **SELECT** proves row exists.
7. Exit 0/1; print paths.

**Acceptance:** script runs twice consecutively on a clean machine with deps installed.

- [ ] **Step 1:** Implement script.
- [ ] **Step 2:** Run twice; capture output in PR description or comment.
- [ ] **Step 3:** Commit  
  `test(ops): automated backup/restore drill script`

---

### Task 5: Document backup ops in deployment runbook section

**Files:**
- Modify: `docs/en/deployment.md` — section **Runbook**
- Modify: `docs/bg/deployment.md` — short mirror
- Link `docs/en/backup.md` for details

**Runbook must include:**
- Ports: binary `BARADB_PORT`, HTTP `+440`, WS `+441`, raft `BARADB_RAFT_PORT`
- Start/stop (binary + compose prod)
- Data dir layout
- Backup command (all-databases)
- Restore procedure + “stop server first”
- Logs (`BARADB_LOG_FILE`, docker volume)
- Health/metrics URLs
- Where known-limitations live

- [ ] **Step 1:** Write runbook sections.
- [ ] **Step 2:** Commit  
  `docs: production runbook (start/stop/backup/restore)`

---

### Task 6: Version bump + CHANGELOG freeze

**Files:**
- Modify: `baradadb.nimble` → `version = "1.2.0"`
- Modify: `CHANGELOG.md` — `## [1.2.0] — 2026-07-30` (or actual ship date); move Unreleased leftovers if any under 1.2.0
- Modify: `README.md` version blurb
- Modify: health version string if hardcoded `1.1.6` in httpserver (align or use single source)

**Acceptance:**
- No “Unreleased” raft/storage/search if they ship in 1.2.0; new Unreleased empty or only post-GA items.

- [ ] **Step 1:** Bump versions + changelog date.
- [ ] **Step 2:** Align `/health` version if needed.
- [ ] **Step 3:** Commit  
  `release: prepare v1.2.0 changelog and version bump`

---

### Task 7: Tag + release artifact

**Steps (controller / human with push rights):**
- [ ] `git tag -a v1.2.0 -m "BaraDB v1.2.0 Production GA (single-node)"`
- [ ] `git push origin main --tags`
- [ ] Build release binary: `nimble build_release` (or documented `nim c -d:release`)
- [ ] Build Docker image: `docker build -t baradb:1.2.0 -t baradb:latest .`
- [ ] Optional: GH/Gitea release notes = CHANGELOG 1.2.0 section

**Do not force-push tags.**

---

### Task 8: README production claim (honest)

**Files:**
- Modify: `README.md`

**Replace hype with:**
- **Production GA (single-node):** v1.2.0 — backup/restore, auth prod compose, runbook
- **Raft cluster:** experimental — link distributed.md + known-limitations

- [ ] **Step 1:** Edit README status tables / quickstart prod pointer.
- [ ] **Step 2:** Commit  
  `docs: README production GA vs raft experimental`

---

### Task 9: CI / release checklist file

**Files:**
- Create: `docs/en/release-checklist.md`

**Checklist content:**
- [ ] `nimble test` (or subset listed)
- [ ] `scripts/backup-restore-drill.sh`
- [ ] `raft_e2e` / `raft_writes_e2e` if binary built (optional for single-node GA)
- [ ] docker build
- [ ] compose prod config validate
- [ ] tag

- [ ] **Step 1:** Write checklist; link from deployment.md.
- [ ] **Step 2:** Commit  
  `docs: v1.2.0 release checklist`

---

### Task 10 (optional): App smoke on release binary

**Files:**
- Possibly none; run `tests/nimforum_smoke_test` or ormin smoke against `./build/baradadb`

- [ ] **Step 1:** Document command in release-checklist.
- [ ] **Step 2:** Run once green; note in changelog “verified with …”.

---

## Task dependency graph

```
T1 limitations
 ├── T2 auth prod
 ├── T3 compose footguns
 ├── T4 backup drill
 │    └── T5 runbook (uses drill)
 ├── T6 version/changelog
 │    └── T7 tag/artifacts  (after T2–T6)
 ├── T8 README honesty
 └── T9 release checklist
T10 optional after T7
```

## Explicit out-of-scope (do not sneak in)

- New raft features, membership, InstallSnapshot payload
- Multi-DB raft
- Benchmark campaigns for marketing
- Rewriting clients

## Definition of Done (whole plan)

- [ ] All P0–P4 tasks complete
- [ ] Tag `v1.2.0` on origin
- [ ] Backup drill green twice
- [ ] Known-limitations + runbook linked from README/deployment
- [ ] Prod compose cannot start without JWT secret (compose and/or binary)

## Estimated effort

| Phase | Effort |
|-------|--------|
| P0–P1 | 0.5–1 day |
| P2 | 0.5–1 day |
| P3–P4 | 0.5 day |
| P5 optional | 0.5 day |
| **Total** | **~2–3 focused days** |

---

## After GA

Open `v1.3.0-raft-supported` plan only if needed: failover under load, CI e2e mandatory, cold-node story, raft TLS.
