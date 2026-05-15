# دليل نشر Docker

## البداية السريعة

```bash
git clone https://codeberg.org/baraba/bara-lang
cd barabaDB

docker build -t baradb:latest .

docker compose up -d

docker compose ps
docker compose logs -f
```

## الملفات

| الملف | الوصف |
|-------|-------|
| `Dockerfile` | بناء multi-stage للإنتاج |
| `docker-compose.yml` | تكوين التطوير |
| `docker-compose.prod.yml` | تكوين الإنتاج |

## بناء الصورة

```bash
docker build -t baradb:latest .
```

## التشغيل

### التطوير

```bash
docker compose up -d
docker compose down
```

### الإنتاج

```bash
docker compose -f docker-compose.prod.yml up -d
```

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