# BaraDB - Installation Guide

## Requirements

- **Nim Compiler** >= 2.0.0
- **Operating System**: Linux, macOS, Windows

## Installing Nim

### Linux/macOS

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

Or via package manager:

```bash
# Ubuntu/Debian
apt-get install nim

# macOS
brew install nim
```

### Windows

Download the installer from [nim-lang.org](https://nim-lang.org/install.html) or use winget:

```powershell
winget install nim
```

## Building BaraDB

### Clone the Repository

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
```

### Build the Project

```bash
# Debug build
nim c -o:build/baradadb src/baradadb.nim

# Release build (optimized)
nim c -d:release -o:build/baradadb src/baradadb.nim
```

### Run Tests

```bash
nim c --path:src -r tests/test_all.nim
```

### Run Benchmarks

```bash
nim c -d:release -r benchmarks/bench_all.nim
```

## Installation Options

### Pre-built Binary

Download the latest release from the [GitHub Releases](https://github.com/katehonz/barabaDB/releases) page.

### Docker

```bash
docker pull barabadb/barabadb
docker run -it barabadb/barabadb
```

### Embedded Usage

Add to your `.nimble` file:

```nim
requires "barabadb >= 1.0.0"
```

Then import in your code:

```nim
import barabadb

var db = newLSMTree("./data")
db.put("key1", cast[seq[byte]]("value1"))
db.close()
```

## Verifying Installation

```bash
./build/baradadb --version
```

Expected output:

```
BaraDB v1.0.0
multimodal database engine
```

## Next Steps

- [Quick Start Guide](en/quickstart.md)
- [Architecture Overview](en/architecture.md)
- [BaraQL Query Language](en/baraql.md)