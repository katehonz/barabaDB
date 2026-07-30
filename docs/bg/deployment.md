# Deployment Guide (кратко)

**Production GA v1.2.0** = **single-node**. Виж [known-limitations](known-limitations.md).  
Пълен runbook: [en/deployment.md](../en/deployment.md).

## Портове

| Услуга | Порт |
|--------|------|
| Wire | `BARADB_PORT` (9472) |
| HTTP | `BARADB_PORT + 440` (9912) |
| WebSocket | `BARADB_PORT + 441` (9913) |

Няма `BARADB_HTTP_PORT`.

## Production Docker

```bash
export BARADB_JWT_SECRET="$(openssl rand -hex 32)"
docker compose -f docker-compose.prod.yml up -d --build
```

Auth е включен; без secret compose **спира**.

## Backup / restore drill

```bash
./scripts/backup-restore-drill.sh
```

## Health

```bash
curl -s http://127.0.0.1:9912/health
```
