# Docker 部署指南

## 快速开始

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB

docker build -t baradb:latest .

docker compose up -d

docker compose ps
docker compose logs -f
```

## 文件

| 文件 | 描述 |
|------|------|
| `Dockerfile` | 多阶段生产构建 |
| `docker-compose.yml` | 开发配置 |
| `docker-compose.prod.yml` | 生产配置 |
| `docker-compose.override.yml` | 开发覆盖（自动加载）|
| `docker-entrypoint.sh` | 初始化入口脚本 |
| `.dockerignore` | 不复制到镜像的文件 |
| `scripts/docker-build.sh` | 构建辅助脚本 |
| `scripts/docker-run.sh` | 运行辅助脚本 |

## 构建镜像

```bash
docker build -t baradb:latest .
./scripts/docker-build.sh
```

## 运行

### 开发 (docker compose)

```bash
docker compose up -d
docker compose down
docker compose logs -f
```

### 生产 (docker compose)

```bash
docker compose -f docker-compose.prod.yml up -d
```

### 手动 (docker run)

```bash
docker run -d \
  --name baradb \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  baradb:latest
```

## 端口

| 端口 | 描述 |
|------|------|
| `9472` | 二进制协议 |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## 环境变量

| 变量 | 默认值 | 描述 |
|------|--------|------|
| `BARADB_ADDRESS` | `0.0.0.0` | 监听地址 |
| `BARADB_PORT` | `9472` | 二进制协议端口 |
| `BARADB_HTTP_PORT` | `9470` | HTTP 端口 |
| `BARADB_DATA_DIR` | `/data` | 数据目录 |

## 卷

| 路径 | 描述 |
|------|------|
| `/data` | 主数据目录 |
| `/data/server/wal` | 预写日志 |
| `/data/server/sstables` | SSTable 文件 |

## 生产检查清单

- [ ] 在 `./certs/` 创建 TLS 证书
- [ ] 设置强 `BARADB_JWT_SECRET`
- [ ] 配置防火墙规则
- [ ] 配置定期备份
- [ ] 检查资源限制
- [ ] 设置监控

## Docker 中的 TLS

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

## Docker 备份

```bash
docker exec baradb /app/backup backup --data-dir=/data
docker exec baradb /app/backup list
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
```

## 故障排除

### 容器不启动

```bash
docker compose logs -f baradb
docker compose ps
```

### 无法连接数据库

```bash
docker port baradb
docker exec baradb wget -qO- http://localhost:9470/health
```