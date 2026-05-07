# دليل النشر

## Docker

### البداية السريعة

```bash
docker build -t baradb:latest .
docker compose up -d
docker compose ps
```

### ملفات Docker Compose

| الملف | الغرض |
|-------|-------|
| `docker-compose.yml` | التطوير |
| `docker-compose.prod.yml` | الإنتاج |

## المنافذ

| المنفذ | الوصف |
|--------|-------|
| `9472` | بروتوكول Wire الثنائي |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## متغيرات البيئة

| المتغير | الافتراضي | الوصف |
|---------|-----------|-------|
| `BARADB_ADDRESS` | `0.0.0.0` | عنوان الاستماع |
| `BARADB_PORT` | `9472` | منفذ البروتوكول الثنائي |
| `BARADB_HTTP_PORT` | `9470` | منفذ HTTP |
| `BARADB_DATA_DIR` | `/data` | دليل البيانات |

## المجلدات

| المسار | الوصف |
|--------|-------|
| `/data` | دليل البيانات الرئيسي |
| `/data/server/wal` | سجل write-ahead |
| `/data/server/sstables` | ملفات SSTable |

## قائمة التحقق للإنتاج

- [ ] إنشاء شهادات TLS في `./certs/`
- [ ] تعيين `BARADB_JWT_SECRET` قوي
- [ ] تكوين قواعد جدار الحماية
- [ ] تكوين النسخ الاحتياطي المنتظم
- [ ] التحقق من حدود الموارد
- [ ] تكوين المراقبة

## TLS في Docker

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

## النسخ الاحتياطي في Docker

```bash
docker exec baradb /app/backup backup --data-dir=/data
docker exec baradb /app/backup list
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
```