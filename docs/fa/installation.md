# راهنمای نصب BaraDB

## الزامات

- **کامپایلر Nim** >= 2.2.0
- **فایل‌های هدر OpenSSL** (برای پشتیبانی TLS)
- **سیستم‌عامل**: لینوکس، macOS، ویندوز

### پلتفرم‌های پشتیبانی‌شده

| سیستم‌عامل | معماری | وضعیت |
|------------|--------|--------|
| لینوکس | x86_64 | ✅ پشتیبانی کامل |
| لینوکس | ARM64 | ✅ پشتیبانی کامل |
| macOS | x86_64 | ✅ پشتیبانی کامل |
| macOS | ARM64 (Apple Silicon) | ✅ پشتیبانی کامل |
| ویندوز | x86_64 | ✅ پشتیبانی‌شده |
| FreeBSD | x86_64 | 🟡 تست‌شده توسط جامعه |

## نصب Nim

### لینوکس

```bash
# نصب‌کننده رسمی
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install nim

# Fedora
sudo dnf install nim

# Arch Linux
sudo pacman -S nim
```

### macOS

```bash
# Homebrew
brew install nim

# MacPorts
sudo port install nim
```

### ویندوز

```powershell
# Using choosenim
curl.exe -A "MSYS2_$(uname -m)" -L https://nim-lang.org/choosenim/init.ps1 | powershell -

# Using winget
winget install nim

# Using scoop
scoop install nim
```

### تأیید نصب

```bash
nim --version
# انتظار: Nim Compiler Version 2.2.0 یا بالاتر
```

## نصب OpenSSL

### لینوکس

```bash
# Ubuntu/Debian
sudo apt-get install libssl-dev

# Fedora
sudo dnf install openssl-devel

# Arch Linux
sudo pacman -S openssl
```

### macOS

OpenSSL همراه سیستم است. در صورت نیاز:

```bash
brew install openssl
```

### ویندوز

OpenSSL همراه توزیع ویندوز Nim است. برای ساخت دستی،
از [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html) دانلود کنید.

## ساخت BaraDB

### کلون کردن مخزن

```bash
git clone https://codeberg.org/baraba/baradb
cd barabaDB
```

### نصب وابستگی‌ها

```bash
nimble install -d -y
```

### گزینه‌های ساخت

#### ساخت دیباگ

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### ساخت ریلیز (توصیه‌شده)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### استفاده از Nimble Tasks

```bash
# ساخت دیباگ
nimble build_debug

# ساخت ریلیز
nimble build_release
```

#### کاهش حجم باینری

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### تأیید ساخت

```bash
./build/baradadb --version
# انتظار: BaraDB v1.1.0 — Multimodal Database Engine
```

## اجرای تست‌ها

### همه تست‌ها

```bash
nim c -d:ssl -r tests/test_all.nim
```

### مجموعه‌های تست خاص

```bash
# تست‌های ذخیره‌سازی
nim c -d:ssl -r tests/test_storage.nim

# تست‌های موتور پرس‌وجو
nim c -d:ssl -r tests/test_query.nim

# تست‌های پروتکل
nim c -d:ssl -r tests/test_protocol.nim
```

### بنچمارک‌ها

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## گزینه‌های نصب

### نصب سیستمی

```bash
# ساخت باینری ریلیز
nimble build_release

# نصب در /usr/local/bin
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# ایجاد پوشه داده
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### باینری از پیش ساخته‌شده

آخرین ریلیز را برای پلتفرم خود دانلود کنید:

```bash
# لینوکس x86_64
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-amd64
chmod +x baradadb-linux-amd64
mv baradadb-linux-amd64 /usr/local/bin/baradadb

# لینوکس ARM64
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-arm64
chmod +x baradadb-linux-arm64
mv baradadb-linux-arm64 /usr/local/bin/baradadb

# macOS
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-darwin-amd64
chmod +x baradadb-darwin-amd64
mv baradadb-darwin-amd64 /usr/local/bin/baradadb
```

### Docker

```bash
# دریافت ایمیج رسمی
docker pull barabadb/barabadb:latest

# اجرا
docker run -d \
  -p 9472:9472 \
  -p 9470:9470 \
  -p 9471:9471 \
  -v baradb_data:/data \
  barabadb/barabadb
```

### Docker Compose

```bash
docker-compose up -d
```

### استفاده توکار (پروژه‌های Nim)

به فایل `.nimble` خود اضافه کنید:

```nim
requires "barabadb >= 0.1.0"
```

در کد خود استفاده کنید:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## اجرای اولیه

```bash
# شروع سرور
./build/baradadb

# خروجی مورد انتظار:
# BaraDB v1.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# تست با HTTP API
curl http://localhost:9470/health

# شل تعاملی
./build/baradadb --shell
```

## عیب‌یابی نصب

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

همیشه با `-d:ssl` کامپایل کنید:

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

### کامپایل کند

از کامپایل موازی استفاده کنید:

```bash
nim c -d:ssl -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### حجم باینری زیاد

از بهینه‌سازی اندازه استفاده کنید:

```bash
nim c -d:ssl -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## مراحل بعدی

- [راهنمای شروع سریع](quickstart.md)
- [مرجع پیکربندی](configuration.md)
- [بررسی معماری](architecture.md)
- [زبان پرس‌وجو BaraQL](baraql.md)