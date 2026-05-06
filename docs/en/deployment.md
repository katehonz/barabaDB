# Deployment Guide

## Docker

За пълно ръководство за Docker deployment вижте [Docker Guide](docker.md).

### Бърз старт

```bash
docker build -t baradb:latest .
docker compose up -d
```

### Docker Compose файлове

| Файл | Назначение |
|------|-----------|
| `docker-compose.yml` | Development |
| `docker-compose.prod.yml` | Production |
| `docker-compose.override.yml` | Dev override (автоматично) |

### Production

```bash
docker compose -f docker-compose.prod.yml up -d
```

### Docker Swarm

```bash
docker stack deploy -c docker-compose.prod.yml baradb
```

## systemd Service

Create `/etc/systemd/system/baradb.service`:

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

Environment=BARADB_PORT=9472
Environment=BARADB_HTTP_PORT=9470
Environment=BARADB_DATA_DIR=/var/lib/baradb/data
Environment=BARADB_LOG_LEVEL=info

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/baradb/data
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo useradd -r -s /bin/false baradb
sudo mkdir -p /var/lib/baradb/data
sudo chown -R baradb:baradb /var/lib/baradb
sudo cp build/baradadb /usr/local/bin/
sudo systemctl daemon-reload
sudo systemctl enable --now baradb
```

## Kubernetes

### StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: baradb
spec:
  serviceName: baradb
  replicas: 3
  selector:
    matchLabels:
      app: baradb
  template:
    metadata:
      labels:
        app: baradb
    spec:
      containers:
      - name: baradb
        image: baradb:latest
        ports:
        - containerPort: 9472
          name: binary
        - containerPort: 9470
          name: http
        - containerPort: 9471
          name: websocket
        env:
        - name: BARADB_DATA_DIR
          value: /data
        - name: BARADB_RAFT_NODE_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Gi
---
apiVersion: v1
kind: Service
metadata:
  name: baradb
spec:
  selector:
    app: baradb
  ports:
  - port: 9472
    name: binary
  - port: 9470
    name: http
  - port: 9471
    name: websocket
  clusterIP: None
```

## Reverse Proxy (nginx)

```nginx
upstream baradb_http {
    server 127.0.0.1:9470;
}

upstream baradb_ws {
    server 127.0.0.1:9471;
}

server {
    listen 80;
    server_name db.example.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name db.example.com;

    ssl_certificate /etc/letsencrypt/live/db.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/db.example.com/privkey.pem;

    location /api/ {
        proxy_pass http://baradb_http/;
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

## High Availability

### 3-Node Raft Cluster

```bash
# Node 1
BARADB_RAFT_NODE_ID=node1 \
BARADB_RAFT_PEERS=node2:9001,node3:9001 \
./build/baradadb

# Node 2
BARADB_RAFT_NODE_ID=node2 \
BARADB_RAFT_PEERS=node1:9001,node3:9001 \
./build/baradadb

# Node 3
BARADB_RAFT_NODE_ID=node3 \
BARADB_RAFT_PEERS=node1:9001,node2:9001 \
./build/baradadb
```

## Cloud Deployment

### AWS EC2

Recommended instance: `m6i.2xlarge` (8 vCPU, 32 GB RAM)

```bash
# User data script
#!/bin/bash
apt-get update
apt-get install -y nim
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-amd64
chmod +x baradadb-linux-amd64
mv baradadb-linux-amd64 /usr/local/bin/baradadb

mkdir -p /data/baradb
cat > /etc/systemd/system/baradb.service << 'EOF'
[Unit]
Description=BaraDB
After=network.target
[Service]
ExecStart=/usr/local/bin/baradadb
Environment=BARADB_DATA_DIR=/data/baradb
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now baradb
```

### GCP Cloud Run (HTTP only)

```bash
gcloud run deploy baradb \
  --image gcr.io/PROJECT/baradb \
  --port 9470 \
  --memory 4Gi \
  --cpu 2 \
  --max-instances 10
```
