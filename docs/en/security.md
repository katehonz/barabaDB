# Security Guide

## TLS/SSL Encryption

BaraDB supports TLS 1.3 for all protocols (binary, HTTP, WebSocket). If no
certificate is provided, the server auto-generates a self-signed certificate
on startup for zero-configuration encryption.

### Using Custom Certificates

```bash
# Provide existing certificates
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### Generating Self-Signed Certificates

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

### Let's Encrypt (Production)

Use certbot and point BaraDB to the generated files:

```bash
sudo certbot certonly --standalone -d db.example.com

BARADB_CERT_FILE=/etc/letsencrypt/live/db.example.com/fullchain.pem \
BARADB_KEY_FILE=/etc/letsencrypt/live/db.example.com/privkey.pem \
./build/baradadb
```

### Client-Side TLS

```python
from baradb import Client

client = Client("localhost", 5432, tls=True, tls_verify=True)
client.connect()
```

## Authentication

### JWT-Based Authentication

BaraDB uses JWT (JSON Web Tokens) with HMAC-SHA256 signing.

#### Enabling Authentication

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

#### Creating Tokens

```nim
import barabadb/protocol/auth

var am = newAuthManager("your-secret-key")
let token = am.createToken(JWTClaims(
  sub: "user1",
  role: "admin",
  exp: getTime() + 24.hours
))
```

#### Role-Based Access Control

| Role | Permissions |
|------|-------------|
| `admin` | Full access |
| `write` | Read + write |
| `read` | Read-only |
| `monitor` | Metrics and health only |

#### Using Tokens

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/query \
  -d '{"query": "SELECT * FROM users"}'
```

```python
from baradb import Client

client = Client("localhost", 5432)
client.connect()
client.authenticate("eyJhbGciOiJIUzI1NiIs...")
```

### Multi-Factor Authentication (MFA)

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
# TOTP-based MFA
let mfaCode = am.generateTOTP("user1")
let valid = am.validateTOTP("user1", mfaCode)
```

## Rate Limiting

Token-bucket rate limiting prevents abuse:

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,      # 10K req/s globally
  perClientRate = 1000,    # 1K req/s per IP/token
  burstSize = 100          # Allow 100 req burst
)

if not rl.allowRequest("client-ip"):
  return error("Rate limit exceeded")
```

## Network Security

### Bind Address

By default BaraDB binds to `127.0.0.1` (localhost only). For production:

```bash
# Bind to all interfaces (behind a firewall or reverse proxy)
BARADB_ADDRESS=0.0.0.0 ./build/baradadb

# Bind to specific internal interface
BARADB_ADDRESS=10.0.0.5 ./build/baradadb
```

### Firewall Rules

```bash
# Allow only application servers
sudo ufw allow from 10.0.0.0/8 to any port 5432
sudo ufw allow from 10.0.0.0/8 to any port 8080

# Block external access to management ports
sudo ufw deny 8081  # WebSocket (internal use only)
```

## Data Encryption at Rest

### OS-Level Encryption

Use LUKS for full-disk encryption:

```bash
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 baradb-crypt
mkfs.ext4 /dev/mapper/baradb-crypt
mount /dev/mapper/baradb-crypt /var/lib/baradb
```

### Application-Level Encryption

BaraDB supports transparent encryption of SSTable files:

```bash
BARADB_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
./build/baradadb
```

## Audit Logging

All queries and administrative actions are logged:

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

Enable audit logging:

```bash
BARADB_LOG_LEVEL=info \
BARADB_LOG_FORMAT=json \
BARADB_LOG_FILE=/var/log/baradb/audit.log \
./build/baradadb
```

## Security Checklist

- [ ] Change default JWT secret
- [ ] Enable TLS with valid certificates
- [ ] Bind to specific interfaces
- [ ] Enable authentication in production
- [ ] Configure rate limiting
- [ ] Enable audit logging
- [ ] Encrypt data at rest (LUKS or app-level)
- [ ] Run BaraDB as non-root user
- [ ] Keep firewall rules restrictive
- [ ] Rotate JWT secrets regularly
