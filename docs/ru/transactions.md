# Транзакции и MVCC

MVCC (Multi-Version Concurrency Control) с изоляцией снэпшотов и обнаружением дедлоков.

## Использование

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

# Операции записи
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# Savepoint
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)  # отмена key3

# Commit
discard tm.commit(txn)
```

## Изоляция транзакций

BaraDB использует **изоляцию снэпшотов**:
- Читатели не блокируют писателей
- Писатели не блокируют читателей
- Каждая транзакция видит согласованный снэпшот

## Обнаружение дедлоков

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "Дедлок обнаружен!"
```

## Write-Ahead Log

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append(txnId, "SET key value")
wal.flush()
```

## Savepoints

Вложенные savepoints транзакций:

```nim
tm.savepoint(txn, "sp1")
# ... операции ...
tm.rollbackToSavepoint(txn, "sp1")
```

## Формальная верификация

Протокол MVCC / Snapshot Isolation формально специфицирован в TLA+:

- **Спецификация:** `formal-verification/mvcc.tla`
- **Проверенные свойства:**
  - `NoDirtyReads` — транзакции никогда не читают незафиксированные данные
  - `ReadOwnWrites` — транзакции всегда видят свои собственные записи
  - `WriteWriteConflict` — первый фиксирующий выигрывает

Запустить TLC локально:

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```