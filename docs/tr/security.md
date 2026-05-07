# Güvenlik Rehberi

## TLS/SSL Şifreleme

BaraDB tüm protokoller için TLS 1.3 destekler. Sertifika sağlanmazsa, sunucu sıfır yapılandırma şifrelemesi için başlangıçta otomatik olarak kendinden imzalı sertifika üretir.

### Özel Sertifika Kullanımı

```bash
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### Kendinden İmzalı Sertifika Oluşturma

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

## Kimlik Doğrulama

### JWT Tabanlı Kimlik Doğrulama

BaraDB HMAC-SHA256 imzalı JWT kullanır.

### Kimlik Doğrulamayı Etkinleştirme

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

### Rol Tabanlı Erişim Kontrolü

| Rol | İzinler |
|-----|---------|
| `admin` | Tam erişim |
| `write` | Okuma + Yazma |
| `read` | Salt okunur |
| `monitor` | Yalnızca metrikler ve sağlık |

## Hız Sınırlama

Token-bucket hız sınırlama kötüye kullanımı önler:

```nim
var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,
  perClientRate = 1000,
  burstSize = 100
)
```

## Ağ Güvenliği

### Bağlama Adresi

```bash
BARADB_ADDRESS=0.0.0.0 ./build/baradadb
```

## Güvenlik Kontrol Listesi

- [ ] Varsayılan JWT sırrını değiştirin
- [ ] Geçerli sertifikalarla TLS'yi etkinleştirin
- [ ] Belirli arayüzlere bağlayın
- [ ] Üretimde kimlik doğrulamayı etkinleştirin
- [ ] Hız sınırlama yapılandırın
- [ ] Denetim günlüğünü etkinleştirin
- [ ] Durağan verileri şifreleyin (LUKS veya uygulama düzeyinde)
- [ ] BaraDB'yi root olmayan kullanıcı olarak çalıştırın