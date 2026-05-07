# Руководство по безопасности

## TLS/SSL шифрование

BaraDB поддерживает TLS 1.3 для всех протоколов (бинарный, HTTP, WebSocket). Если сертификат не предоставлен, сервер автоматически генерирует самоподписанный сертификат при запуске для шифрования без конфигурации.

### Использование пользовательских сертификатов

```bash
# Предоставьте существующие сертификаты
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### Генерация самоподписанных сертификатов

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

### Let's Encrypt (Производство)

Используйте certbot и укажите BaraDB на сгенерированные файлы:

```bash
sudo certbot certonly --standalone -d db.example.com

BARADB_CERT_FILE=/etc/letsencrypt/live/db.example.com/fullchain.pem \
BARADB_KEY_FILE=/etc/letsencrypt/live/db.example.com/privkey.pem \
./build/baradadb
```

### TLS на стороне клиента

```python
from baradb import Client

client = Client("localhost", 9472, tls=True, tls_verify=True)
client.connect()
```

## Аутентификация

### JWT-аутентификация

BaraDB использует JWT (JSON Web Tokens) с подписью HMAC-SHA256.

#### Включение аутентификации

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

#### Создание токенов

```nim
import barabadb/protocol/auth

var am = newAuthManager("your-secret-key")
let token = am.createToken(JWTClaims(
  sub: "user1",
  role: "admin",
  exp: getTime() + 24.hours
))
```

#### Контроль доступа на основе ролей

| Роль | Разрешения |
|------|------------|
| `admin` | Полный доступ |
| `write` | Чтение + запись |
| `read` | Только чтение |
| `monitor` | Только метрики и здоровье |

#### Использование токенов

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

### Многофакторная аутентификация (MFA)

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
# MFA на основе TOTP
let mfaCode = am.generateTOTP("user1")
let valid = am.validateTOTP("user1", mfaCode)
```

## Ограничение скорости

Token-bucket ограничение скорости предотвращает злоупотребления:

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,      # 10K req/s глобально
  perClientRate = 1000,    # 1K req/s на клиент
  burstSize = 100          # Позволить burst 100 req
)

if not rl.allowRequest("client-ip"):
  return error("Rate limit exceeded")
```

## Сетевая безопасность

### Адрес привязки

По умолчанию BaraDB привязывается к `127.0.0.1` (только localhost). Для производства:

```bash
# Привязать ко всем интерфейсам (за файрволом или обратным прокси)
BARADB_ADDRESS=0.0.0.0 ./build/baradadb

# Привязать к конкретному внутреннему интерфейсу
BARADB_ADDRESS=10.0.0.5 ./build/baradadb
```

### Правила файрвола

```bash
# Разрешить только серверам приложений
sudo ufw allow from 10.0.0.0/8 to any port 9472
sudo ufw allow from 10.0.0.0/8 to any port 9470

# Заблокировать внешний доступ к портам управления
sudo ufw deny 9471  # WebSocket (только внутреннее использование)
```

## Шифрование данных в покое

### Шифрование на уровне ОС

Используйте LUKS для полнодискового шифрования:

```bash
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 baradb-crypt
mkfs.ext4 /dev/mapper/baradb-crypt
mount /dev/mapper/baradb-crypt /var/lib/baradb
```

### Шифрование на уровне приложения

BaraDB поддерживает прозрачное шифрование SSTable файлов:

```bash
BARADB_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
./build/baradadb
```

## Аудитлог

Все запросы и административные действия логируются:

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

Включите аудитлог:

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/audit.log \
./build/baradadb
```

## Чеклист безопасности

- [ ] Изменить секрет JWT по умолчанию
- [ ] Включить TLS с валидными сертификатами
- [ ] Привязать к конкретным интерфейсам
- [ ] Включить аутентификацию в производстве
- [ ] Настроить ограничение скорости
- [ ] Включить аудитлог
- [ ] Шифровать данные в покое (LUKS или на уровне приложения)
- [ ] Запускать BaraDB от не-root пользователя
- [ ] Поддерживать файрвол в строгом режиме
- [ ] Регулярно менять секреты JWT