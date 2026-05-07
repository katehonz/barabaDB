# مرجع پیکربندی

BaraDB از **متغیرهای محیطی**، **فایل پیکربندی** یا **پرچم‌های خط فرمان** پیکربندی می‌شود.

## اولویت

1. پرچم‌های خط فرمان (بالاترین)
2. متغیرهای محیطی
3. فایل پیکربندی (`baradb.conf` یا `baradb.json`)
4. مقادیر پیش‌فرض (پایین‌ترین)

## متغیرهای محیطی

### شبکه

| متغیر | پیش‌فرض | توضیح |
|--------|---------|--------|
| `BARADB_ADDRESS` | `127.0.0.1` | آدرس اتصال |
| `BARADB_PORT` | `9472` | پورت پروتکل باینری |
| `BARADB_HTTP_PORT` | `9470` | پورت HTTP/REST API |
| `BARADB_WS_PORT` | `9471` | پورت WebSocket |

### ذخیره‌سازی

| متغیر | پیش‌فرض | توضیح |
|--------|---------|--------|
| `BARADB_DATA_DIR` | `./data` | مسیر پوشه داده |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | اندازه MemTable (MB) |
| `BARADB_CACHE_SIZE_MB` | `256` | اندازه کش صفحه (MB) |

### TLS/SSL

| متغیر | پیش‌فرض | توضیح |
|--------|---------|--------|
| `BARADB_TLS_ENABLED` | `false` | فعال‌سازی TLS |
| `BARADB_CERT_FILE` | — | مسیر گواهی TLS |
| `BARADB_KEY_FILE` | — | مسیر کلید TLS |

### امنیت

| متغیر | پیش‌فرض | توضیح |
|--------|---------|--------|
| `BARADB_AUTH_ENABLED` | `false` | فعال‌سازی احراز هویت |
| `BARADB_JWT_SECRET` | — | رمز امضای JWT |

## فایل پیکربندی

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

## پرچم‌های خط فرمان

```bash
./build/baradadb --help
```

## نمونه پیکربندی‌ها

### توسعه

```bash
./build/baradadb --log-level debug --data-dir ./dev_data
```

### تولید - گره واحد

```bash
BARADB_TLS_ENABLED=true \
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
BARADB_MEMTABLE_SIZE_MB=256 \
BARADB_CACHE_SIZE_MB=1024 \
./build/baradadb
```