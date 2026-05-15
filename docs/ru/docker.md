# Руководство по развёртыванию Docker

## Быстрый старт

```bash
# Клонировать репозиторий
git clone https://codeberg.org/baraba/baradb
cd barabaDB

# Собрать образ
docker build -t baradb:latest .

# Запустить с Docker Compose
docker compose up -d

# Проверить статус
docker compose ps
docker compose logs -f
```

## Файлы

| Файл | Описание |
|------|----------|
| `Dockerfile` | Multi-stage production build |
| `docker-compose.yml` | Development конфигурация |
| `docker-compose.prod.yml` | Production конфигурация |
| `docker-compose.override.yml` | Development override (автоматически загружается) |
| `docker-entrypoint.sh` | Entrypoint скрипт для инициализации |
| `.dockerignore` | Файлы, которые не копируются в образ |
| `scripts/docker-build.sh` | Helper скрипт для сборки |
| `scripts/docker-run.sh` | Helper скрипт для ручного запуска |

## Создание образа

```bash
# Стандартная сборка
docker build -t baradb:latest .

# Со скриптом
./scripts/docker-build.sh

# С конкретной версией
IMAGE_NAME=baradb VERSION=0.1.0 ./scripts/docker-build.sh
```

## Запуск

### Development (docker compose)

```bash
# Запуск в фоне
docker compose up -d

# Остановка
docker compose down

# Остановка и удаление volumes (ВНИМАНИЕ — удаляет данные!)
docker compose down -v

# Просмотр логов
docker compose logs -f
```

### Production (docker compose)

```bash
# Запуск с production конфигурацией
docker compose -f docker-compose.prod.yml up -d

# Проверка healthcheck
docker compose -f docker-compose.prod.yml ps
```

### Ручной (docker run)

```bash
# Со скриптом
./scripts/docker-run.sh

# Вручную
docker run -d \
  --name baradb \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  -e BARADB_LOG_LEVEL=info \
  baradb:latest
```

## Порты

| Порт | Описание |
|------|----------|
| `9472` | Binary wire protocol |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## Переменные окружения

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `BARADB_ADDRESS` | `0.0.0.0` | Адрес для прослушивания |
| `BARADB_PORT` | `9472` | Binary protocol порт |
| `BARADB_HTTP_PORT` | `9470` | HTTP порт |
| `BARADB_WS_PORT` | `9471` | WebSocket порт |
| `BARADB_DATA_DIR` | `/data` | Директория для данных |
| `BARADB_LOG_LEVEL` | `info` | Уровень логирования |

## Volumes

| Путь в контейнере | Описание |
|-------------------|----------|
| `/data` | Основная директория базы данных |
| `/data/server/wal` | Write-ahead log |
| `/data/server/sstables` | SSTable файлы |

## Production чеклист

- [ ] Создать TLS сертификаты в `./certs/`
- [ ] Установить сильный `BARADB_JWT_SECRET`
- [ ] Настроить файрвол правила
- [ ] Настроить регулярные бэкапы
- [ ] Проверить resource limits
- [ ] Настроить мониторинг (healthcheck, logs)

## TLS в Docker

1. Создайте сертификаты:
```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

2. Активируйте в `docker-compose.prod.yml`:
```yaml
environment:
  - BARADB_TLS_ENABLED=true
  - BARADB_CERT_FILE=/certs/server.crt
  - BARADB_KEY_FILE=/certs/server.key
volumes:
  - ./certs:/certs:ro
```

## Бэкап в Docker

```bash
# Ручной бэкап
docker exec baradb /app/backup backup --data-dir=/data

# Список бэкапов
docker exec baradb /app/backup list

# Восстановление
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
```

## Устранение проблем

### Контейнер не запускается

```bash
# Проверка логов
docker compose logs -f baradb

# Проверка статуса
docker compose ps
```

### Нет соединения с базой

```bash
# Проверка экспонированных портов
docker port baradb

# Проверка изнутри
docker exec baradb wget -qO- http://localhost:9470/health
```

### Permission denied на /data

Entrypoint скрипт автоматически создаёт директории и устанавливает правильные permissions. При проблемах:

```bash
docker exec baradb ls -la /data
docker exec baradb chown -R baradb:baradb /data
```