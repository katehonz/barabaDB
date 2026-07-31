# Release checklist — v1.3.0 raft-supported

Use before tagging and publishing artifacts.

## Pre-flight

- [ ] Working tree clean on `main`
- [ ] [Known limitations](known-limitations.md) accurate
- [ ] `CHANGELOG.md` has dated `## [1.3.0]` (not Unreleased for shipped items)
- [ ] `baradadb.nimble` version `1.3.0`

## Tests

```bash
nim c -o:build/baradadb src/baradadb.nim
nim c -o:build/backup src/barabadb/core/backup.nim

nim c -d:ssl --threads:on --path:src -r tests/test_all.nim
nim c -d:ssl --threads:on --path:src -r tests/bugfix_test.nim
nim c -d:ssl --threads:on --path:src -r tests/test_schema_persist.nim

# Ops drill (twice)
./scripts/backup-restore-drill.sh
DRILL_PORT=19482 ./scripts/backup-restore-drill.sh

# Cluster e2e (raft supported tier — all five suites)
./tests/raft_e2e_test
./tests/raft_writes_e2e_test
./tests/raft_failover_load_e2e_test
./tests/raft_tls_e2e_test
./tests/raft_coldnode_e2e_test
```

## Production compose

```bash
export BARADB_JWT_SECRET="$(openssl rand -hex 32)"
docker compose -f docker-compose.prod.yml config >/dev/null
# must fail without secret:
# (unset BARADB_JWT_SECRET; docker compose -f docker-compose.prod.yml config)
```

## Artifacts

```bash
nimble build_release   # or: nim c -d:release -o:build/baradadb src/baradadb.nim
docker build -t baradb:1.3.0 -t baradb:latest .
```

## Tag

```bash
git tag -a v1.3.0 -m "BaraDB v1.3.0 raft-supported"
git push origin main --tags
```

## Post-release

- [ ] Smoke: start prod compose, `/health` → ok, auth required for `/query`
- [ ] Announce: raft-supported release (3-node, `default` DB); link known-limitations
