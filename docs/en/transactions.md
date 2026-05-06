# Transactions & MVCC

MVCC (Multi-Version Concurrency Control) with snapshot isolation and deadlock detection.

## Usage

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

# Write operations
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# Savepoint
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)  # undo key3

# Commit
discard tm.commit(txn)
```

## Transaction Isolation

BaraDB uses **snapshot isolation**:
- Readers don't block writers
- Writers don't block readers
- Each transaction sees a consistent snapshot

## Deadlock Detection

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "Deadlock detected!"
```

## Write-Ahead Log

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append(txnId, "SET key value")
wal.flush()
```

## Savepoints

Nested transaction savepoints:

```nim
tm.savepoint(txn, "sp1")
# ... operations ...
tm.rollbackToSavepoint(txn, "sp1")
```