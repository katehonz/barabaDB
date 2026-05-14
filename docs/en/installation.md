# BaraDB - Installation Guide

## Requirements

- **Nim Compiler** >= 2.2.0
- **OpenSSL** development headers (for TLS support)
- **Operating System**: Linux, macOS, Windows

### Supported Platforms

| OS | Architecture | Status |
|----|--------------|--------|
| Linux | x86_64 | ✅ Fully supported |
| Linux | ARM64 | ✅ Fully supported |
| macOS | x86_64 | ✅ Fully supported |
| macOS | ARM64 (Apple Silicon) | ✅ Fully supported |
| Windows | x86_64 | ✅ Supported |
| FreeBSD | x86_64 | 🟡 Community tested |

## Installing Nim

### Linux

```bash
# Official installer
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

### Verify Installation

```bash
nim --version
# Expected: Nim Compiler Version 2.2.0 or later
```

## Installing OpenSSL

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

OpenSSL is included with the system. If needed:

```bash
brew install openssl
```

### Windows

OpenSSL is bundled with the Nim Windows distribution. For manual builds,
download from [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html).

## Building BaraDB

### Clone the Repository

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabaDB
```

### Install Dependencies

```bash
nimble install -d -y
```

### Build Options

#### Debug Build

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

#### Release Build (Recommended)

```bash
nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim
```

#### Using Nimble Tasks

```bash
# Debug build
nimble build_debug

# Release build
nimble build_release
```

#### Strip Binary (Minimal Size)

```bash
nim c -d:ssl -d:release --opt:size -o:build/baradadb src/baradadb.nim
strip build/baradadb
```

### Verify Build

```bash
./build/baradadb --version
# Expected: BaraDB v1.1.0 — Multimodal Database Engine
```

## Running Tests

### All Tests

```bash
nim c -d:ssl -r tests/test_all.nim
```

### Specific Test Suites

```bash
# Storage tests
nim c -d:ssl -r tests/test_storage.nim

# Query engine tests
nim c -d:ssl -r tests/test_query.nim

# Protocol tests
nim c -d:ssl -r tests/test_protocol.nim
```

### Benchmarks

```bash
nim c -d:ssl -d:release -r benchmarks/bench_all.nim
```

## Installation Options

### System-Wide Installation

```bash
# Build release binary
nimble build_release

# Install to /usr/local/bin
sudo cp build/baradadb /usr/local/bin/
sudo chmod +x /usr/local/bin/baradadb

# Create data directory
sudo mkdir -p /var/lib/baradb
sudo chmod 755 /var/lib/baradb
```

### Pre-built Binary

Download the latest release for your platform:

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
# Pull official image
docker pull barabadb/barabadb:latest

# Run
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

### Embedded Usage (Nim Projects)

Add to your `.nimble` file:

```nim
requires "barabadb >= 0.1.0"
```

Use in your code:

```nim
import barabadb/storage/lsm

var db = newLSMTree("./data")
db.put("key", cast[seq[byte]]("value"))
let (found, val) = db.get("key")
db.close()
```

## First Run

```bash
# Start server
./build/baradadb

# Expected output:
# BaraDB v1.1.0 — Multimodal Database Engine
# BaraDB TCP listening on 127.0.0.1:9472

# Test with HTTP API
curl http://localhost:9470/health

# Interactive shell
./build/baradadb --shell
```

## Troubleshooting Installation

### "cannot open file: hunos"

```bash
nimble install -d -y
```

### "BaraDB requires SSL support"

Always compile with `-d:ssl`:

```bash
nim c -d:ssl -o:build/baradadb src/baradadb.nim
```

### Slow compilation

Use parallel compilation:

```bash
nim c -d:ssl -d:release --parallelBuild:4 -o:build/baradadb src/baradadb.nim
```

### Large binary size

Use size optimization:

```bash
nim c -d:ssl -d:release --opt:size --passL:-s -o:build/baradadb src/baradadb.nim
```

## Next Steps

- [Quick Start Guide](quickstart.md)
- [Configuration Reference](configuration.md)
- [Architecture Overview](architecture.md)
- [BaraQL Query Language](baraql.md)
