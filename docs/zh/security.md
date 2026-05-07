# 安全指南

## TLS/SSL 加密

BaraDB 支持所有协议的 TLS 1.3（二进制、HTTP、WebSocket）。如果未提供证书，服务器会在启动时自动生成自签名证书以实现零配置加密。

### 使用自定义证书

```bash
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### 生成自签名证书

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

### Let's Encrypt（生产环境）

使用 certbot 并将 BaraDB 指向生成的文件：

```bash
sudo certbot certonly --standalone -d db.example.com

BARADB_CERT_FILE=/etc/letsencrypt/live/db.example.com/fullchain.pem \
BARADB_KEY_FILE=/etc/letsencrypt/live/db.example.com/privkey.pem \
./build/baradadb
```

### 客户端 TLS

```python
from baradb import Client

client = Client("localhost", 9472, tls=True, tls_verify=True)
client.connect()
```

## 认证

### 基于 JWT 的认证

BaraDB 使用 HMAC-SHA256 签名的 JWT。

#### 启用认证

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

#### 创建令牌

```nim
import barabadb/protocol/auth

var am = newAuthManager("your-secret-key")
let token = am.createToken(JWTClaims(
  sub: "user1",
  role: "admin",
  exp: getTime() + 24.hours
))
```

#### 基于角色的访问控制

| 角色 | 权限 |
|------|------|
| `admin` | 完全访问 |
| `write` | 读取 + 写入 |
| `read` | 只读 |
| `monitor` | 仅指标和健康检查 |

#### 使用令牌

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

### 多因素认证 (MFA)

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
let mfaCode = am.generateTOTP("user1")
let valid = am.validateTOTP("user1", mfaCode)
```

## 限流

Token-bucket 限流防止滥用：

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,
  perClientRate = 1000,
  burstSize = 100
)

if not rl.allowRequest("client-ip"):
  return error("超出限流")
```

## 网络安全

### 绑定地址

默认 BaraDB 绑定到 `127.0.0.1`（仅本地）。生产环境：

```bash
BARADB_ADDRESS=0.0.0.0 ./build/baradadb
```

### 防火墙规则

```bash
sudo ufw allow from 10.0.0.0/8 to any port 9472
sudo ufw allow from 10.0.0.0/8 to any port 9470
sudo ufw deny 9471
```

## 静态数据加密

### 操作系统级加密

使用 LUKS 进行全磁盘加密：

```bash
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 baradb-crypt
mkfs.ext4 /dev/mapper/baradb-crypt
mount /dev/mapper/baradb-crypt /var/lib/baradb
```

### 应用级加密

```bash
BARADB_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
./build/baradadb
```

## 审计日志

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

## 安全检查清单

- [ ] 更改默认 JWT 密钥
- [ ] 使用有效证书启用 TLS
- [ ] 绑定到特定接口
- [ ] 生产环境启用认证
- [ ] 配置限流
- [ ] 启用审计日志
- [ ] 静态数据加密
- [ ] 以非 root 用户运行
- [ ] 保持防火墙规则严格
- [ ] 定期轮换 JWT 密钥