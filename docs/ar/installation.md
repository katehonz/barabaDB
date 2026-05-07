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
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

### macOS

```bash
brew install nim
```

### ويندوز

```powershell
winget install nim
```

## بناء BaraDB

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
nimble install -d -y
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

## التشغيل الأول

```bash
./build/baradadb
curl http://localhost:9470/health
./build/baradadb --shell
```

## الخطوات التالية

- [دليل البداية السريعة](quickstart.md)
- [مرجع التكوين](configuration.md)
- [نظرة عامة على البنية](architecture.md)
- [لغة استعلام BaraQL](baraql.md)