# BaraDB - Руководство по установке

## Требования

- **Компилятор Nim** >= 2.2.0
- **Заголовочные файлы OpenSSL** (для поддержки TLS)
- **Операционная система**: Linux, macOS, Windows

### Поддерживаемые платформы

| ОС | Архитектура | Статус |
|----|--------------|--------|
| Linux | x86_64 | ✅ Полная поддержка |
| Linux | ARM64 | ✅ Полная поддержка |
| macOS | x86_64 | ✅ Полная поддержка |
| macOS | ARM64 (Apple Silicon) | ✅ Полная поддержка |
| Windows | x86_64 | ✅ Поддерживается |
| FreeBSD | x86_64 | 🟡 Тестировалось сообществом |

## Установка Nim

### Linux

```bash
# Официальный установщик
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
# Using choosenim
curl.exe -A "MSYS2_$(uname -m)" -L https://nim-lang.org/choosenim/init.ps1 | powershell -

# Using winget
winget install nim

# Using scoop
scoop install nim
```

### Проверка установки

```bash
nim --version
# Ожидается: Nim Compiler Version 2.2.0 или выше
```

## Установка OpenSSL

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

OpenSSL уже включён в систему. При необходимости:

```bash
brew install openssl
```

### Windows

OpenSSL поставляется вместе с Nim для Windows. Для ручной сборки,
скачайте с [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html).

## Сборка BaraDB

### Клонирование репозитория

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
```

### Установка зависимостей

```bash
nimble install -d -y
```

### Варианты сборки

#### Отладочная сборка

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### Релизная сборка (Рекомендуется)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### Использование Nimble Tasks

```bash
# Отладочная сборка
nimble build_debug

# Релизная сборка
nimble build_release
```

#### Уменьшение размера бинарника

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### Проверка сборки

```bash
./build/baradadb --version
# Ожидается: BaraDB v0.1.0 — Multimodal Database Engine
```

## Запуск тестов

### Все тесты

```bash
nim c -d:ssl -r tests/test_all.nim
```

### Конкретные наборы тестов

```bash
# Тесты хранилища
nim c -d:ssl -r tests/test_storage.nim

# Тесты движка запросов
nim c -d:ssl -r tests/test_query.nim

# Тесты протокола
nim c -d:ssl -r tests/test_protocol.nim
```

### Бенчмарки

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Варианты установки

### Системная установка

```bash
# Собираем релизный бинарник
nimble build_release

# Устанавливаем в /usr/local/bin
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# Создаём директорию для данных
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### Предварительно собранный бинарник

Скачайте последний релиз для вашей платформы:

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
# Скачать официальный образ
docker pull barabadb/barabadb:latest

# Запустить
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

### Встраиваемое использование (Nim проекты)

Добавьте в ваш файл `.nimble`:

```nim
requires "barabadb >= 0.1.0"
```

Используйте в коде:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## Первый запуск

```bash
# Запуск сервера
./build/baradadb

# Ожидаемый вывод:
# BaraDB v0.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# Проверка через HTTP API
curl http://localhost:9470/health

# Интерактивная оболочка
./build/baradadb --shell
```

## Устранение проблем при установке

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

Всегда компилируйте с `-d:ssl`:

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

### Медленная компиляция

Используйте параллельную компиляцию:

```bash
nim c -d:ssl -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### Большой размер бинарника

Используйте оптимизацию размера:

```bash
nim c -d:ssl -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## Следующие шаги

- [Руководство по быстрому старту](quickstart.md)
- [Справочник по конфигурации](configuration.md)
- [Обзор архитектуры](architecture.md)
- [Язык запросов BaraQL](baraql.md)