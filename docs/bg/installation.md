# BaraDB - Ръководство за Инсталация

## Изисквания

- **Nim Компилатор** >= 2.2.0
- **OpenSSL** development headers (за TLS поддръжка)
- **Операционна система**: Linux, macOS, Windows

### Поддържани Платформи

| ОС | Архитектура | Статус |
|----|-------------|--------|
| Linux | x86_64 | ✅ Пълна поддръжка |
| Linux | ARM64 | ✅ Пълна поддръжка |
| macOS | x86_64 | ✅ Пълна поддръжка |
| macOS | ARM64 (Apple Silicon) | ✅ Пълна поддръжка |
| Windows | x86_64 | ✅ Поддръжка |
| FreeBSD | x86_64 | 🟡 Тествано от общността |

## Инсталиране на Nim

### Linux

```bash
# Официален инсталатор
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
# С choosenim
curl.exe -A "MSYS2_$(uname -m)" -L https://nim-lang.org/choosenim/init.ps1 | powershell -

# С winget
winget install nim

# С scoop
scoop install nim
```

### Проверка

```bash
nim --version
# Очакван резултат: Nim Compiler Version 2.2.0 или по-нова
```

## Инсталиране на OpenSSL

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

OpenSSL е включен в системата. Ако е необходимо:

```bash
brew install openssl
```

### Windows

OpenSSL е включен в Nim Windows дистрибуцията. За ръчни компилации, изтеглете от [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html).

## Компилиране на BaraDB

### Клониране на Репозиторито

```bash
git clone https://codeberg.org/baraba/baradb
cd barabaDB
```

### Инсталиране на Зависимости

```bash
nimble install -d -y
```

### Опции за Компилация

#### Debug Компилация

```bash
nim c -d:ssl --threads:on -o:build/baradadb src/baradadb.nim
```

#### Release Компилация (Препоръчителна)

```bash
nim c -d:ssl --threads:on -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### Използване на Nimble Tasks

```bash
# Debug компилация
nimble build_debug

# Release компилация
nimble build_release
```

#### Минимален Размер

```bash
nim c -d:ssl --threads:on -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### Проверка на Компилацията

```bash
./build/baradadb --version
# Очакван резултат: BaraDB v1.1.0 — Multimodal Database Engine
```

## Стартиране на Тестове

### Всички Тестове

```bash
nim c --path:src -d:ssl --threads:on -r tests/test_all.nim
```

### Специфични Тестови Сюити

```bash
# Storage тестове
nim c --path:src -d:ssl --threads:on -r tests/test_all.nim

# Stress тестове
nim c --path:src -d:ssl --threads:on -d:release -r tests/stress_test.nim
```

### Бенчмаркове

```bash
nim c --path:src -d:ssl --threads:on -d:release -r benchmarks/bench_all.nim
```

## Опции за Инсталация

### Системна Инсталация

```bash
# Компилиране на release binary
nimble build_release

# Инсталиране в /usr/local/bin
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# Създаване на директория за данни
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### Предварително Компилиран Binary

Изтеглете най-новата версия за вашата платформа:

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
# Изтегляне на официален образ
docker pull barabadb/barabadb:latest

# Стартиране
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

### Вградено Използване (Nim Проекти)

Добавете към вашия `.nimble` файл:

```nim
requires "barabadb >= 1.1.0"
```

Използване в кода:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## Първо Стартиране

```bash
# Стартиране на сървъра
./build/baradadb

# Очакван изход:
# BaraDB v1.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# Тестване с HTTP API
curl http://localhost:9470/health

# Интерактивна обвивка
./build/baradadb --shell
```

## Отстраняване на Проблеми с Инсталацията

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

Винаги компилирайте с `-d:ssl`:

```bash
nim c -d:ssl --threads:on -o:build/baradadb src/baradadb.nim
```

### Бавна компилация

Използвайте паралелна компилация:

```bash
nim c -d:ssl --threads:on -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### Голям размер на binary-то

Използвайте оптимизация на размера:

```bash
nim c -d:ssl --threads:on -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## Следващи Стъпки

- [Бърз Старт](quickstart.md)
- [Конфигурационна Референция](configuration.md)
- [Преглед на Архитектурата](architecture.md)
- [BaraQL Език за Заявки](baraql.md)
