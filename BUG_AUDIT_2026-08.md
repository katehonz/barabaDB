# BaraDB — Deep Audit (август 2026)

> Дата: 2026-08-02
> Метод: 4 паралелни одит-агента по слоеве (Storage / Query / Core / Protocol), всеки чете всички файлове в обхвата си и проверява находките срещу реалния код.
> Обхват: **само нови дефекти** — 80-те вече оправени в `BUGS.md` / `BUG_AUDIT.md` / `BARADB_CLIENT_BUGS.md` са изключени.
> **Общо: ~28 находки | Поправени (батч 1): 5 | Остават: 23**

---

## Поправени — батч 1 (5)

| # | Severity | Проблем | Файл | Fix |
|---|----------|---------|------|-----|
| C1 | 🔴 CRITICAL | **MIGRATE handler без auth gate** — неавтентикиран клиент пишеше произволни key/value в базата (`handleMigrationMessage → applyMigrationBatch → storeKeys → db.put`). Открито независимо от 2 агента. | `core/server.nim:682` | Добавен `if not authenticated: ... continue` (като REP/DISTTXN блоковете) |
| C2 | 🔴 CRITICAL | **Raft commit quorum off-by-one за even-N** — `(N+1) div 2` commit-ваше с малцинство при четен брой възли (N=4 → 2/4). Election-ът ползваше коректното strict majority. *GA обхватът е 3-node (нечетно), където формулите съвпадат.* | `core/raft.nim:653` | `let majority = (node.peers.len + 1) div 2 + 1` (съвпада с election); регресионен тест за 4-node |
| H1 | 🟠 HIGH | **Pre-auth memory-exhaustion DoS** — `parseHeader` не ограничаваше `length` (uint32 до ~4 GiB); `recvExactWithTimeout` пре-алокира преди auth check. | `core/server.nim:168` | Reject `length > uint32(MaxWireStringLen)` (64 MB) преди алокация |
| H4 | 🟠 HIGH | **`**` и `++` се lower-ваха към equality** — `bkPow`/`bkConcat` липсваха в op-mapping case-а и попадаха в `else: irEq` (`2 ** 3` → `false`, `'a' ++ 'b'` → `false`). | `query/exec/lower.nim:79` | `of bkPow: irOp = irPow`, `of bkConcat: irOp = irAdd`; 2 регресионни теста |
| H5 | 🟠 HIGH | **`!=` не е отрицание на `=`** — `irNeq` short-circuit-ваше на string inequality, така че `5 != 5.0` → true, но `5 = 5.0` → true. | `query/exec/eval.nim:438` | `irNeq` numeric-first (точно допълнение на `irEq`); регресионен тест |

**Верификация:** `baradadb` build чист; `tests/test_all.nim` (пълен suite) и `tests/bugfix_test.nim` минават без `[FAILED]`.

---

## Остават (23)

### 🟠 HIGH (8)

| # | Проблем | Файл | Предложен fix |
|---|---------|------|---------------|
| H2 | **TLS client връзките между възли не верифицират сертификата** — `forwardQueryToLeader` ползва `verifyMode = CVerifyNone` → MITM на клъстър линка. Raft client dials са със същия default (`raftTlsVerifyPeer: false`). | `core/server.nim:70` | Verify peer cert срещу CA при client handshake (fail-closed при enabled TLS) |
| H3 | **Semi-sync репликация връща durable LSN при partial/zero ack** — `rmSync` връща 0 при partial ack, но `rmSemiSync` връща LSN безусловно (само debug echo при 0 acks). | `core/replication.nim:217` | `if syncReplicaCount > 0 and ackCount < syncReplicaCount: return 0` |
| H6 | **`COUNT/SUM/AVG(DISTINCT)` игнорира DISTINCT** — `funcDistinct` се set-ва в парсера (BUG-017), но `aggDistinct` никога не се копира/чете; няма dedup в aggregate пътищата. | `query/exec/lower.nim:116`, `plan_exec.nim` | Копирай `aggDistinct = node.funcDistinct`; dedup чрез `HashSet[string]` преди count/sum/avg |
| H7 | **`UNION/INTERSECT/EXCEPT` (без ALL) чупят с KeyError** — dedup ключът чете `row["$value"]`, но projected редове нямат този ключ. Само `UNION ALL` работи. | `query/executor.nim:459` | Dedup ключ от projected колоните (join `valueToString` по ред на `cols`), не `row["$value"]` |
| H8 | **`MERGE ... WHEN MATCHED THEN DELETE` / `AND <cond>` не се изпълняват** — AST/parser полетата (BUG-032) съществуват, но executor-ът не ги реферира; DELETE е no-op, condition се игнорира. | `query/executor.nim:752` | В matched клона: провери `mergeMatchedCondition`, после honor-вай `mergeMatchedDelete` |
| H9 | **WAL recovery чупи процеса при torn record** — recovery parser-ът вярва на `keyLen`/`valLen` (до ~4 GiB alloc) и `kind` (out-of-range enum → `CaseStmtError` Defect, не се catch-ва). | `storage/lsm.nim:704` | Bound lengths + валидирай `kind` преди use; дългосрочно per-record CRC32 |
| H10 | **B-tree `remove` пише separator с грешна конвенция** — `splitChild` ползва left child max, `removeRec` пише right child min (`child.keys[0]`) → ключове стават ненамираеми при internal nodes (silent data loss). | `storage/btree.nim:377` | Separator = max ключ на left child, преизчислен след rebalance |

### 🟡 MEDIUM (11)

| # | Проблем | Файл | Предложен fix |
|---|---------|------|---------------|
| M1 | **MVCC `write` трие от `activeTxns` по време на итерация** — `delete` proc-ът ползва collect-then-delete, но `write` трие inline (unsafe, пропуска timed-out txns). | `core/mvcc.nim:180` | Collect stale ids в seq, трий след loop-а |
| M2 | **disttxn `connectWithTimeout` без SO_ERROR + uncaught RPC** — refused connect е "writable" → връща true; `sendDistTxnRpc` няма try/except → OSError wedge-ва 2PC състояние. (BUG-042 fix-нат в replication, не тук.) | `core/disttxn.nim:88` | `getsockopt(SO_ERROR)` + try/except около per-participant RPC |
| M3 | **`checkpoint` leaking write lock при exception** — `acquireWrite` без try/finally; IOError от flush/rotate пропуска `releaseWrite` → постоянен hang. | `storage/lsm.nim:932` | try/finally около lock-а (и walLock) |
| M4 | **`flushUnsafe` празни memtable преди SSTable write** — при IOError на `writeSSTable` данните са загубени от memory (остават само в WAL, невидими за live reads). | `storage/lsm.nim:870` | Първо `writeSSTable`, после clear на memtable |
| M5 | **Compaction пропуска empty-string ключа** — dedup sentinel `lastKey = ""` skip-ва ключ `""` → data loss при compact на празен ключ. | `storage/compaction.nim:130` | `haveLast` флаг вместо sentinel стойност |
| M6 | **`rewriteLive` data-loss window** — `removeFile(wal.path)` преди `moveFile`; crash между тях губи unflushed записи. `rename(2)` и без това е атомен replace. | `storage/wal.nim:329` | Махни `removeFile`, остави атомния `moveFile` |
| M7 | **Compaction unlink-ва input-ите преди output-ът да е loadable в каталога** — `applyCompactionResult` re-load-ва output в try/except (само warning); ако fail-не след unlink → загуба на ключове. | `storage/compaction.nim:150` | Load/verify output в каталога ПРЕДИ unlink на input-ите |
| M8 | **`OFFSET n` без `LIMIT` връща 0 реда; negative `LIMIT` чупи** — `limitCount = 0` е sentinel и за "няма limit", и за "LIMIT 0"; `sourceRows[start..<endIdx]` с endIdx<start → IndexDefect. | `query/exec/lower.nim:411`, `plan_exec.nim:219` | Отделен sentinel (-1 = unlimited); clamp negative |
| M9 | **Aggregate window функции връщат NULL** — `SUM/AVG/COUNT/MIN/MAX OVER (...)` попадат в `else` клона (`"\N"`); само ranking/lead/lag се handle-ват. | `query/exec/window.nim` | `of "sum","avg","count","min","max"` с `resolveFrameBounds` |
| M10 | **WebSocket приема unmasked client frames** — RFC 6455 §5.1 изисква server да затвори връзката при unmasked client frame (cache-poisoning защита). | `core/websocket.nim:85` | Затвори връзката при `masked == false` |
| M11 | **WebSocket без frame/message size limit → DoS** — `buf.add(chunk)` расте неограничено; няма 125-byte control-frame cap. | `core/websocket.nim:215` | Max frame/message size + control-frame cap |
| M12 | **WebSocket SUBSCRIBE bypass-ва table-level auth** — всеки автентикиран клиент subscribe-ва към任意 таблица и получава всички insert/delete. | `core/websocket.nim:232` | Table read authorization при subscribe |

### 🟢 LOW (4)

| # | Проблем | Файл | Предложен fix |
|---|---------|------|---------------|
| L1 | **SCRAM timing user enumeration** — unknown user връща веднага, known user прави urandom+HMAC/PBKDF2 работа → timing delta (BUG-049 fix-на съобщението, не timing-а). | `protocol/auth.nim:227` | Equivalent dummy work за unknown users |
| L2 | **SCRAM channel-binding не се верифицира** — `c=` се приема verbatim; RFC 5802 изисква валидация. Не е exploitable днес (няма TLS-CB). | `protocol/auth.nim:259` | Enforce expected `c=` (напр. `biws`) |
| L3 | **mmap read `offset + size` overflow** — `offset + size > region.size` с native int wrap-ва негативно при corrupt offset/size → OOB read. v3 SSTable-ите са CRC-защитени (reachable само през legacy v1/v2). | `storage/mmap.nim` | `offset > region.size - size` (без overflow) |
| L4 | **NULL equality semantics** — `NULL = NULL` и `col = NULL` → true (string sentinel сравнение), не unknown/false. Системно за string-based value модела. | `query/exec/eval.nim:431` | Three-valued logic за NULL (по-голям рефакторинг) |

### Хигиена

- **Stray 94 KB компилиран ELF binary** в `src/barabadb/protocol/scram` — случайно commit-нат в source tree-то; да се премахне (+ `.gitignore`).

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
