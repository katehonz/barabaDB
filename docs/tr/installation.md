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
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

### macOS

```bash
brew install nim
```

### Windows

```powershell
winget install nim
```

## BaraDB Derleme

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
nimble install -d -y
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

## İlk Çalıştırma

```bash
./build/baradadb
curl http://localhost:9470/health
./build/baradadb --shell
```

## Sonraki Adımlar

- [Hızlı Başlangıç](quickstart.md)
- [Yapılandırma Referansı](configuration.md)
- [Mimari Genel Bakış](architecture.md)
- [BaraQL Sorgu Dili](baraql.md)