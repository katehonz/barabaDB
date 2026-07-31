# Разпределена Система

BaraDB поддържа разпределено внедряване с Raft консенсус, шардиране, репликация и gossip протокол.

> ⚠️ **Ограничение при множество бази данни**
> Разпределените модули (Raft, шардиране и репликация) в момента работят само с **`default`** базата данни. Ако използвате множество бази (`CREATE DATABASE`, `USE DATABASE`), разпределените функции още не ги обхващат. Всяка база данни се нуждае от отделна кластър конфигурация.

> **Статус (2026-07-30, v1.3.0):** Raft е **supported** за обхвата single-`default`-DB: failover под товар, raft TLS и cold-node recovery чрез InstallSnapshot са e2e-доказани. Преглед: `docs/superpowers/specs/2026-07-30-raft-cluster-status.md`.

## Raft Консенсус

Leader election и log репликация през TCP; SQL DML/DDL за **default** минават през raft log. Включване:

| Env | Значение |
|-----|----------|
| `BARADB_RAFT_ENABLED=true` | Включва Raft |
| `BARADB_RAFT_NODE_ID` | Id на този възел |
| `BARADB_RAFT_PORT` | Raft TCP порт |
| `BARADB_RAFT_PEERS` | Списък `id@host:port` (вкл. себе си) |
| `BARADB_RAFT_WRITE_TIMEOUT_MS` | Макс. изчакване за majority commit при SQL записи (по подразбиране 5000) |
| `BARADB_RAFT_CLIENT_PEERS` | Опционален `id@host:clientPort` map за leader write forwarding |
| `BARADB_RAFT_LOG_MAX_ENTRIES` | Лимит на in-memory raft log (по подразбиране 256); safe prefix compact |
| `BARADB_RAFT_SNAP_CHUNK_KB` | Размер на InstallSnapshot chunk в KiB (по подразбиране 256) |
| `BARADB_RAFT_PEER_STALE_MS` | Peer е „stale“ след толкова ms без ack (по подразбиране 30000); stale peers не блокират compaction |
| `BARADB_RAFT_TLS_ENABLED` | TLS на raft порта (по подразбиране false; стартът спира при липсващ cert/key) |
| `BARADB_RAFT_TLS_CERT_FILE` / `BARADB_RAFT_TLS_KEY_FILE` | Сертификат и ключ за raft listener-а |
| `BARADB_RAFT_TLS_CA_FILE` / `BARADB_RAFT_TLS_VERIFY_PEER` | Опционален CA bundle и mutual auth (по подразбиране false) |

Когато Raft е активен, SQL DML и schema DDL се приемат само от лидера на **`default`**. DML отива като put/delete; DDL — като `ddl` запис. Followers **препращат** write/DDL към лидера, ако е зададен `BARADB_RAFT_CLIENT_PEERS`; иначе връщат `not leader; leader is '…'`. Записи към друга database name се отказват. `CREATE`/`DROP DATABASE` не се репликират. Приложен DML обновява и secondary индекси/графи.

**Log compaction:** след apply node-ът може да изреже safe prefix, когато log-ът надхвърли `BARADB_RAFT_LOG_MAX_ENTRIES`. На лидера safe prefix се смята само по peers с ack в рамките на `BARADB_RAFT_PEER_STALE_MS`; stale peers се възстановяват със snapshot при завръщане. Snapshot metadata се пази в `raft_state.bin`.

**Snapshot recovery (InstallSnapshot, v1.3.0):** когато изоставането на follower е невъзстановимо, лидерът изпраща `tar.gz` snapshot на default DB на chunk-ове от `BARADB_RAFT_SNAP_CHUNK_KB` KiB. Follower-ът го възстановява през backup/restore пътя и продължава catch-up. Върнат след дълъг прекъсване или **изтрит** (wiped data dir, същото node id) възел конвергира автоматично. E2E: `tests/raft_coldnode_e2e_test.nim`.

**Клиентски договор при failover:** запис, който е in-flight при смяна на лидера, **гърми бързо с грешка** — клиентът трябва да го повтори (retry). Всеки **потвърден** (acknowledged) запис оцелява failover-а и е наличен на новия лидер и на наваксалите followers. E2E: `tests/raft_failover_load_e2e_test.nim`.

**Raft TLS (v1.3.0):** `BARADB_RAFT_TLS_ENABLED=true` + cert/key на всеки възел; стартът спира при липсващ cert/key. Целият клъстер трябва да е в един и същ режим — plaintext възел не може да говори с TLS порт и е изключен от клъстера (`tests/raft_tls_e2e_test.nim`). Forwarding-ът follower→leader се обвива в TLS, когато клиентският wire порт е с TLS.

**Metrics:** при включен raft `GET /metrics` (HTTP = `BARADB_PORT + 440`) дава Prometheus редове: `baradb_raft_is_leader`, `baradb_raft_term`, `baradb_raft_log_entries`, `baradb_raft_apply_lag`, `baradb_raft_commit_wait_ms_total`, `baradb_raft_elections_total`, `baradb_raft_forwards_total`, `baradb_raft_compactions_total`. `GET /health` включва обект `raft` (`role`, `term`, `leader_id`, …).

```nim
import barabadb/core/raft

var cluster = newRaftCluster()
cluster.addNode("node1")
cluster.addNode("node2")
cluster.addNode("node3")

let n1 = cluster.nodes["n1"]
n1.becomeCandidate()
n1.becomeLeader()
let entry = n1.appendLog("SET key1 value1")
```

## Шардиране

Разпределение на данни между възли:

```nim
import barabadb/core/sharding

var router = newShardRouter(ShardConfig(
  numShards: 4,
  replicas: 2,
  strategy: ssHash
))
router.rebalance(@["node1", "node2", "node3"])
let shard = router.getShard("user_123")
```

### Стратегии за Шардиране

| Стратегия | Описание |
|-----------|----------|
| `ssHash` | Хеш-базирано шардиране |
| `ssRange` | Range-базирано шардиране |
| `ssConsistent` | Consistent hashing |

## Репликация

```nim
import barabadb/core/replication

var rm = newReplicationManager(rmSync)
rm.addReplica(newReplica("r1", "10.0.0.1", 9472))
rm.connectReplica("r1")
let lsn = rm.writeLsn(@[1'u8, 2, 3])
rm.ackLsn("r1", lsn)
```

### Режими на Репликация

| Режим | Описание |
|--------|----------|
| `rmSync` | Синхронна репликация |
| `rmAsync` | Асинхронна репликация |
| `rmSemiSync` | Полу-синхронна репликация |

## Gossip Протокол

Управление на членство и детекция на откази:

```nim
import barabadb/core/gossip

var g = newGossipProtocol("node1", "localhost", 9472, gossipPort = 9572)
g.join(newGossipNode("node2", "10.0.0.2", 9472))
```

## Разпределени Транзакции

Two-phase commit между възли:

```nim
import barabadb/core/disttxn

var tm = newDistTxnManager()
let txn = tm.beginTransaction("node1")
txn.addParticipant("node2", "10.0.0.2", 9472)
txn.prepare()
txn.commit()
```

## Формална Верификация

Основните разпределени алгоритми са формално специфицирани в TLA+ и проверени с TLC:

- **Raft Консенсус** — `formal-verification/raft.tla`
  - Проверено: ElectionSafety, StateMachineSafety
- **Two-Phase Commit** — `formal-verification/twopc.tla`
  - Проверено: Atomicity, NoOrphanBlocks
- **Репликация** — `formal-verification/replication.tla`
  - Проверено: MonotonicLsn, AcksRemovePending

Пускане на TLC локално:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/raft.cfg raft.tla
java -cp tla2tools.jar tlc2.TLC -config models/twopc.cfg twopc.tla
java -cp tla2tools.jar tlc2.TLC -config models/replication.cfg replication.tla
```
