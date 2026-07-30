# Production GA (v1.2.0) — Design / cut line

Date: 2026-07-30  
Status: **Approved direction** — implementation follows the plan  
`docs/superpowers/plans/2026-07-30-production-ga.md`.

## Problem

BaraDB has substantial features (storage hardening, search, engine persistence,
Raft cluster path) but “production” never arrives because work stays on the
feature treadmill without a **release + ops cut line**.

## Goal

Ship **v1.2.0 Production GA** for a defined scope:

> **Single-node (or single primary) BaraDB suitable for real applications**,
> with documented limits, tested backup/restore, secure-by-default prod
> compose, tagged release, and a one-page runbook.

Raft multi-node remains **supported experimental / ops-documented**, not the
GA reliability target for v1.2.0.

## Non-goals (v1.2.0)

- Multi-database Raft
- InstallSnapshot full SM dump / automatic cold-node catch-up beyond AppendEntries
- Membership changes (add/remove voters)
- Raft TLS
- Replacing Postgres HA marketing claims
- New major SQL/AI features

## Success definition

| # | Criterion |
|---|-----------|
| 1 | Git tag `v1.2.0`; `baradadb.nimble` + README version **1.2.0** |
| 2 | `CHANGELOG.md` section **[1.2.0]** dated (not Unreleased) |
| 3 | `docker-compose.prod.yml`: **auth required** (or fails closed if secret missing) |
| 4 | Scripted backup → wipe data → restore → query succeeds |
| 5 | `nimble test` green on release-shaped build (or documented subset + binary e2e) |
| 6 | Runbook: start/stop/backup/restore/logs/ports in `docs/en/deployment.md` |
| 7 | Known limitations page (single-node GA vs raft experimental) |
| 8 | Optional: one smoke app path (nimforum or ormin) on release binary |

## Threat model (honest)

**In scope for GA:** process crash, disk full (document), operator restore, unauthenticated internet (mitigated by auth-on in prod).

**Out of scope for GA:** multi-region, zero-downtime upgrades, perfect follower-read consistency, multi-tenant SaaS isolation audit.

## Architecture of the release

```
[build release binary + image]
        │
        ▼
[prod compose: auth + data volume + healthcheck]
        │
        ▼
[backup tool / HTTP backup] ──► offsite copy
        │
        ▼
[restore drill script] proves recoverability
        │
        ▼
[tag + docs + known-limitations]
```

## Follow-on (v1.3.0 — not this plan)

- Raft cluster “supported” tier: failover under write load, CI e2e, cold peer story  
- Multi-DB raft or explicit product refusal  
- InstallSnapshot / membership  

## References

- Raft status: `docs/superpowers/specs/2026-07-30-raft-cluster-status.md`
- Ops: `docs/en/distributed.md`, `docs/en/backup.md`, `docs/en/deployment.md`
- Compose: `docker-compose.prod.yml`
