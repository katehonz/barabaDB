# Sicherheitsleitfaden

## TLS/SSL-Verschlüsselung

BaraDB unterstützt TLS 1.3 für alle Protokolle (Binary, HTTP, WebSocket). Wenn kein
Zertifikat bereitgestellt wird, generiert der Server automatisch ein selbstsigniertes Zertifikat
beim Start für Zero-Configuration-Verschlüsselung.

### Eigene Zertifikate verwenden

```bash
# Vorhandene Zertifikate bereitstellen
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### Selbstsignierte Zertifikate generieren

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

### Let's Encrypt (Production)

Certbot verwenden und BaraDB auf die generierten Dateien zeigen:

```bash
sudo certbot certonly --standalone -d db.example.com

BARADB_CERT_FILE=/etc/letsencrypt/live/db.example.com/fullchain.pem \
BARADB_KEY_FILE=/etc/letsencrypt/live/db.example.com/privkey.pem \
./build/baradadb
```

## Authentifizierung

### JWT-basierte Authentifizierung

BaraDB verwendet JWT (JSON Web Tokens) mit HMAC-SHA256-Signatur.

#### Authentifizierung aktivieren

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

#### Tokens erstellen

```nim
import barabadb/protocol/auth

var am = newAuthManager("your-secret-key")
let token = am.createToken(JWTClaims(
  sub: "user1",
  role: "admin",
  exp: getTime() + 24.hours
))
```

#### Rollenbasierte Zugriffskontrolle

| Rolle | Berechtigungen |
|------|---------------|
| `admin` | Voller Zugriff |
| `write` | Lesen + Schreiben |
| `read` | Nur Lesen |
| `monitor` | Nur Metrics und Health |

#### Tokens verwenden

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:9470/api/query \
  -d '{"query": "SELECT * FROM users"}'
```

## Rate Limiting

Token-Bucket Rate Limiting verhindert Missbrauch:

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,      # 10K req/s global
  perClientRate = 1000,    # 1K req/s pro IP/Token
  burstSize = 100           # 100 req Burst erlauben
)

if not rl.allowRequest("client-ip"):
  return error("Rate limit exceeded")
```

## Netzwerksicherheit

### Bind-Adresse

Standardmäßig bindet BaraDB an `127.0.0.1` (nur Localhost). Für Production:

```bash
# An alle Interfaces binden (hinter Firewall oder Reverse Proxy)
BARADB_ADDRESS=0.0.0.0 ./build/baradadb

# An spezifisches internes Interface binden
BARADB_ADDRESS=10.0.0.5 ./build/baradadb
```

### Firewall-Regeln

```bash
# Nur Application-Server erlauben
sudo ufw allow from 10.0.0.0/8 to any port 9472
sudo ufw allow from 10.0.0.0/8 to any port 9470

# Externen Zugriff auf Management-Ports blockieren
sudo ufw deny 9471  # WebSocket (nur für internen Gebrauch)
```

## Datenverschlüsselung at Rest

### OS-Level-Verschlüsselung

LUKS für Vollständige-Festplatten-Verschlüsselung verwenden:

```bash
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 baradb-crypt
mkfs.ext4 /dev/mapper/baradb-crypt
mount /dev/mapper/baradb-crypt /var/lib/baradb
```

### Applikations-Level-Verschlüsselung

BaraDB unterstützt transparente Verschlüsselung von SSTable-Dateien:

```bash
BARADB_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
./build/baradadb
```

## Audit Logging

Alle Abfragen und administrativen Aktionen werden geloggt:

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

Audit Logging aktivieren:

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/audit.log \
./build/baradadb
```

## Sicherheits-Checkliste

- [ ] Standard-JWT-Geheimnis ändern
- [ ] TLS mit gültigen Zertifikaten aktivieren
- [ ] An spezifische Interfaces binden
- [ ] Authentifizierung in Production aktivieren
- [ ] Rate Limiting konfigurieren
- [ ] Audit Logging aktivieren
- [ ] Daten at Rest verschlüsseln (LUKS oder App-Level)
- [ ] BaraDB als Non-Root-Benutzer ausführen
- [ ] Firewall-Regeln restriktiv halten
- [ ] JWT-Geheimnisse regelmäßig rotieren
