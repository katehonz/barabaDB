# Руководство по устранению проблем

## Проблемы с установкой

### Nim не найден

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
echo 'export PATH=$HOME/.nimble/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### Ошибка компиляции SSL

**Решение:** Всегда компилируйте с `-d:ssl`:

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### Отсутствуют зависимости

```bash
nimble install -d -y
```

## Проблемы с выполнением

### Порт уже используется

```bash
BARADB_PORT=5433 ./build/baradadb
# или
lsof -ti:9472 | xargs kill -9
```

### Permission denied

```bash
mkdir -p ./data
chmod 755 ./data
```

### Недостаточно памяти

```bash
BARADB_MEMTABLE_SIZE_MB=32 \
BARADB_CACHE_SIZE_MB=128 \
BARADB_VECTOR_EF_CONSTRUCTION=100 \
./build/baradadb
```

### Диск заполнен

```bash
curl -X POST http://localhost:9470/api/admin/compact
./build/baradadb --compact
```

## Проблемы с запросами

### Синтаксическая ошибка

```sql
-- Правильно
SELECT name, age FROM users WHERE age > 18;

-- Неправильно (пропущена запятая)
SELECT name age FROM users WHERE age > 18;
```

### Таблица не найдена

```sql
CREATE TYPE User {
  name: str,
  age: int32
};
```

### Несовпадение типов

```sql
-- Правильно
SELECT * FROM users WHERE age > 18;

-- Неправильно
SELECT * FROM users WHERE age > '18';
```

## Проблемы с соединением

### Connection refused

```bash
ps aux | grep baradadb
./build/baradadb
sudo ufw allow 9472
```

### Ошибка аутентификации

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="correct-secret" \
./build/baradadb
```

### SSL/TLS ошибки

```bash
BARADB_TLS_ENABLED=false ./build/baradadb
```

## Проблемы с производительностью

### Медленные запросы

```bash
curl -X POST http://localhost:9470/api/explain \
  -d '{"query": "SELECT * FROM large_table"}'
```

Решения:
1. Добавить индексы: `CREATE INDEX idx_users_name ON users(name);`
2. Использовать LIMIT: `SELECT * FROM users LIMIT 100;`
3. Увеличить кэш: `BARADB_CACHE_SIZE_MB=1024`

### Высокая загрузка CPU

```bash
BARADB_COMPACTION_INTERVAL_MS=300000 ./build/baradadb
```

### Высокое потребление памяти

```bash
BARADB_MEMTABLE_SIZE_MB=64
BARADB_CACHE_SIZE_MB=256
BARADB_VECTOR_M=8
```

## Проблемы кластера

### Raft split-brain

Убедитесь в нечётном количестве узлов (3, 5, 7).

### Отставание репликации

```bash
BARADB_REPLICATION_MODE=async
```

## Режим отладки

```bash
BARADB_LOG_LEVEL=debug \
BARADB_LOG_FILE=/tmp/baradb_debug.log \
./build/baradadb
```

## Получение помощи

1. Проверьте логи: `tail -f /var/log/baradb/baradb.log`
2. Проверьте метрики: `curl http://localhost:9470/metrics`
3. Запустите диагностику: `./build/baradadb --diagnose`
4. Откройте issue с версией BaraDB и логами