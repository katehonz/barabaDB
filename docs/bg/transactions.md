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