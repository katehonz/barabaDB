# Docker Deployment-Leitfaden

Dieser Leitfaden beschreibt, wie Sie BaraDB mit Docker und Docker Compose verwenden.

## Schnellstart

```bash
# Repository klonen
git clone https://codeberg.org/baraba/baradb
cd barabaDB

# Image bauen
docker build -t baradb:latest .

# Mit Docker Compose starten
docker compose up -d

# Status prüfen
docker compose ps
docker compose logs -f
```

## Dateien

| Datei | Beschreibung |
|-------|--------------|
| `Dockerfile` | Multi-stage Production Build |
| `docker-compose.yml` | Development Konfiguration |
| `docker-compose.prod.yml` | Production Konfiguration |
| `docker-compose.override.yml` | Development Override (wird automatisch geladen) |
| `docker-entrypoint.sh` | Entrypoint-Skript für Initialisierung |
| `.dockerignore` | Dateien, die nicht ins Image kopiert werden sollen |
| `scripts/docker-build.sh` | Helper-Skript für Build |
| `scripts/docker-run.sh` | Helper-Skript für manuelles Starten |

## Image erstellen

```bash
# Standard Build
docker build -t baradb:latest .

# Mit Skript
./scripts/docker-build.sh

# Mit bestimmter Version
IMAGE_NAME=baradb VERSION=0.1.0 ./scripts/docker-build.sh
```

## Starten

### Development (docker compose)

```bash
# Im Hintergrund starten
docker compose up -d

# Stoppen
docker compose down

# Stoppen und Volumes löschen (WARNUNG — löscht Daten!)
docker compose down -v

# Logs ansehen
docker compose logs -f
```

### Production (docker compose)

```bash
# Mit Production-Konfiguration starten
docker compose -f docker-compose.prod.yml up -d

# Healthcheck prüfen
docker compose -f docker-compose.prod.yml ps
```

### Manuell (docker run)

```bash
# Mit Skript
./scripts/docker-run.sh

# Manuell
docker run -d \
  --name baradb \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  -e BARADB_LOG_LEVEL=info \
  baradb:latest
```

## Ports

| Port | Beschreibung |
|------|--------------|
| `9472` | Binary Wire Protocol |
| `9912` | HTTP/REST API (TCP port + 440) |
| `9913` | WebSocket (TCP port + 441) |

## Environment Variables

| Variable | Standardwert | Beschreibung |
|----------|--------------|--------------|
| `BARADB_ADDRESS` | `0.0.0.0` | Bind-Adresse |
| `BARADB_PORT` | `9472` | Binary Protocol Port |
| `BARADB_HTTP_PORT` | `9470` | HTTP Port |
| `BARADB_WS_PORT` | `9471` | WebSocket Port |
| `BARADB_DATA_DIR` | `/data` | Datenverzeichnis |
| `BARADB_LOG_LEVEL` | `info` | Log-Level |

## Volumes

| Pfad im Container | Beschreibung |
|-------------------|--------------|
| `/data` | Hauptdatenverzeichnis |
| `/data/server/wal` | Write-Ahead Log |
| `/data/server/sstables` | SSTable Dateien |

## Production Checklist

- [ ] TLS-Zertifikate in `./certs/` erstellen
- [ ] Starkes `BARADB_JWT_SECRET` setzen
- [ ] Firewall-Regeln konfigurieren
- [ ] Regelmäßige Backups konfigurieren
- [ ] Resource Limits prüfen
- [ ] Monitoring einrichten (Healthcheck, Logs)

## TLS in Docker

1. Zertifikate erstellen:
```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

2. In `docker-compose.prod.yml` aktivieren:
```yaml
environment:
  - BARADB_TLS_ENABLED=true
  - BARADB_CERT_FILE=/certs/server.crt
  - BARADB_KEY_FILE=/certs/server.key
volumes:
  - ./certs:/certs:ro
```

## Backup in Docker

```bash
# Manueller Backup
docker exec baradb /app/backup backup --data-dir=/data

# Backup-Liste
docker exec baradb /app/backup list

# Wiederherstellung
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
```

## Troubleshooting

### Container startet nicht

```bash
# Logs prüfen
docker compose logs -f baradb

# Status prüfen
docker compose ps
```

### Keine Verbindung zur Datenbank

```bash
# Prüfen ob Ports exponiert sind
docker port baradb

# Von innen prüfen
docker exec baradb wget -qO- http://localhost:9470/health
```

### Permission denied auf /data

Das Entrypoint-Skript erstellt automatisch Verzeichnisse und setzt korrekte Permissions. Bei Problemen:

```bash
docker exec baradb ls -la /data
docker exec baradb chown -R baradb:baradb /data
```
