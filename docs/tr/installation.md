# BaraDB - Kurulum Rehberi

## Gereksinimler

- **Nim Derleyici** >= 2.2.0
- **OpenSSL** geliştirme başlıkları (TLS desteği için)
- **İşletim Sistemi**: Linux, macOS, Windows

### Desteklenen Platformlar

| OS | Mimari | Durum |
|----|--------|-------|
| Linux | x86_64 | ✅ Tam destek |
| Linux | ARM64 | ✅ Tam destek |
| macOS | x86_64 | ✅ Tam destek |
| macOS | ARM64 (Apple Silicon) | ✅ Tam destek |
| Windows | x86_64 | ✅ Destekleniyor |
| FreeBSD | x86_64 | 🟡 Topluluk testli |

## Nim Kurulumu

### Linux

```bash
# Resmi kurulum scripti
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

### Windows

```powershell
# choosenim ile
curl.exe -A "MSYS2_$(uname -m)" -L https://nim-lang.org/choosenim/init.ps1 | powershell -

# winget ile
winget install nim

# scoop ile
scoop install nim
```

### Kurulumu Doğrulama

```bash
nim --version
# Beklenen: Nim Compiler Version 2.2.0 veya daha yeni
```

## OpenSSL Kurulumu

### Linux

```bash
# Ubuntu/Debian
sudo apt-get install libssl-dev

# Fedora
sudo dnf install openssl-devel

# Arch Linux
sudo pacman -S openssl
```

### macOS

OpenSSL sistemle birlikte gelir. Gerekirse:

```bash
brew install openssl
```

### Windows

OpenSSL, Nim Windows dağıtımıyla birlikte gelir. Manuel derlemeler için [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html) adresinden indirin.

## BaraDB Derleme

### Depoyu Klonlama

```bash
git clone https://codeberg.org/baraba/baradb
cd barabaDB
```

### Bağımlılıkları Kurma

```bash
nimble install -d -y
```

### Derleme Seçenekleri

#### Debug Derleme

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### Release Derleme (Önerilen)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### Nimble Tasks Kullanma

```bash
# Debug derleme
nimble build_debug

# Release derleme
nimble build_release
```

#### Binary Boyutunu Küçültme

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### Derlemeyi Doğrulama

```bash
./build/baradadb --version
# Beklenen: BaraDB v1.1.0 — Multimodal Database Engine
```

## Testleri Çalıştırma

### Tüm Testler

```bash
nim c -d:ssl -r tests/test_all.nim
```

### Belirli Test Süitleri

```bash
# Depolama testleri
nim c -d:ssl -r tests/test_storage.nim

# Sorgu motoru testleri
nim c -d:ssl -r tests/test_query.nim

# Protokol testleri
nim c -d:ssl -r tests/test_protocol.nim
```

### Benchmarklar

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Kurulum Seçenekleri

### Sistem Geneli Kurulum

```bash
# Release binary derle
nimble build_release

# /usr/local/bin'e kur
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# Veri dizini oluştur
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### Ön Derlenmiş Binary

En son sürümü platformunuz için indirin:

```bash
# Linux x86_64
wget https://github.com/katehonz/barabaDB/releases/latest/download/baradadb-linux-amd64
chmod +x baradadb-linux-amd64
mv baradadb-linux-amd64 /usr/local/bin/baradadb

# Linux ARM64
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
# Resmi image'i çek
docker pull barabadb/barabadb:latest

# Çalıştır
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

### Gömülü Kullanım (Nim Projeleri)

`.nimble` dosyanıza ekleyin:

```nim
requires "barabadb >= 1.1.0"
```

Kodunuzda kullanın:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## İlk Çalıştırma

```bash
# Sunucuyu başlat
./build/baradadb

# Beklenen çıktı:
# BaraDB v1.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# HTTP API ile test et
curl http://localhost:9470/health

# İnteraktif shell
./build/baradadb --shell
```

## Kurulum Sorunlarını Giderme

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

Her zaman `-d:ssl` ile derleyin:

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

### Yavaş derleme

Paralel derleme kullanın:

```bash
nim c -d:ssl -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### Büyük binary boyutu

Boyut optimizasyonu kullanın:

```bash
nim c -d:ssl -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## Sonraki Adımlar

- [Hızlı Başlangıç](quickstart.md)
- [Yapılandırma Referansı](configuration.md)
- [Mimari Genel Bakış](architecture.md)
- [BaraQL Sorgu Dili](baraql.md)