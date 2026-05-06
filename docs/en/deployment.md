# Deployment Guide

## Docker

### Single Node

```bash
docker build -t baradb:latest .
docker run -d \
  --name baradb \
  -p 5432:5432 \
  -p 8080:8080 \
  -p 8081:8081 \
  -v baradb_data:/data \
  -e BARADB_DATA_DIR=/data \
  baradb:latest
```

### Docker Compose (Production)

```yaml
version: "3.9"
services:
  baradb:
    image: baradb:latest
    ports:
      - "5432:5432"
      - "8080:8080"
      - "8081:8081"
    volumes:
      - baradb_data:/data
      - ./certs:/certs:ro
    environment:
      - BARADB_PORT=5432
      - BARADB_HTTP_PORT=8080
      - BARADB_WS_PORT=8081
      - BARADB_DATA_DIR=/data
      - BARADB_TLS_ENABLED=true
      - BARADB_CERT_FILE=/certs/server.crt
      - BARADB_KEY_FILE=/certs/server.key
      - BARADB_LOG_LEVEL=info
      - BARADB_MEMTABLE_SIZE_MB=256
      - BARADB_CACHE_SIZE_MB=512
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 8G
        reservations:
          cpus: '1.0'
          memory: 1G

volumes:
  baradb_data:
```

### Docker Swarm

```bash
docker stack deploy -c docker-compose.yml baradb
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

Environment=BARADB_PORT=5432
Environment=BARADB_HTTP_PORT=8080
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
        - containerPort: 5432
          name: binary
        - containerPort: 8080
          name: http
        - containerPort: 8081
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
  - port: 5432
    name: binary
  - port: 8080
    name: http
  - port: 8081
    name: websocket
  clusterIP: None
```

## Reverse Proxy (nginx)

```nginx
upstream baradb_http {
    server 127.0.0.1:8080;
}

upstream baradb_ws {
    server 127.0.0.1:8081;
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
  --port 8080 \
  --memory 4Gi \
  --cpu 2 \
  --max-instances 10
```
