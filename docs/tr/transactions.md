# İşlemler ve MVCC

MVCC (Multi-Version Concurrency Control), snapshot izolasyonu ve deadlock algılama ile.

## Kullanım

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

## İşlem İzolasyonu

BaraDB **snapshot izolasyonu** kullanır:
- Okuyucular yazıcıları engellemez
- Yazıcılar okuyucuları engellemez
- Her işlem tutarlı bir snapshot görür

## Deadlock Algılama

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "Deadlock algılandı!"
```

## Resmi Doğrulama

MVCC/Snapshot Isolation protokolü TLA+'da resmi olarak belirtilmiştir:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```