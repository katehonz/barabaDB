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
# Winget
winget install nim

# Scoop
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

```bash
brew install openssl
```

## Компилиране на BaraDB

### Клониране на Репозиторито

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
```

### Инсталиране на Зависимости

```bash
nimble install -d -y
```

### Опции за Компилация

#### Debug Компилация

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### Release Компилация (Препоръчителна)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### Използване на Nimble

```bash
nimble build_debug
nimble build_release
```

#### Минимален Размер

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### Проверка на Компилацията

```bash
./build/baradadb --version
# Очакван резултат: BaraDB v0.1.0 — Multimodal Database Engine
```

## Стартиране на Тестове

```bash
# Всички тестове (262 теста, 56 сюита)
nim c -d:ssl -r tests/test_all.nim

# Бенчмаркове
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Опции за Инсталация

### Системна Инсталация

```bash
nimble build_release
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb
sudo mkdir -p /var/lib/baradb
```

### Docker

```bash
docker pull barabadb/barabadb:latest
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

### Вградено Използване

```nim
requires "barabadb >= 0.1.0"
```

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

# Тестване на HTTP API
curl http://localhost:9470/health

# Интерактивна конзола
./build/baradadb --shell
```

## Следващи Стъпки

- [Бързо Стартиране](bg/quickstart.md)
- [Конфигурация](en/configuration.md)
- [Архитектура](bg/architecture.md)
- [BaraQL Заявки](bg/baraql.md)
