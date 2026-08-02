# BaraDB — Deep Audit (август 2026)

> Дата: 2026-08-02
> Метод: 4 паралелни одит-агента по слоеве (Storage / Query / Core / Protocol), всеки чете всички файлове в обхвата си и проверява находките срещу реалния код.
> Обхват: **само нови дефекти** — 80-те вече оправени в `BUGS.md` / `BUG_AUDIT.md` / `BARADB_CLIENT_BUGS.md` са изключени.
> **Общо: ~28 находки | Поправени: 17 (батч 1: 5 + батч 2: 12, вкл. hygiene) | Остават: 12**

---

## Поправени — батч 1 (5)

| # | Severity | Проблем | Файл | Fix |
|---|----------|---------|------|-----|
| C1 | 🔴 CRITICAL | **MIGRATE handler без auth gate** — неавтентикиран клиент пишеше произволни key/value в базата (`handleMigrationMessage → applyMigrationBatch → storeKeys → db.put`). Открито независимо от 2 агента. | `core/server.nim:682` | Добавен `if not authenticated: ... continue` (като REP/DISTTXN блоковете) |
| C2 | 🔴 CRITICAL | **Raft commit quorum off-by-one за even-N** — `(N+1) div 2` commit-ваше с малцинство при четен брой възли (N=4 → 2/4). Election-ът ползваше коректното strict majority. *GA обхватът е 3-node (нечетно), където формулите съвпадат.* | `core/raft.nim:653` | `let majority = (node.peers.len + 1) div 2 + 1` (съвпада с election); регресионен тест за 4-node |
| H1 | 🟠 HIGH | **Pre-auth memory-exhaustion DoS** — `parseHeader` не ограничаваше `length` (uint32 до ~4 GiB); `recvExactWithTimeout` пре-алокира преди auth check. | `core/server.nim:168` | Reject `length > uint32(MaxWireStringLen)` (64 MB) преди алокация |
| H4 | 🟠 HIGH | **`**` и `++` се lower-ваха към equality** — `bkPow`/`bkConcat` липсваха в op-mapping case-а и попадаха в `else: irEq` (`2 ** 3` → `false`, `'a' ++ 'b'` → `false`). | `query/exec/lower.nim:79` | `of bkPow: irOp = irPow`, `of bkConcat: irOp = irAdd`; 2 регресионни теста |
| H5 | 🟠 HIGH | **`!=` не е отрицание на `=`** — `irNeq` short-circuit-ваше на string inequality, така че `5 != 5.0` → true, но `5 = 5.0` → true. | `query/exec/eval.nim:438` | `irNeq` numeric-first (точно допълнение на `irEq`); регресионен тест |

## Поправени — батч 2 (12)

| # | Severity | Проблем | Файл | Fix |
|---|----------|---------|------|-----|
| H3 | 🟠 HIGH | **Semi-sync partial/zero ack** — връщаше LSN дори при 0 acks | `core/replication.nim` | `return 0` когато connected replicas < `syncReplicaCount` acks; 0 connected → local-only (като sync) |
| H6 | 🟠 HIGH | **`COUNT/SUM/AVG(DISTINCT)` игнорира DISTINCT** | `query/exec/lower.nim`, `plan_exec.nim` | `aggDistinct = node.funcDistinct`; dedup с `HashSet` в agg пътищата |
| H7 | 🟠 HIGH | **`UNION/INTERSECT/EXCEPT` KeyError** | `query/executor.nim` | Dedup fingerprint от projected cols, не `row["$value"]` |
| H8 | 🟠 HIGH | **`MERGE … THEN DELETE` / matched condition no-op** | `query/executor.nim` | Honor `mergeMatchedDelete` + `mergeMatchedCondition` |
| H9 | 🟠 HIGH | **WAL recovery crash на torn record** | `storage/lsm.nim`, `wal.nim`, `recovery.nim` | Bound key/val ≤ 64 MB; validate kind преди enum cast |
| M1 | 🟡 MEDIUM | **MVCC `write` delete-during-iteration** | `core/mvcc.nim` | Collect-then-delete stale txn ids |
| M3 | 🟡 MEDIUM | **`checkpoint` lock leak** | `storage/lsm.nim` | try/finally около write lock + walLock |
| M4 | 🟡 MEDIUM | **`flushUnsafe` clear-before-write** | `storage/lsm.nim` | Clear memtable едва след успешен `writeSSTable` |
| M5 | 🟡 MEDIUM | **Compaction empty-key skip** | `storage/compaction.nim` | `haveLast` флаг вместо `lastKey = ""` sentinel |
| M6 | 🟡 MEDIUM | **`rewriteLive` remove-before-move** | `storage/wal.nim` | Само атомен `moveFile` (rename replace) |
| L3 | 🟢 LOW | **mmap `offset+size` overflow** | `storage/mmap.nim` | Overflow-safe: `offset > size - length` |
| — | hygiene | **Stray ELF `protocol/scram`** | `.gitignore` | Премахнат binary + ignore entry |

**Верификация (батч 2):** `baradadb` build чист; `tests/bugfix_test.nim` (вкл. batch-2 suite) и `tests/test_all.nim` (501 OK) минават без `[FAILED]`. `tests/prop_test.nim` B-Tree suite OK (H10 *не* е в този батч — naive left-max fix чупи interleaved remove).

---

## Остават (12)

### 🟠 HIGH (2)

| # | Проблем | Файл | Предложен fix |
|---|---------|------|---------------|
| H2 | **TLS client връзките между възли не верифицират сертификата** — `forwardQueryToLeader` ползва `verifyMode = CVerifyNone` → MITM на клъстър линка. Raft client dials са със същия default (`raftTlsVerifyPeer: false`). | `core/server.nim:70` | Verify peer cert срещу CA при client handshake (fail-closed при enabled TLS) |
| H10 | **B-tree `remove` separator convention** — audit: `splitChild` left-max vs `removeRec` right-min. Naive left-max rewrite of separators/borrows **fails** `prop_test` interleaved insert/remove; needs careful multi-level fix + more targeted repro first. | `storage/btree.nim:377` | Repro + full-tree separator invariant; keep borrow/merge/search consistent |

### 🟡 MEDIUM (7)

| # | Проблем | Файл | Предложен fix |
|---|---------|------|---------------|
| M2 | **disttxn `connectWithTimeout` без SO_ERROR + uncaught RPC** — refused connect е "writable" → връща true; `sendDistTxnRpc` няма try/except → OSError wedge-ва 2PC състояние. (BUG-042 fix-нат в replication, не тук.) | `core/disttxn.nim:88` | `getsockopt(SO_ERROR)` + try/except около per-participant RPC |
| M7 | **Compaction unlink-ва input-ите преди output-ът да е loadable в каталога** — verifySSTable вече е преди unlink; остава catalog re-load ordering в caller. | `storage/compaction.nim` / LSM apply | Load/verify output в каталога ПРЕДИ unlink на input-ите |
| M8 | **`OFFSET n` без `LIMIT` връща 0 реда; negative `LIMIT` чупи** — `limitCount = 0` е sentinel и за "няма limit", и за "LIMIT 0"; `sourceRows[start..<endIdx]` с endIdx<start → IndexDefect. | `query/exec/lower.nim:411`, `plan_exec.nim:219` | Отделен sentinel (-1 = unlimited); clamp negative |
| M9 | **Aggregate window функции връщат NULL** — `SUM/AVG/COUNT/MIN/MAX OVER (...)` попадат в `else` клона (`"\N"`); само ranking/lead/lag се handle-ват. | `query/exec/window.nim` | `of "sum","avg","count","min","max"` с `resolveFrameBounds` |
| M10 | **WebSocket приема unmasked client frames** — RFC 6455 §5.1 изисква server да затвори връзката при unmasked client frame (cache-poisoning защита). | `core/websocket.nim:85` | Затвори връзката при `masked == false` |
| M11 | **WebSocket без frame/message size limit → DoS** — `buf.add(chunk)` расте неограничено; няма 125-byte control-frame cap. | `core/websocket.nim:215` | Max frame/message size + control-frame cap |
| M12 | **WebSocket SUBSCRIBE bypass-ва table-level auth** — всеки автентикиран клиент subscribe-ва към произволна таблица и получава всички insert/delete. | `core/websocket.nim:232` | Table read authorization при subscribe |

### 🟢 LOW (3)

| # | Проблем | Файл | Предложен fix |
|---|---------|------|---------------|
| L1 | **SCRAM timing user enumeration** — unknown user връща веднага, known user прави urandom+HMAC/PBKDF2 работа → timing delta (BUG-049 fix-на съобщението, не timing-а). | `protocol/auth.nim:227` | Equivalent dummy work за unknown users |
| L2 | **SCRAM channel-binding не се верифицира** — `c=` се приема verbatim; RFC 5802 изисква валидация. Не е exploitable днес (няма TLS-CB). | `protocol/auth.nim:259` | Enforce expected `c=` (напр. `biws`) |
| L4 | **NULL equality semantics** — `NULL = NULL` и `col = NULL` → true (string sentinel сравнение), не unknown/false. Системно за string-based value модела. | `query/exec/eval.nim:431` | Three-valued logic за NULL (по-голям рефакторинг) |

---

## Проверени и чисти (не са бъгове)

- JWT `exp`/alg-confusion: pinned `jwt-nim-baraba#fbe084b` `verify()` enforce-ва alg-match, reject-ва `NONE`, проверява `exp/nbf/iat`, constant-time compare.
- `auth.nim` `constantTimeCompare` и SCRAM `verifyClientProof` са constant-time; празен JWT secret fail-closed (`server.nim:59`).
- `wire.nim` deserialize bounds/depth caps са sound.
- CRC byte ranges / `headerSize = 40` са консистентни между write/verify/load (format *коментарът* още казва "36" — само коментар).
- Lock ordering (`walLock` в `db.lock`; gate преди `db.lock`), mmap negative offset / `close()` recursion / fd handling (BUG-036/046) — непокътнати.
- `COUNT(col)` изключва NULLs (`v.kind != vkNull`); `LIMIT 0` → празно е коректно; IN-list се lower-ва към OR/AND вериги.

---

*Виж също: `PLAN.md` (Сесия 13), `docs/en/known-limitations.md`.*
