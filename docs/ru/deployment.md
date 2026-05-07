# Руководство по развёртыванию

## Docker

### Быстрый старт

```bash
docker build -t baradb:latest .
docker compose up -d
docker compose ps
```

### Файлы Docker Compose

| Файл | Назначение |
|------|-----------|
| `docker-compose.yml` | Development |
| `docker-compose.prod.yml` | Production |

## Порты

| Порт | Описание |
|------|----------|
| `9472` | Binary wire protocol |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## Переменные окружения

| Переменная | По умолчанию | Описание |
|-----------|--------------|----------|
| `BARADB_ADDRESS` | `0.0.0.0` | Адрес для прослушивания |
| `BARADB_PORT` | `9472` | Binary protocol порт |
| `BARADB_HTTP_PORT` | `9470` | HTTP порт |
| `BARADB_DATA_DIR` | `/data` | Директория для данных |

## Production чеклист

- [ ] Создать TLS сертификаты в `./certs/`
- [ ] Установить сильный `BARADB_JWT_SECRET`
- [ ] Настроить файрвол правила
- [ ] Настроить регулярные бэкапы
- [ ] Проверить resource limits
- [ ] Настроить мониторинг