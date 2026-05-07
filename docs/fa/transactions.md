# تراکنش‌ها و MVCC

MVCC (کنترل همزمانی چندنسخه‌ای) با جداسازی snapshot و تشخیص بن‌بست.

## استفاده

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

# عملیات نوشتن
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# Savepoint
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)

# Commit
discard tm.commit(txn)
```

## جداسازی تراکنش

BaraDB از **جداسازی snapshot** استفاده می‌کند:
- خوانندگان نویسندگان را مسدود نمی‌کنند
- نویسندگان خوانندگان را مسدود نمی‌کنند
- هر تراکنش یک snapshot سازگار می‌بیند

## تشخیص بن‌بست

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "بن‌بست تشخیص داده شد!"
```

## WAL

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append(txnId, "SET key value")
wal.flush()
```

## Savepoints

```nim
tm.savepoint(txn, "sp1")
tm.rollbackToSavepoint(txn, "sp1")
```

## تأیید رسمی

پروتکل MVCC در TLA+ مشخص شده:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```