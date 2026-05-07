# المعاملات و MVCC

MVCC (تحكم التزامن متعدد الإصدارات) مع عزل اللقطة واكتشاف الجمود.

## الاستخدام

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)

discard tm.commit(txn)
```

## عزل المعاملات

تستخدم BaraDB **عزل اللقطة**:
- القراء لا يحظرون الكتاب
- الكتاب لا يحظرون القراء
- كل معاملة ترى لقطة متسقة

## اكتشاف الجمود

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "تم اكتشاف الجمود!"
```

## التحقق الرسمي

تم تحديد بروتوكول MVCC/Snapshot Isolation رسمياً في TLA+:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```