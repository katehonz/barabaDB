# Yapılandırma Referansı

BaraDB **ortam değişkenleri**, **yapılandırma dosyası** veya **komut satırı bayrakları** ile yapılandırılabilir.

## Öncelik Sırası

1. Komut satırı bayrakları (en yüksek)
2. Ortam değişkenleri
3. Yapılandırma dosyası (`baradb.conf` veya `baradb.json`)
4. Yerleşik varsayılanlar (en düşük)

## Ortam Değişkenleri

### Ağ

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `BARADB_ADDRESS` | `127.0.0.1` | Bağlama adresi |
| `BARADB_PORT` | `9472` | TCP ikili protokol portu |
| `BARADB_HTTP_PORT` | `9470` | HTTP/REST API portu |
| `BARADB_WS_PORT` | `9471` | WebSocket portu |

### Depolama

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `BARADB_DATA_DIR` | `./data` | Veri dizini yolu |
| `BARADB_MEMTABLE_SIZE_MB` | `64` | MemTable boyutu (MB) |
| `BARADB_CACHE_SIZE_MB` | `256` | Sayfa önbellek boyutu (MB) |

### TLS/SSL

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `BARADB_TLS_ENABLED` | `false` | TLS'yi etkinleştir |
| `BARADB_CERT_FILE` | — | TLS sertifika dosyası |
| `BARADB_KEY_FILE` | — | TLS özel anahtar dosyası |

### Güvenlik

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `BARADB_AUTH_ENABLED` | `false` | Kimlik doğrulamayı etkinleştir |
| `BARADB_JWT_SECRET` | — | JWT imzalama sırrı |
| `BARADB_RATE_LIMIT_GLOBAL` | `10000` | Global istek/saniye |
| `BARADB_RATE_LIMIT_PER_CLIENT` | `1000` | İstemci başına istek/saniye |

## Yapılandırma Dosyası

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

## Komut Satırı Bayrakları

```bash
./build/baradadb --help
```

```
Options:
  -c, --config <file>       Yapılandırma dosyası yolu
  -p, --port <port>         TCP ikili port (varsayılan: 9472)
  --http-port <port>        HTTP port (varsayılan: 9470)
  -d, --data-dir <dir>      Veri dizini (varsayılan: ./data)
  --shell                   İnteraktif kabuk başlat
  --version                 Versiyonu göster
```

## Örnek Yapılandırmalar

### Geliştirme

```bash
./build/baradadb --log-level debug --data-dir ./dev_data
```

### Üretim Tek Düğüm

```bash
BARADB_TLS_ENABLED=true \
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
BARADB_MEMTABLE_SIZE_MB=256 \
BARADB_CACHE_SIZE_MB=1024 \
./build/baradadb
```