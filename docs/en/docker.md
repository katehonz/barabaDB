# Docker Deployment Guide

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
| `docker-entrypoint.sh` | Entrypoint скрипт за инициализация |
| `.dockerignore` | Файлове, които да не се копират в образа |
| `scripts/docker-build.sh` | Helper скрипт за build |
| `scripts/docker-run.sh` | Helper скрипт за ръчно стартиране |

## Създаване на образ

```bash
# Стандартен build
docker build -t baradb:latest .

# Със скрипта
./scripts/docker-build.sh

# С конкретна версия
IMAGE_NAME=baradb VERSION=0.1.0 ./scripts/docker-build.sh
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
# Със скрипта
./scripts/docker-run.sh

# Ръчно
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
| `9472` | Binary wire protocol |
| `9912` | HTTP/REST API (TCP port + 440) |
| `9913` | WebSocket (TCP port + 441) |

## Environment Variables

| Променлива | Стойност по подразбиране | Описание |
|------------|--------------------------|----------|
| `BARADB_ADDRESS` | `0.0.0.0` | Адрес за слушане |
| `BARADB_PORT` | `9472` | Binary protocol порт |
| `BARADB_HTTP_PORT` | `9470` | HTTP порт |
| `BARADB_WS_PORT` | `9471` | WebSocket порт |
| `BARADB_DATA_DIR` | `/data` | Директория за данни |
| `BARADB_LOG_LEVEL` | `info` | Ниво на логове |

> **Забележка:** В момента приложението използва built-in стойности. Пълна поддръжка на env променливи се разработва.

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
docker exec baradb /app/backup backup --data-dir=/data

# Списък на backups
docker exec baradb /app/backup list

# Възстановяване
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
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
# Проверка дали портовете са експознати
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
