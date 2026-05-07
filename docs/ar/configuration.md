# مرجع التكوين

يمكن تكوين BaraDB عبر **متغيرات البيئة** أو **ملف التكوين** أو **علامات سطر الأوامر**.

## ترتيب الأولوية

1. علامات سطر الأوامر (الأعلى)
2. متغيرات البيئة
3. ملف التكوين (`baradb.conf` أو `baradb.json`)
4. الإعدادات الافتراضية (الأدنى)

## متغيرات البيئة

### الشبكة

| المتغير | الافتراضي | الوصف |
|---------|-----------|-------|
| `BARADB_ADDRESS` | `127.0.0.1` | عنوان الربط |
| `BARADB_PORT` | `9472` | منفذ البروتوكول الثنائي |
| `BARADB_HTTP_PORT` | `9470` | منفذ HTTP/REST API |
| `BARADB_WS_PORT` | `9471` | منفذ WebSocket |

### التخزين

| المتغير | الافتراضي | الوصف |
|---------|-----------|-------|
| `BARADB_DATA_DIR` | `./data` | مسار دليل البيانات |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | حجم MemTable (MB) |
| `BARADB_CACHE_SIZE_MB` | `256` | حجم ذاكرة الصفحة (MB) |

### TLS/SSL

| المتغير | الافتراضي | الوصف |
|---------|-----------|-------|
| `BARADB_TLS_ENABLED` | `false` | تمكين TLS |
| `BARADB_CERT_FILE` | — | مسار شهادة TLS |
| `BARADB_KEY_FILE` | — | مسار مفتاح TLS الخاص |

### الأمان

| المتغير | الافتراضي | الوصف |
|---------|-----------|-------|
| `BARADB_AUTH_ENABLED` | `false` | تمكين المصادقة |
| `BARADB_JWT_SECRET` | — | سر توقيع JWT |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | طلبات/ثانية عامة |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | طلبات/ثانية لكل عميل |

## ملف التكوين

### baradb.conf

```ini
[server]
address = "0.0.0.0"
port = 9472
http_port = 9470

[storage]
data_dir = "/var/lib/baradb"
memtable_size_mb = 256
cache_size_mb = 512

[tls]
enabled = true
cert_file = "/etc/baradb/server.crt"
key_file = "/etc/baradb/server.key"

[auth]
enabled = true
jwt_secret = "change-me-in-production"
```

## علامات سطر الأوامر

```bash
./build/baradadb --help
```

## أمثلة التكوين

### التطوير

```bash
./build/baradadb --log-level debug --data-dir ./dev_data
```

### الإنتاج - عقدة واحدة

```bash
BARADB_TLS_ENABLED=true \
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
BARADB_MEMTABLE_SIZE_MB=256 \
BARADB_CACHE_SIZE_MB=1024 \
./build/baradadb
```