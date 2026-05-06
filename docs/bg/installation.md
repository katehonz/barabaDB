# BaraDB - Ръководство за Инсталация

## Изисквания

- **Nim Компилатор** >= 2.0.0
- **Операционна система**: Linux, macOS, Windows

## Инсталиране на Nim

### Linux/macOS

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

Или чрез пакетен мениджър:

```bash
# Ubuntu/Debian
apt-get install nim

# macOS
brew install nim
```

### Windows

Изтеглете инсталатора от [nim-lang.org](https://nim-lang.org/install.html) или използвайте winget:

```powershell
winget install nim
```

## Компилиране на BaraDB

### Клониране на Репозиторито

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
```

### Компилиране

```bash
# Debug компилация
nim c -o:build/baradadb src/baradadb.nim

# Release компилация (оптимизирана)
nim c -d:release -o:build/baradadb src/baradadb.nim
```

### Стартиране на Тестове

```bash
nim c --path:src -r tests/test_all.nim
```

### Стартиране на Бенчмаркове

```bash
nim c -d:release -r benchmarks/bench_all.nim
```

## Опции за Инсталация

### Docker

```bash
docker pull barabadb/barabadb
docker run -it barabadb/barabadb
```

### Вградено Използване

Добавете към вашия `.nimble` файл:

```nim
requires "barabadb >= 1.0.0"
```

След това импортнете в кода:

```nim
import barabadb

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
db.close()
```

## Следващи Стъпки

- [Бързо Стартиране](bg/quickstart.md)
- [Архитектура](bg/architecture.md)
- [BaraQL Заявки](bg/baraql.md)