# دليل تثبيت BaraDB

## المتطلبات

- **مترجم Nim** >= 2.2.0
- **ملفات رأس OpenSSL** (لدعم TLS)
- **نظام التشغيل**: لينكس، macOS، ويندوز

### المنصات المدعومة

| نظام التشغيل | البنية | الحالة |
|-------------|--------|--------|
| لينكس | x86_64 | ✅ دعم كامل |
| لينكس | ARM64 | ✅ دعم كامل |
| macOS | x86_64 | ✅ دعم كامل |
| macOS | ARM64 | ✅ دعم كامل |
| ويندوز | x86_64 | ✅ مدعوم |
| FreeBSD | x86_64 | 🟡 اختبار المجتمع |

## تثبيت Nim

### لينكس

```bash
# المثبت الرسمي
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

### ويندوز

```powershell
# باستخدام choosenim
curl.exe -A "MSYS2_$(uname -m)" -L https://nim-lang.org/choosenim/init.ps1 | powershell -

# باستخدام winget
winget install nim

# باستخدام scoop
scoop install nim
```

### التحقق من التثبيت

```bash
nim --version
# المتوقع: Nim Compiler Version 2.2.0 أو أحدث
```

## تثبيت OpenSSL

### لينكس

```bash
# Ubuntu/Debian
sudo apt-get install libssl-dev

# Fedora
sudo dnf install openssl-devel

# Arch Linux
sudo pacman -S openssl
```

### macOS

OpenSSL مضمن مع النظام. إذا لزم الأمر:

```bash
brew install openssl
```

### ويندوز

OpenSSL مضمن مع توزيع Nim ويندوز. للبناء اليدوي، قم بالتنزيل من [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html).

## بناء BaraDB

### استنساخ المستودع

```bash
git clone https://codeberg.org/baraba/bara-lang
cd barabaDB
```

### تثبيت التبعيات

```bash
nimble install -d -y
```

### خيارات البناء

#### بناء التصحيح

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### بناء الإصدار (موصى به)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### استخدام مهام Nimble

```bash
# بناء التصحيح
nimble build_debug

# بناء الإصدار
nimble build_release
```

#### تقليل حجم الملف الثنائي

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### التحقق من البناء

```bash
./build/baradadb --version
# المتوقع: BaraDB v1.1.0 — Multimodal Database Engine
```

## تشغيل الاختبارات

### جميع الاختبارات

```bash
nim c -d:ssl -r tests/test_all.nim
```

### مجموعات اختبارات محددة

```bash
# اختبارات التخزين
nim c -d:ssl -r tests/test_storage.nim

# اختبارات محرك الاستعلام
nim c -d:ssl -r tests/test_query.nim

# اختبارات البروتوكول
nim c -d:ssl -r tests/test_protocol.nim
```

### المعايير

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## خيارات التثبيت

### التثبيت على مستوى النظام

```bash
# بناء إصدار RELEASE
nimble build_release

# التثبيت في /usr/local/bin
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# إنشاء دليل البيانات
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### الملف الثنائي المبنى مسبقًا

قم بتنزيل أحدث إصدار لمنصتك:

```bash
# لينكس x86_64
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-amd64
chmod +x baradadb-linux-amd64
mv baradadb-linux-amd64 /usr/local/bin/baradadb

# لينكس ARM64
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
# سحب الصورة الرسمية
docker pull barabadb/barabadb:latest

# التشغيل
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

### الاستخدام المدمج (مشاريع Nim)

أضف إلى ملف `.nimble` الخاص بك:

```nim
requires "barabadb >= 1.1.0"
```

استخدم في الكود:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## التشغيل الأول

```bash
# بدء الخادم
./build/baradadb

# المخرجات المتوقعة:
# BaraDB v1.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# الاختبار عبر HTTP API
curl http://localhost:9470/health

# الصدفة التفاعلية
./build/baradadb --shell
```

## حل مشكلات التثبيت

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

قم دائمًا بالبناء باستخدام `-d:ssl`:

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

### البناء البطيء

استخدم البناء المتوازي:

```bash
nim c -d:ssl -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### حجم الملف الثنائي الكبير

استخدم تحسين الحجم:

```bash
nim c -d:ssl -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## الخطوات التالية

- [دليل البداية السريعة](quickstart.md)
- [مرجع التكوين](configuration.md)
- [نظرة عامة على البنية](architecture.md)
- [لغة استعلام BaraQL](baraql.md)