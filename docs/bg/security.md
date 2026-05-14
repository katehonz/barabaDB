# Ръководство за Сигурност

## TLS/SSL Криптиране

BaraDB поддържа TLS 1.3 за всички протоколи (бинарен, HTTP, WebSocket). Ако не е предоставен сертификат, сървърът автоматично генерира self-signed сертификат при стартиране за криптиране без конфигурация.

### Използване на Персонализирани Сертификати

```bash
# Предоставяне на съществуващи сертификати
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### Генериране на Self-Signed Сертификати

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

### Let's Encrypt (Продукция)

Използвайте certbot и насочете BaraDB към генерираните файлове:

```bash
sudo certbot certonly --standalone -d db.example.com

BARADB_CERT_FILE=/etc/letsencrypt/live/db.example.com/fullchain.pem \
BARADB_KEY_FILE=/etc/letsencrypt/live/db.example.com/privkey.pem \
./build/baradadb
```

### TLS от Страна на Клиента

```python
from baradb import Client

client = Client("localhost", 9472, tls=True, tls_verify=True)
client.connect()
```

## Автентикация

### JWT-Базирана Автентикация

BaraDB използва JWT (JSON Web Tokens) с HMAC-SHA256 подписване.

#### Включване на Автентикация

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

#### Създаване на Токени

```nim
import barabadb/protocol/auth

var am = newAuthManager("your-secret-key")
let token = am.createToken(JWTClaims(
  sub: "user1",
  role: "admin",
  exp: getTime() + 24.hours
))
```

#### Контрол на Достъп на База Роли

| Роля | Права |
|------|-------|
| `admin` | Пълен достъп |
| `write` | Четене + запис |
| `read` | Само четене |
| `monitor` | Само метрики и health |

#### Използване на Токени

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:9470/api/query \
  -d '{"query": "SELECT * FROM users"}'
```

```python
from baradb import Client

client = Client("localhost", 9472)
client.connect()
client.authenticate("eyJhbGciOiJIUzI1NiIs...")
```

### Многофакторна Автентикация (MFA)

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
# TOTP-базирана MFA
let mfaCode = am.generateTOTP("user1")
let valid = am.validateTOTP("user1", mfaCode)
```

## Rate Limiting

Token-bucket rate limiting предотвратява злоупотреби:

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,      # 10K заявки/s глобално
  perClientRate = 1000,    # 1K заявки/s на IP/токен
  burstSize = 100          # Разрешаване на 100 заявки burst
)

if not rl.allowRequest("client-ip"):
  return error("Лимитът на заявки е надвишен")
```

## Мрежова Сигурност

### Адрес за Свързване

По подразбиране BaraDB се свързва към `127.0.0.1` (само localhost). За продукция:

```bash
# Свързване към всички интерфейси (зад защитна стена или reverse proxy)
BARADB_ADDRESS=0.0.0.0 ./build/baradadb

# Свързване към конкретен вътрешен интерфейс
BARADB_ADDRESS=10.0.0.5 ./build/baradadb
```

### Правила на Защитната Стена

```bash
# Разрешаване само на сървъри на приложения
sudo ufw allow from 10.0.0.0/8 to any port 9472
sudo ufw allow from 10.0.0.0/8 to any port 9470

# Блокиране на външен достъп до портове за управление
sudo ufw deny 9471  # WebSocket (само вътрешна употреба)
```

## Криптиране на Данни в Покой

### Криптиране на Ниво ОС

Използвайте LUKS за пълно дисково криптиране:

```bash
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 baradb-crypt
mkfs.ext4 /dev/mapper/baradb-crypt
mount /dev/mapper/baradb-crypt /var/lib/baradb
```

### Криптиране на Ниво Приложение

BaraDB поддържа прозрачно криптиране на SSTable файлове:

```bash
BARADB_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
./build/baradadb
```

## Одитно Логване

Всички заявки и административни действия се логват:

```json
{
  "timestamp": "2025-01-15T10:30:00Z",
  "level": "info",
  "event": "query_executed",
  "client_ip": "10.0.0.15",
  "user": "app_user",
  "query": "SELECT * FROM users WHERE id = ?",
  "duration_ms": 12,
  "rows_returned": 1
}
```

Включване на одитно логване:

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/audit.log \
./build/baradadb
```

## Чеклист за Сигурност

- [ ] Сменете JWT secret по подразбиране
- [ ] Включете TLS с валидни сертификати
- [ ] Свържете се към конкретни интерфейси
- [ ] Включете автентикация в продукция
- [ ] Конфигурирайте rate limiting
- [ ] Включете одитно логване
- [ ] Криптирайте данните в покой (LUKS или на ниво приложение)
- [ ] Стартирайте BaraDB като non-root потребител
- [ ] Поддържайте рестриктивни правила на защитната стена
- [ ] Ротирайте JWT secret-и редовно
