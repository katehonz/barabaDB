# BaraDB — Ревизия за бъгове и план за подобрения

> Дата: 2026-05-13
> Статус: **ВСИЧКИ критични/високи/средни бъгове поправени — v1.0.0 READY**
> Последно обновяване: 2026-05-13

## Обобщение

| Категория | Общо | Поправени | Остават |
|-----------|------|-----------|---------|
| 🔴 Критични | 9 | 9 | 0 |
| 🟠 Високи | 7 | 7 | 0 |
| 🟡 Средни | 12 | 12 | 0 |
| 🟢 Конфигурационни | 4 | 4 | 0 |

**Общ брой тестове:** 294 — всички минават.

---

## 🔴 Критични бъгове (всички поправени ✅)

1. **MVCC — Aborted транзакции стават видими** ✅ — `abortedTxns: HashSet[TxnId]` + `committedTxnsSet`
2. **LSM-Tree — Загуба на данни при immutable memtable overwrite** ✅ — flush преди презапис
3. **LSM-Tree — Счупена SSTable търсачка** ✅ — сортиране по `id` (descending)
4. **Auth — JWT подписът е тривиално forgeable** ✅ — HMAC-SHA256 чрез `checksums/sha2`
5. **Auth — SCRAM-SHA-256 е фалшив** ✅ — заменен с истински RFC 7677 SCRAM-SHA-256 със salt + iteration count + challenge-response
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

## 🔧 Конфигурационни проблеми (всички поправени ✅)

| # | Проблем | Файл | Статус |
|---|---------|------|--------|
| 29 | `nimble build` fail-ва без `-d:ssl` | `baradadb.nimble` | ✅ `nim.cfg` с `-d:ssl` |
| 30 | `bench` task сочи към несъществуващ файл | `baradadb.nimble` | ✅ `bench_all.nim` |
| 31 | CI build benchmarks без `-d:ssl` | `.github/workflows/ci.yml` | ✅ поправено |
| 32 | `threadpool` е deprecated (Nim 2.2) | `src/baradadb.nim` | ✅ warning suppressed (non-critical) |

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

## 📋 Сесия 8 — v1.0.0 финален спринт

### Build warnings cleanup

| # | Warning | Файл | Fix |
|---|---------|------|-----|
| 35 | `threadpool` deprecated | `baradadb.nim` | `{.push warning[Deprecated]: off.}` около import |
| 36 | unused `import std/os` | `logging.nim` | Премахнат |
| 37 | `ImplicitDefaultValue` | `ast.nim` | `line: int = 0, col: int = 0` |
| 38 | `CStringConv` (2x) | `wal.nim` | `posix.open(cstring(wal.path), O_RDONLY)` |
| 39 | `HoleEnumConv` | `server.nim` | Локално suppress с pragma |

### TLA+ symmetry reduction

| # | Задача | Статус |
|---|--------|--------|
| 40 | `SYMMETRY` добавен във всички 9 `.cfg` файла | ✅ |
| 41 | `Permutations` дефиниции в `.tla` спековете | ✅ |

### `crossmodal.tla`

| # | Задача | Статус |
|---|--------|--------|
| 42 | 10-ти TLA+ спек за cross-modal consistency | ✅ 170 реда, 5 invariants |

### Auth SCRAM-SHA-256

| # | Задача | Файл | Статус |
|---|--------|------|--------|
| 43 | SCRAM-SHA-256 модул (RFC 7677) | `protocol/scram.nim` | ✅ PBKDF2 + HMAC + SHA-256 + nonce/salt generation |
| 44 | AuthManager SCRAM integration | `protocol/auth.nim` | ✅ `registerScramUser`, `startScram`, `finishScram` |
| 45 | HTTP SCRAM endpoints | `core/httpserver.nim` | ✅ `/auth/scram/start` + `/auth/scram/finish` |
| 46 | SCRAM тестове | `tests/test_all.nim` | ✅ 2 теста (full handshake + invalid proof rejection) |

---

## 🎯 Ключеви метрики (финални)

| Метрика | Текущ статус |
|---------|-------------|
| Тестове | 294 — 0 failure-а ✅ |
| Критични бъгове | 0 ✅ |
| Високи бъгове | 0 ✅ |
| Средни бъгове | 0 ✅ |
| TLA+ спецификации | 10 — всички с symmetry reduction ✅ |
| Security audit | Всички 🔴 и 🟠 поправени ✅ |
| Build | Компилира, 0 warnings ✅ |

---

## Оставащи задачи (post-v1.0.0, non-critical за single-node)

1. ~~Build warnings cleanup~~ ✅
2. ~~Threadpool deprecation~~ ✅ (warning suppressed)
3. ~~Auth SCRAM-SHA-256~~ ✅
4. ~~TLA+ symmetry reduction~~ ✅
5. ~~`crossmodal.tla`**~~ ✅
6. **Replication data transfer** — `writeLsn` да изпраща данни към replicas
7. **Sharding data migration** — `rebalance` да мигрира ключове
8. **Property-based / fuzz tests** — storage engine edge cases
