# Ръководство за Отстраняване на Проблеми

## Проблеми с Инсталацията

### Nim не е намерен

```
nim: command not found
```

**Решение:**

```bash
# Linux/macOS
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Добавяне към PATH
echo 'export PATH=$HOME/.nimble/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### SSL Грешка при Компилация

```
Error: BaraDB requires SSL support. Compile with -d:ssl
```

**Решение:** Винаги компилирайте с `-d:ssl`:

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### Липсващи Зависимости

```
Error: cannot open file: hunos
```

**Решение:**

```bash
nimble install -d -y
```

## Проблеми по Време на Изпълнение

### Портът е Зает

```
Error: unhandled exception: Address already in use [OSError]
```

**Решение 1:** Сменете порта:

```bash
BARADB_PORT=5433 ./build/baradadb
```

**Решение 2:** Убийте съществуващия процес:

```bash
lsof -ti:9472 | xargs kill -9
```

### Permission Denied на Директория с Данни

```
Error: Permission denied: ./data
```

**Решение:**

```bash
mkdir -p ./data
chmod 755 ./data
# или използвайте друга директория
BARADB_DATA_DIR=/tmp/baradb ./build/baradadb
```

## Storage Проблеми

### Бавни Заявки

1. Проверете cache hit rate:
```bash
curl http://localhost:9470/metrics | grep cache_hit_rate
```

2. Пуснете ръчен compaction:
```bash
curl -X POST http://localhost:9470/admin/compact
```

3. Проверете броя на SSTables:
```bash
curl http://localhost:9470/metrics | grep sstables
```

### Растящо Дисково Пространство

```bash
# Проверете размера на директорията с данни
du -sh ./data

# Проверете WAL размера
du -sh ./data/server/wal

# Пуснете ръчен compaction за освобождаване на място
curl -X POST http://localhost:9470/admin/compact
```

## Проблеми с Автентикация

### Грешка при Верификация на JWT

```json
{"error": {"code": "AUTH_REQUIRED", "message": "Authentication required"}}
```

**Решение:** Уверете се, че изпращате правилния токен:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:9470/api/query \
  -d '{"query": "SELECT 1"}'
```

## Разпределени Проблеми

### Възел не се Присъединява към Клъстер

1. Проверете мрежовата свързаност между възлите
2. Проверете gossip порта (raft порт + 100)
3. Проверете логовете за грешки при gossip

### Репликационно Закъснение

```bash
# Проверете replication lag
curl http://localhost:9470/metrics/cluster | jq .replication_lag_ms
```

## Често Задавани Въпроси

### Как да нулирам напълно базата данни?

```bash
# Спрете сървъра
# Изтрийте директорията с данни
rm -rf ./data
# Стартирайте отново — нова празна база ще бъде създадена
./build/baradadb
```

### Как да мигрирам от друга база данни?

BaraDB поддържа импорт чрез JSON и CSV:

```bash
curl -X POST http://localhost:9470/api/import \
  -H "Content-Type: application/json" \
  -d '{"table": "users", "format": "json", "data": [...]}'
```
