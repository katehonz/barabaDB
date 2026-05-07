# راهنمای امنیت

## رمزنگاری TLS/SSL

BaraDB از TLS 1.3 برای تمام پروتکل‌ها (باینری، HTTP، WebSocket) پشتیبانی می‌کند. اگر گواهی ارائه نشود، سرور در هنگام راه‌اندازی یک گواهی خودامضا تولید می‌کند.

### استفاده از گواهی‌های سفارشی

```bash
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### تولید گواهی‌های خودامضا

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

### Let's Encrypt (تولید)

از certbot استفاده کنید و BaraDB را به فایل‌های تولیدشده هدایت کنید:

```bash
sudo certbot certonly --standalone -d db.example.com

BARADB_CERT_FILE=/etc/letsencrypt/live/db.example.com/fullchain.pem \
BARADB_KEY_FILE=/etc/letsencrypt/live/db.example.com/privkey.pem \
./build/baradadb
```

## احراز هویت

### احراز هویت مبتنی بر JWT

BaraDB از JWT با امضای HMAC-SHA256 استفاده می‌کند.

#### فعال‌سازی احراز هویت

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

#### ایجاد توکن‌ها

```nim
import barabadb/protocol/auth

var am = newAuthManager("your-secret-key")
let token = am.createToken(JWTClaims(
  sub: "user1",
  role: "admin",
  exp: getTime() + 24.hours
))
```

#### کنترل دسترسی مبتنی بر نقش

| نقش | مجوزها |
|------|---------|
| `admin` | دسترسی کامل |
| `write` | خواندن + نوشتن |
| `read` | فقط خواندن |
| `monitor` | فقط معیارها و سلامت |

### احراز هویت چندعاملی (MFA)

```nim
import barabadb/protocol/auth

var am = newAuthManager("secret-key")
let mfaCode = am.generateTOTP("user1")
let valid = am.validateTOTP("user1", mfaCode)
```

## محدودیت نرخ

محدودیت نرخ token-bucket از سوءاستفاده جلوگیری می‌کند:

```nim
import barabadb/protocol/ratelimit

var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,
  perClientRate = 1000,
  burstSize = 100
)

if not rl.allowRequest("client-ip"):
  return error("محدودیت نرخ تجاوز شده")
```

## امنیت شبکه

### آدرس اتصال

به‌صورت پیش‌فرض BaraDB به `127.0.0.1` متصل می‌شود. برای تولید:

```bash
BARADB_ADDRESS=0.0.0.0 ./build/baradadb
```

## چک‌لیست امنیتی

- [ ] تغییر رمز JWT پیش‌فرض
- [ ] فعال‌سازی TLS با گواهی‌های معتبر
- [ ] اتصال به رابط‌های خاص
- [ ] فعال‌سازی احراز هویت در تولید
- [ ] پیکربندی محدودیت نرخ
- [ ] فعال‌سازی لاگ حسابرسی
- [ ] رمزنگاری داده در حالت سکون
- [ ] اجرای BaraDB به‌عنوان کاربر غیرroot
- [ ] محدود نگه‌داشتن قوانین فایروال
- [ ] چرخش منظم رمزهای JWT