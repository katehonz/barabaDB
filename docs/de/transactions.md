# Transaktionen & MVCC

MVCC (Multi-Version Concurrency Control) mit Snapshot-Isolation und Deadlock-Erkennung.

## Verwendung

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

# Schreiboperationen
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# Savepoint
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)  # rückgängig machen key3

# Commit
discard tm.commit(txn)
```

## Transaktionsisolation

BaraDB verwendet **Snapshot-Isolation**:
- Leser blockieren keine Schreiber
- Schreiber blockieren keine Leser
- Jede Transaktion sieht einen konsistenten Snapshot

## Deadlock-Erkennung

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "Deadlock erkannt!"
```

## Write-Ahead Log

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append(txnId, "SET key value")
wal.flush()
```

## Savepoints

Verschachtelte Transaktions-Savepoints:

```nim
tm.savepoint(txn, "sp1")
# ... Operationen ...
tm.rollbackToSavepoint(txn, "sp1")
```

## Formale Verifikation

Das MVCC / Snapshot-Isolation Protokoll ist formal in TLA+ spezifiziert:

- **Spec:** `formal-verification/mvcc.tla`
- **Verifizierte Eigenschaften:**
  - `NoDirtyReads` — Transaktionen lesen niemals nicht-committete Daten
  - `ReadOwnWrites` — Transaktionen sehen immer ihre eigenen Schreiboperationen
  - `WriteWriteConflict` — First-committer-wins (keine zwei committete Transaktionen schreiben denselben Schlüssel)

Lokale TLC-Ausführung:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```
