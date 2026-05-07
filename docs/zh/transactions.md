# 事务与 MVCC

MVCC（多版本并发控制），提供快照隔离和死锁检测。

## 使用

```nim
import barabadb/core/mvcc

var tm = newTxnManager()
let txn = tm.beginTxn()

# 写操作
discard tm.write(txn, "key1", cast[seq[byte]]("value1"))
discard tm.write(txn, "key2", cast[seq[byte]]("value2"))

# 保存点
tm.savepoint(txn)
discard tm.write(txn, "key3", cast[seq[byte]]("value3"))
discard tm.rollbackToSavepoint(txn)

# 提交
discard tm.commit(txn)
```

## 事务隔离

BaraDB 使用**快照隔离**：
- 读取者不阻塞写入者
- 写入者不阻塞读取者
- 每个事务看到一致的快照

## 死锁检测

```nim
import barabadb/core/deadlock

var detector = newDeadlockDetector()
if detector.detectCycle(txn1, txn2):
  echo "检测到死锁！"
```

## 预写日志

```nim
import barabadb/storage/wal

var wal = newWAL("./wal")
wal.append(txnId, "SET key value")
wal.flush()
```

## 保存点

嵌套事务保存点：

```nim
tm.savepoint(txn, "sp1")
tm.rollbackToSavepoint(txn, "sp1")
```

## 形式化验证

MVCC/快照隔离协议在 TLA+ 中形式化规范：

- **规范：** `formal-verification/mvcc.tla`
- **验证的属性：**
  - `NoDirtyReads` — 事务从不读取未提交的数据
  - `ReadOwnWrites` — 事务总是看到自己的写入
  - `WriteWriteConflict` — 先提交者胜出

本地运行 TLC：

```bash
cd formal-verification
java -cp tla2tools.jar tlc2.TLC -config models/mvcc.cfg mvcc.tla
```