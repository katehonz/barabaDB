# Fehlerbehebungsleitfaden

## Installationsprobleme

### Nim nicht gefunden

```
im: command not found
```

**Lösung:**

```bash
# Linux/macOS
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Zu PATH hinzufügen
echo 'export PATH=$HOME/.nimble/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### SSL-Kompilierungsfehler

```
Error: BaraDB requires SSL support. Compile with -d:ssl
```

**Lösung:** Immer mit `-d:ssl` kompilieren:

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### Fehlende Abhängigkeiten

```
Error: cannot open file: hunos
```

**Lösung:**

```bash
nimble install -d -y
```

## Laufzeitprobleme

### Port bereits in Verwendung

```
Error: unhandled exception: Address already in use [OSError]
```

**Lösung 1:** Port ändern:

```bash
BARADB_PORT=5433 ./build/baradadb
```

**Lösung 2:** Bestehenden Prozess beenden:

```bash
lsof -ti:9472 | xargs kill -9
# oder
fuser -k 9472/tcp
```

### Permission Denied auf Datenverzeichnis

```
Error: cannot create directory: Permission denied
```

**Lösung:**

```bash
mkdir -p ./data
chmod 755 ./data
# Oder anderes Verzeichnis verwenden
BARADB_DATA_DIR=/tmp/baradb_data ./build/baradadb
```

### Out of Memory

```
Error: out of memory
```

**Lösung:** Speicherverbrauch reduzieren:

```bash
BARADB_MEMTABLE_SIZE_MB=32 \
BARADB_CACHE_SIZE_MB=128 \
BARADB_VECTOR_EF_CONSTRUCTION=100 \
./build/baradadb
```

### Disk Full

```
Error: No space left on device
```

**Lösung:**

```bash
# Disk-Nutzung prüfen
df -h

# Compaction auslösen um Platz freizugeben
curl -X POST http://localhost:9470/api/admin/compact

# Oder manuell
./build/baradadb --compact
```

## Abfrageprobleme

### Syntaxfehler

```
Error: Syntax error at position 15: unexpected token
```

**Lösung:** Abfragesyntax prüfen:

```sql
-- Korrekt
SELECT name, age FROM users WHERE age > 18;

-- Inkorrekt (fehlendes Komma)
SELECT name age FROM users WHERE age > 18;
```

### Tabelle nicht gefunden

```
Error: Table 'users' does not exist
```

**Lösung:** Zuerst Schema erstellen:

```sql
CREATE TYPE User {
  name: str,
  age: int32
};
```

### Typ-Mismatch

```
Error: Cannot compare int32 with str
```

**Lösung:** Korrekte Typen verwenden:

```sql
-- Korrekt
SELECT * FROM users WHERE age > 18;

-- Inkorrekt
SELECT * FROM users WHERE age > '18';
```

### Timeout

```
Error: Query execution timeout
```

**Lösung:** LIMIT hinzufügen oder optimieren:

```sql
-- Limit hinzufügen
SELECT * FROM large_table LIMIT 1000;

-- Index verwenden
SELECT * FROM users WHERE id = 123;
```

## Verbindungsprobleme

### Connection Refused

```
Connection refused: localhost:9472
```

**Lösung:**

```bash
# Prüfen ob Server läuft
ps aux | grep baradadb

# Server starten
./build/baradadb

# Firewall prüfen
sudo ufw status
sudo ufw allow 9472
```

### Authentifizierung fehlgeschlagen

```
Error: Authentication failed
```

**Lösung:**

```bash
# Prüfen ob JWT-Geheimnis übereinstimmt
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="correct-secret" \
./build/baradadb
```

## Performance-Probleme

### Langsame Abfragen

**Diagnose:**

```bash
# Abfrageplan prüfen
curl -X POST http://localhost:9470/api/explain \
  -d '{"query": "SELECT * FROM large_table"}'
```

**Lösungen:**

1. Indizes hinzufügen:
```sql
CREATE INDEX idx_users_name ON users(name);
```

2. LIMIT verwenden:
```sql
SELECT * FROM users LIMIT 100;
```

3. Cache erhöhen:
```bash
BARADB_CACHE_SIZE_MB=1024 ./build/baradadb
```

### Hohe CPU-Nutzung

**Ursachen:**
- Compaction läuft
- Große Vektor-Suche ohne HNSW
- Komplexe Graph-Traversierung

**Lösungen:**

```bash
# Compaction-Intervall anpassen
BARADB_COMPACTION_INTERVAL_MS=300000 ./build/baradadb

# Approximative Vektor-Suche verwenden
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

## Cluster-Probleme

### Raft Split-Brain

```
Warning: Multiple leaders detected
```

**Lösung:** Ungerade Anzahl von Knoten sicherstellen (3, 5, 7). Minority-Partition neu starten.

### Replikations-Lag

```
Warning: Replication lag > 10s
```

**Lösung:**

```bash
# Netzwerk-Latenz prüfen
ping replica-node

# Replikations-Threads erhöhen
BARADB_REPLICATION_THREADS=4 ./build/baradadb

# Auf Async-Replikation umschalten
BARADB_REPLICATION_MODE=async
```

## Datenkorruption

### Prüfsummen-Mismatch

```
Error: SSTable checksum mismatch
```

**Lösung:**

```bash
# Korrupte SSTable entfernen (Daten werden aus WAL wiederhergestellt)
rm ./data/sstables/corrupted.sst

# Neustarten und wiederherstellen
./build/baradadb --recover
```

## Debug-Modus

Debug-Logging für detaillierte Diagnostik aktivieren:

```bash
BARADB_LOG_LEVEL=debug \
BARADB_LOG_FILE=/tmp/baradb_debug.log \
./build/baradadb
```

## Hilfe erhalten

Wenn das Problem weiterhin besteht:

1. Logs prüfen: `tail -f /var/log/baradb/baradb.log`
2. Metrics prüfen: `curl http://localhost:9470/metrics`
3. Diagnostik ausführen: `./build/baradadb --diagnose`
4. Issue öffnen mit:
   - BaraDB Version (`./build/baradadb --version`)
   - OS und Architektur
   - Relevante Log-Auszüge
   - Schritte zur Reproduktion
