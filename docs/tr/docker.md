# Docker Dağıtım Rehberi

## Hızlı Başlangıç

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB

docker build -t baradb:latest .

docker compose up -d

docker compose ps
docker compose logs -f
```

## Dosyalar

| Dosya | Açıklama |
|-------|----------|
| `Dockerfile` | Multi-stage üretim build |
| `docker-compose.yml` | Geliştirme yapılandırması |
| `docker-compose.prod.yml` | Üretim yapılandırması |

## Image Oluşturma

```bash
docker build -t baradb:latest .
```

## Çalıştırma

### Geliştirme

```bash
docker compose up -d
docker compose down
```

### Üretim

```bash
docker compose -f docker-compose.prod.yml up -d
```

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
| `/data` | Ana veri dizini |
| `/data/server/wal` | Write-ahead log |
| `/data/server/sstables` | SSTable dosyaları |

## Üretim Kontrol Listesi

- [ ] `./certs/` içinde TLS sertifikaları oluşturun
- [ ] Güçlü `BARADB_JWT_SECRET` ayarlayın
- [ ] Güvenlik duvarı kurallarını yapılandırın
- [ ] Düzenli yedeklemeler yapılandırın
- [ ] Kaynak sınırlarını kontrol edin
- [ ] İzleme ayarlayın