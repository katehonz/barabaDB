# Dağıtım Rehberi

## Docker

### Hızlı Başlangıç

```bash
docker build -t baradb:latest .
docker compose up -d
docker compose ps
```

### Docker Compose Dosyaları

| Dosya | Amaç |
|-------|------|
| `docker-compose.yml` | Geliştirme |
| `docker-compose.prod.yml` | Üretim |

## Portlar

| Port | Açıklama |
|------|----------|
| `9472` | İkili tel protokolü |
| `9470` | HTTP/REST API |
| `9471` | WebSocket |

## Ortam Değişkenleri

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `BARADB_ADDRESS` | `0.0.0.0` | Dinleme adresi |
| `BARADB_PORT` | `9472` | İkili protokol portu |
| `BARADB_HTTP_PORT` | `9470` | HTTP portu |
| `BARADB_DATA_DIR` | `/data` | Veri dizini |

## Volumes

| Yol | Açıklama |
|-----|----------|
| `/data` | Ana veritabanı dizini |
| `/data/server/wal` | Write-ahead log |
| `/data/server/sstables` | SSTable dosyaları |

## Üretim Kontrol Listesi

- [ ] TLS sertifikaları oluşturun
- [ ] Güçlü `BARADB_JWT_SECRET` ayarlayın
- [ ] Güvenlik duvarı kurallarını yapılandırın
- [ ] Düzenli yedeklemeler ayarlayın
- [ ] Kaynak sınırlarını kontrol edin
- [ ] İzlemeyi yapılandırın

## TLS Docker'da

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key -out certs/server.crt
```

## Yedekleme Docker'da

```bash
docker exec baradb /app/backup backup --data-dir=/data
docker exec baradb /app/backup list
docker exec baradb /app/backup restore --input=backup_xxx.tar.gz
```