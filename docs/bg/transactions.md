# Транзакции и MVCC

MVCC (Multi-Version Concurrency Control) със snapshot изолация и deadlock детекция.

## Употреба

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

# Операции за запис
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# Savepoint
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)  # отмяна на key3

# Commit
discard tm.commit(txn)
```

## Изолация на Транзакции

BaraDB използва **snapshot изолация**:
- Четящите не блокират пишещите
- Пишещите не блокират четящите
- Всяка транзакция вижда консистентен snapshot

## Deadlock Детекция

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "Открит deadlock!"
```

## Write-Ahead Log

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append(txnId, "SET key value")
wal.flush()
```

## Savepoints

Вложени savepoints на транзакции:

```nim
tm.savepoint(txn, "sp1")
# ... операции ...
tm.rollbackToSavepoint(txn, "sp1")
```

## Формална Верификация

MVCC / Snapshot Isolation протоколът е формално специфициран в TLA+:

- **Спецификация:** `formal-verification/mvcc.tla`
- **Проверени свойства:**
  - `NoDirtyReads` — транзакциите никога не четат некомитнати данни
  - `ReadOwnWrites` — транзакциите винаги виждат собствените си записи
  - `WriteWriteConflict` — first-committer-wins (няма две комитнати транзакции да пишат един и същ ключ)

Пускане на TLC локално:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```
