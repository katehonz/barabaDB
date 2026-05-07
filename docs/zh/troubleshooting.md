# 故障排除指南

## 安装问题

### 未找到 Nim

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

### SSL 编译错误

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### 缺少依赖

```bash
nimble install -d -y
```

## 运行时问题

### 端口已被占用

```bash
BARADB_PORT=5433 ./build/baradadb
lsof -ti:9472 | xargs kill -9
```

### 权限被拒绝

```bash
mkdir -p ./data
chmod 755 ./data
```

### 内存不足

```bash
BARADB_MEMTABLE_SIZE_MB=32 \
BARADB_CACHE_SIZE_MB=128 \
BARADB_VECTOR_EF_CONSTRUCTION=100 \
./build/baradadb
```

### 磁盘已满

```bash
curl -X POST http://localhost:9470/api/admin/compact
./build/baradadb --compact
```

## 查询问题

### 语法错误

```sql
SELECT name, age FROM users WHERE age > 18;
```

### 表未找到

```sql
CREATE TYPE User { name: str, age: int32 };
```

### 类型不匹配

```sql
SELECT * FROM users WHERE age > 18;
```

## 连接问题

### 连接被拒绝

```bash
./build/baradadb
sudo ufw allow 9472
```

### 认证失败

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="correct-secret" \
./build/baradadb
```

## 性能问题

### 查询慢

1. 创建索引：`CREATE INDEX idx_users_name ON users(name);`
2. 使用 LIMIT
3. 增加缓存：`BARADB_CACHE_SIZE_MB=1024`

### 高 CPU 使用率

```bash
BARADB_COMPACTION_INTERVAL_MS=300000 ./build/baradadb
```

### 高内存使用

```bash
BARADB_MEMTABLE_SIZE_MB=64
BARADB_CACHE_SIZE_MB=256
BARADB_VECTOR_M=8
```

## 调试模式

```bash
BARADB_LOG_LEVEL=debug ./build/baradadb
```