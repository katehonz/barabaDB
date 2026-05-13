# BaraDB — Ревизия за бъгове и план за подобрения

> Дата: 2026-05-12
> Статус: **ВСИЧКИ критични/високи/средни бъгове поправени**
> Последно обновяване: 2026-05-12

## Обобщение

| Категория | Общо | Поправени | Остават |
|-----------|------|-----------|---------|
| 🔴 Критични | 9 | 9 | 0 |
| 🟠 Високи | 7 | 7 | 0 |
| 🟡 Средни | 12 | 12 | 0 |
| 🟢 Конфигурационни | 4 | 3 | 1 |

**Общ брой тестове:** 292 — всички минават.

---

## 🔴 Критични бъгове (всички поправени ✅)

1. **MVCC — Aborted транзакции стават видими** ✅ — `abortedTxns: HashSet[TxnId]` + `committedTxnsSet`
2. **LSM-Tree — Загуба на данни при immutable memtable overwrite** ✅ — flush преди презапис
3. **LSM-Tree — Счупена SSTable търсачка** ✅ — сортиране по `id` (descending)
4. **Auth — JWT подписът е тривиално forgeable** ✅ — HMAC-SHA256 чрез `checksums/sha2`
5. **Auth — SCRAM-SHA-256 е фалшив** ✅ (частично) — `hmacSha256` в SCRAM path; истински challenge-response остава за дългосрочно
6. **Recovery — `summary()` мутира базата данни** ✅ — извиква `analyze()` вместо `recover()`
7. **DistTxn — Rollback след commit attempt нарушава atomicity** ✅ — no rollback след commit
8. **Raft — Majority calculation bug за четен брой нодове** ✅ — strict majority fix
9. **Query — `EXISTS` подзаявки винаги връщат false** ✅ — `executePlan` в `irekExists`

---

## 🟠 Високо приоритетни бъгове (всички поправени ✅)

| # | Модул | Проблем | Fix |
|---|-------|---------|-----|
| 10 | `storage/wal.nim` | `sync()` прави само `flush()`, не `fsync` | `posix.fsync()` |
| 11 | `protocol/ssl.nim` | Command injection в shell команди | `quoteShell()` |
| 12-13 | `protocol/wire.nim` | OOM/DoS + липса на bounds checking | 64MB limit + bounds checks + max depth |
| 14 | `query/executor.nim` | SQL injection в `exprToSql` | `'` → `''` |
| 15 | `query/executor.nim` | ReDoS в `irLike`/`irILike` | escape на regex metachars |
| 16 | `query/executor.nim` | Stale BTree indexes на UPDATE/DELETE | `BTree.remove()` + cleanup |

---

## 🟡 Средно приоритетни бъгове (всички поправени ✅)

| # | Модул | Проблем | Fix |
|---|-------|---------|-----|
| 17-19 | `query/lexer.nim` | Boolean parsing, malformed floats, unclosed comments | `tkTrue`/`tkFalse`, втора точка спира float, `ValueError` |
| 20 | `query/executor.nim` | Aggregate + `*` на empty result → crash | `sourceRows.len > 0` |
| 21 | `query/ir.nim` | Unary minus → boolean NOT | `ukNeg` → `irNeg` |
| 22 | `query/executor.nim` | Non-aggregate UDFs → NULL | `irekFuncCall` |
| 23-24 | `vector/engine.nim` | Dimension mismatch + HNSW без locking | `ValueError` + `Lock` |
| 25 | `fts/engine.nim` | UTF-8 tokenization мангира байтове | `runes` вместо байтове |
| 26 | `graph/engine.nim` | `addEdge` без node existence check | `KeyError` |
| 27 | `core/raft.nim` | Няма disk persistence | `saveState()`/`loadState()` |
| 28 | `core/server.nim` | `DISTTXN`/`REP` handlers без timeout | `recvWithTimeout()` |

---

## 🔧 Конфигурационни проблеми

| # | Проблем | Файл | Статус |
|---|---------|------|--------|
| 29 | `nimble build` fail-ва без `-d:ssl` | `baradadb.nimble` | ✅ `nim.cfg` с `-d:ssl` |
| 30 | `bench` task сочи към несъществуващ файл | `baradadb.nimble` | ✅ `bench_all.nim` |
| 31 | CI build benchmarks без `-d:ssl` | `.github/workflows/ci.yml` | ✅ поправено |
| 32 | `threadpool` е deprecated (Nim 2.2) | `src/baradadb.nim` | ❌ ОСТАВА — non-critical |

---

## 📋 Сесия 6 — Auth hardening (допълнително)

| # | Проблем | Файл | Статус |
|---|---------|------|--------|
| 33 | Auth token expiration (`exp`/`nbf`/`iat`) не се проверяват | `protocol/auth.nim` | ✅ Добавено `getMonoTime().ticks()` + timestamp validation |
| 34 | JWT signature comparison не е constant-time | `protocol/auth.nim` | ✅ Добавено `constantTimeEquals` с byte-by-byte XOR |

---

## 📋 Сесия 7 — TLA+ Formal Verification (backup & recovery)

| # | Задача | Статус |
|---|--------|--------|
| FV-10 | `backup.tla` — backup/restore/verify/cleanup | ✅ 166 реда, 6 invariants, TLC минава |
| FV-11 | `recovery.tla` — WAL REDO/UNDO replay | ✅ 253 реда, 4 invariants, TLC минава |

---

## 🎯 Ключеви метрики

| Метрика | Текущ статус |
|---------|-------------|
| Тестове | 292 — 0 failure-а ✅ |
| Критични бъгове | 0 ✅ |
| Високи бъгове | 0 ✅ |
| Средни бъгове | 0 ✅ |
| TLA+ спецификации | 9 — всички минават TLC ✅ |
| Security audit | Всички 🔴 и 🟠 поправени ✅ |
| Build | Компилира, 4 non-blocking warnings |

---

## 🔄 Оставащи задачи (всички non-critical)

1. ~~**Build warnings cleanup**~~ ✅ — implicit `cstring` conversion (wal.nim), `HoleEnumConv` (server.nim), unused `os` import (logging.nim), `ImplicitDefaultValue` (ast.nim)
2. **Threadpool deprecation** — миграция към `malebolgia`/`weave`/`taskpools`
3. ~~**Auth SCRAM-SHA-256**~~ ✅ — истински challenge-response със salt + iteration count
4. ~~**TLA+ symmetry reduction**~~ ✅ — `SYMMETRY` добавен във всички 9 `.cfg` файла + `Permutations` дефиниции в `.tla` спековете
5. ~~**`crossmodal.tla`**~~ ✅ — cross-modal consistency между document/vector/graph/FTS
6. **Replication data transfer** — `writeLsn` да изпраща данни към replicas
7. **Sharding data migration** — `rebalance` да мигрира ключове
8. **Property-based / fuzz tests** — storage engine edge cases
