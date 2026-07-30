# Deployment Guide

**Production GA (v1.2.0)** is **single-node**. See [known limitations](known-limitations.md).  
Raft multi-node is [documented](distributed.md) as **experimental**.

## Ports

| Service | Port | Notes |
|---------|------|--------|
| Binary wire | `BARADB_PORT` (default 9472) | Clients |
| HTTP REST | `BARADB_PORT + 440` (9912) | `/health`, `/query`, `/metrics` |
| WebSocket | `BARADB_PORT + 441` (9913) | |
| Raft | `BARADB_RAFT_PORT` | Experimental cluster only |

There is **no** `BARADB_HTTP_PORT` — HTTP is always TCP+440.

## Docker

See also [Docker Guide](docker.md).

### Development

```bash
docker build -t baradb:latest .
docker compose up -d
```

### Production (GA)

```bash
export BARADB_JWT_SECRET="$(openssl rand -hex 32)"
docker compose -f docker-compose.prod.yml up -d --build
```

- Auth is **on**; compose **fails** if `BARADB_JWT_SECRET` is unset.
- Binary sets `BARADB_ENV=production` → process refuses empty/placeholder secrets.
- Image tag: `baradb:1.2.0`.

Optional backup sidecar:

```bash
docker compose -f docker-compose.prod.yml --profile backup up -d
```

| Compose file | Role |
|--------------|------|
| `docker-compose.yml` | Development |
| `docker-compose.prod.yml` | Production GA |
| `docker-compose.override.yml` | Local override |

> Note: `deploy.resources` limits apply under Docker Swarm; plain Compose may ignore them.

## Production runbook

### Start (binary)

```bash
export BARADB_ENV=production
export BARADB_AUTH_ENABLED=true
export BARADB_JWT_SECRET="$(openssl rand -hex 32)"   # store securely
export BARADB_PORT=9472
export BARADB_DATA_DIR=/var/lib/baradb/data
export BARADB_LOG_LEVEL=warn
export BARADB_LOG_FILE=/var/log/baradb/baradb.log
./build/baradadb
```

### Stop

```bash
# systemd
sudo systemctl stop baradb
# docker
docker compose -f docker-compose.prod.yml down
# foreground: Ctrl+C / SIGTERM
```

### Health / metrics

```bash
curl -s http://127.0.0.1:9912/health
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9912/metrics
```

### Auth token (prod)

```bash
curl -s -X POST http://127.0.0.1:9912/auth \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$BARADB_JWT_SECRET\"}"
```

### Backup (server stopped or offline-consistent)

Preferred offline / all-databases:

```bash
./build/backup backup --all-databases \
  --data-root=/var/lib/baradb/data/databases \
  --output=/backups/baradb_$(date +%Y%m%d_%H%M%S).tar.gz
```

Copy archives off-host. Details: [backup.md](backup.md).

### Restore

1. **Stop** BaraDB.
2. Move aside or empty the data root (keep a copy of the broken dir).
3. Restore:

```bash
./build/backup restore --input=/backups/baradb_YYYYMMDD.tar.gz \
  --all-databases --data-root=/var/lib/baradb/data/databases --force
```

4. Start BaraDB; verify with a known query.

### Automated drill

```bash
nim c -o:build/baradadb src/baradadb.nim
nim c -o:build/backup src/barabadb/core/backup.nim
./scripts/backup-restore-drill.sh
```

### Logs

- File: `BARADB_LOG_FILE` (prod compose: `./logs` → `/var/log/baradb`)
- Docker: `docker logs baradb`

### Data layout

```
$BARADB_DATA_DIR/
  databases/
    default/     # LSM + WAL + schema keys
  raft/          # only if raft enabled
```

## systemd

`/etc/systemd/system/baradb.service`:

```ini
[Unit]
Description=BaraDB Multimodal Database
After=network.target

[Service]
Type=simple
User=baradb
Group=baradb
WorkingDirectory=/var/lib/baradb
ExecStart=/usr/local/bin/baradadb
Restart=always
RestartSec=5

Environment=BARADB_ENV=production
Environment=BARADB_PORT=9472
Environment=BARADB_DATA_DIR=/var/lib/baradb/data
Environment=BARADB_LOG_LEVEL=warn
Environment=BARADB_AUTH_ENABLED=true
# Environment=BARADB_JWT_SECRET=  # use EnvironmentFile
EnvironmentFile=-/etc/baradb/baradb.env

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/baradb/data /var/log/baradb
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd -r -s /bin/false baradb
sudo mkdir -p /var/lib/baradb/data /var/log/baradb /etc/baradb
# put BARADB_JWT_SECRET=... in /etc/baradb/baradb.env (mode 600)
sudo systemctl daemon-reload
sudo systemctl enable --now baradb
```

## High Availability (experimental)

Raft multi-node is **not** the v1.2.0 GA tier. See [distributed.md](distributed.md)
and [known-limitations](known-limitations.md). Use `id@host:port` peer format:

```bash
export BARADB_RAFT_ENABLED=true
export BARADB_RAFT_NODE_ID=n1
export BARADB_RAFT_PORT=46101
export BARADB_RAFT_PEERS=n1@127.0.0.1:46101,n2@127.0.0.1:46102,n3@127.0.0.1:46103
export BARADB_RAFT_CLIENT_PEERS=n1@127.0.0.1:46010,n2@127.0.0.1:46020,n3@127.0.0.1:46030
```

## Reverse proxy (nginx)

Proxy to **HTTP = TCP+440** (9912 if TCP is 9472):

```nginx
upstream baradb_http {
    server 127.0.0.1:9912;
}
upstream baradb_ws {
    server 127.0.0.1:9913;
}
server {
    listen 443 ssl http2;
    server_name db.example.com;
    location / {
        proxy_pass http://baradb_http;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location /ws/ {
        proxy_pass http://baradb_ws/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

## See also

- [Known limitations](known-limitations.md)
- [Release checklist](release-checklist.md)
- [Backup](backup.md) · [Monitoring](monitoring.md) · [Distributed / Raft](distributed.md)
