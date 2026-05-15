# راهنمای استقرار Docker

## شروع سریع

```bash
git clone https://codeberg.org/baraba/bara-lang
cd barabaDB

docker build -t baradb:latest .

docker compose up -d

docker compose ps
docker compose logs -f
```

## فایل‌ها

| فایل | توضیح |
|------|--------|
| `Dockerfile` | ساخت multi-stage production |
| `docker-compose.yml` | پیکربندی توسعه |
| `docker-compose.prod.yml` | پیکربندی تولید |
| `docker-compose.override.yml` | Override توسعه |
| `docker-entrypoint.sh` | اسکریپت entrypoint |
| `.dockerignore` | فایل‌های مستثنی از کپی |
| `scripts/docker-build.sh` | اسکریپت کمکی ساخت |
| `scripts/docker-run.sh` | اسکریپت کمکی اجرا |

## ساخت تصویر

```bash
docker build -t baradb:latest .
./scripts/docker-build.sh
```

## اجرا

### توسعه

```bash
docker compose up -d
docker compose down
docker compose logs -f
```

### تولید

```bash
docker compose -f docker-compose.prod.yml up -d
```

### دستی

```bash
docker run -d \
  --name baradb \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  baradb:latest
```

## پورت‌ها

| پورت | توضیح |
|------|--------|
| `9472` | پروتکل باینری |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## متغیرهای محیطی

| متغیر | پیش‌فرض | توضیح |
|--------|---------|--------|
| `BARADB_ADDRESS` | `0.0.0.0` | آدرس اتصال |
| `BARADB_PORT` | `9472` | پورت پروتکل باینری |
| `BARADB_HTTP_PORT` | `9470` | پورت HTTP |
| `BARADB_DATA_DIR` | `/data` | پوشه داده |

## Volumeها

| مسیر | توضیح |
|------|--------|
| `/data` | پوشه اصلی داده |
| `/data/server/wal` | Write-ahead log |
| `/data/server/sstables` | فایل‌های SSTable |

## چک‌لیست تولید

- [ ] ایجاد گواهی‌های TLS
- [ ] تنظیم `BARADB_JWT_SECRET` قوی
- [ ] پیکربندی قوانین فایروال
- [ ] تنظیم پشتیبان‌گیری منظم
- [ ] بررسی محدودیت منابع
- [ ] تنظیم مانیتورینگ

## TLS در Docker

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

## پشتیبان‌گیری

```bash
docker exec baradb /app/backup backup --data-dir=/data
docker exec baradb /app/backup list
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
```