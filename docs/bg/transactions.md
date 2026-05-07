# Транзакции & MVCC

Multi-Version Concurrency Control със snapshot изолация.

## Употреба

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

tm.savepoint(txn)
discard tm.rollbackToSavepoint(txn)

discard tm.commit(txn)
```

## Изолация

BaraDB използва **snapshot isolation**:
- Читателите не блокират писатели
- Писателите не блокират читатели
- Всяка транзакция вижда консистентен моментна снимка

## Формална Верификация

MVCC / Snapshot Isolation протоколът е формално специфициран в TLA+:

- **Спецификация:** `formal-verification/mvcc.tla`
- **Проверени свойства:**
  - `NoDirtyReads` — транзакциите никога не четат неcommit-нати данни
  - `ReadOwnWrites` — транзакциите винаги виждат собствените си записи
  - `WriteWriteConflict` — first-committer-wins

Пускане на TLC:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```