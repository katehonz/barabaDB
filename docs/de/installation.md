# BaraDB — Installation

## Voraussetzungen

- **Nim >= 2.2.0** (`curl https://nim-lang.org/choosenim/init.sh -sSf | sh`)
- **Git**
- **OpenSSL** (für TLS)

## Aus dem Quellcode bauen

```bash
git clone https://github.com/katehonz/barabaDB.git
cd barabadb
nimble build_release
```

Die Binärdateien werden im `build/` Verzeichnis erstellt:
- `build/baradadb` — Datenbank-Server (TCP + HTTP)
- `build/baramcp` — MCP Server für AI-Agenten

## Debug-Build

```bash
nimble build_debug
```

## Tests ausführen

```bash
nimble test
```

## Docker

```bash
docker compose up -d
```

## Verifizierung

```bash
./build/baradadb --version
# BaraDB v1.1.6 — Multimodal Database Engine

./build/baramcp --data-dir ./data &
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./build/baramcp
```

## Manuelle Kompilierung

```bash
# Server
nim c -d:release --opt:speed -o:build/baradadb src/baradadb.nim

# MCP Server
nim c -d:release --opt:speed -o:build/baramcp src/baramcp.nim
```
