# Docker Deployment Ръководство

Това ръководство описва как да използвате BaraDB с Docker и Docker Compose.

## Бърз старт

```bash
# Клониране на репото
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB

# Build на образа
docker build -t baradb:latest .

# Стартиране с Docker Compose
docker compose up -d

# Проверка на статуса
docker compose ps
docker compose logs -f
```

## Файлове

| Файл | Описание |
|------|----------|
| `Dockerfile` | Мулти-stage production build |
| `docker-compose.yml` | Development конфигурация |
| `docker-compose.prod.yml` | Production конфигурация |
| `docker-compose.override.yml` | Development override (автоматично се зарежда) |
| `docker-compose.test.yml` | Тестова конфигурация |
| `docker-entrypoint.sh` | Entrypoint скрипт за инициализация |
| `.dockerignore` | Файлове, които да не се копират в образа |

## Създаване на образ

```bash
# Стандартен build
docker build -t baradb:latest .

# С конкретна версия
docker build -t baradb:1.1.0 .
```

## Стартиране

### Development (docker compose)

```bash
# Стартиране на заден план
docker compose up -d

# Спиране
docker compose down

# Спиране и изтриване на volumes (ВНИМАНИЕ — изтрива данните!)
docker compose down -v

# Преглед на логове
docker compose logs -f
```

### Production (docker compose)

```bash
# Стартиране с production конфигурация
docker compose -f docker-compose.prod.yml up -d

# Проверка на healthcheck
docker compose -f docker-compose.prod.yml ps
```

### Ръчно (docker run)

```bash
docker run -d \
  --name baradb \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  -e BARADB_LOG_LEVEL=info \
  baradb:latest
```

## Портове

| Порт | Описание |
|------|----------|
| `9472` | Binary wire протокол |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## Променливи на Средата

| Променлива | Стойност по подразбиране | Описание |
|------------|--------------------------|----------|
| `BARADB_ADDRESS` | `0.0.0.0` | Адрес за слушане |
| `BARADB_PORT` | `9472` | Binary протокол порт |
| `BARADB_HTTP_PORT` | `9470` | HTTP порт |
| `BARADB_WS_PORT` | `9471` | WebSocket порт |
| `BARADB_DATA_DIR` | `/data` | Директория за данни |
| `BARADB_LOG_LEVEL` | `info` | Ниво на логове |

## Volumes

| Път в контейнера | Описание |
|------------------|----------|
| `/data` | Основна директория за базата данни |
| `/data/server/wal` | Write-ahead log |
| `/data/server/sstables` | SSTable файлове |

## Production Checklist

- [ ] Създайте TLS сертификати в `./certs/`
- [ ] Задайте силен `BARADB_JWT_SECRET`
- [ ] Настройте firewall правила
- [ ] Конфигурирайте регулярни backups
- [ ] Проверете resource limits
- [ ] Настройте мониторинг (healthcheck, logs)

## TLS в Docker

1. Създайте сертификати:
```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

2. Активирайте в `docker-compose.prod.yml`:
```yaml
environment:
  - BARADB_TLS_ENABLED=true
  - BARADB_CERT_FILE=/certs/server.crt
  - BARADB_KEY_FILE=/certs/server.key
volumes:
  - ./certs:/certs:ro
```

## Backup в Docker

```bash
# Ръчен backup
docker exec baradb baradadb --snapshot --output=/backup/snapshot.db

# Списък на backups
ls /backup/

# Възстановяване
docker exec baradb baradadb --recover --checkpoint=/backup/snapshot.db
```

## Troubleshooting

### Контейнерът не стартира

```bash
# Проверка на логове
docker compose logs -f baradb

# Проверка на статус
docker compose ps
```

### Няма връзка с базата

```bash
# Проверка дали портовете са експозвани
docker port baradb

# Проверка отвътре
docker exec baradb wget -qO- http://localhost:9470/health
```

### Permission denied на /data

Entrypoint скриптът автоматично създава директориите и задава правилните permissions. Ако имате проблем:

```bash
docker exec baradb ls -la /data
docker exec baradb chown -R baradb:baradb /data
```
