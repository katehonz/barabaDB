# Troubleshooting Guide

## Installation Issues

### Nim Not Found

```
im: command not found
```

**Solution:**

```bash
# Linux/macOS
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Add to PATH
echo 'export PATH=$HOME/.nimble/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### SSL Compilation Error

```
Error: BaraDB requires SSL support. Compile with -d:ssl
```

**Solution:** Always compile with `-d:ssl`:

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### Missing Dependencies

```
Error: cannot open file: hunos
```

**Solution:**

```bash
nimble install -d -y
```

## Runtime Issues

### Port Already in Use

```
Error: unhandled exception: Address already in use [OSError]
```

**Solution 1:** Change port:

```bash
BARADB_PORT=5433 ./build/baradadb
```

**Solution 2:** Kill existing process:

```bash
lsof -ti:9472 | xargs kill -9
# or
fuser -k 9472/tcp
```

### Permission Denied on Data Directory

```
Error: cannot create directory: Permission denied
```

**Solution:**

```bash
mkdir -p ./data
chmod 755 ./data
# Or use a different directory
BARADB_DATA_DIR=/tmp/baradb_data ./build/baradadb
```

### Out of Memory

```
Error: out of memory
```

**Solution:** Reduce memory usage:

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

**Solution:**

```bash
# Check disk usage
df -h

# Trigger compaction to reclaim space
curl -X POST http://localhost:9470/api/admin/compact

# Or manually
./build/baradadb --compact
```

## Query Issues

### Syntax Error

```
Error: Syntax error at position 15: unexpected token
```

**Solution:** Check query syntax:

```sql
-- Correct
SELECT name, age FROM users WHERE age > 18;

-- Incorrect (missing comma)
SELECT name age FROM users WHERE age > 18;
```

### Table Not Found

```
Error: Table 'users' does not exist
```

**Solution:** Create the schema first:

```sql
CREATE TYPE User {
  name: str,
  age: int32
};
```

### Type Mismatch

```
Error: Cannot compare int32 with str
```

**Solution:** Use correct types:

```sql
-- Correct
SELECT * FROM users WHERE age > 18;

-- Incorrect
SELECT * FROM users WHERE age > '18';
```

### Timeout

```
Error: Query execution timeout
```

**Solution:** Add LIMIT or optimize:

```sql
-- Add limit
SELECT * FROM large_table LIMIT 1000;

-- Use index
SELECT * FROM users WHERE id = 123;
```

## Connection Issues

### Connection Refused

```
Connection refused: localhost:9472
```

**Solution:**

```bash
# Check if server is running
ps aux | grep baradadb

# Start server
./build/baradadb

# Check firewall
sudo ufw status
sudo ufw allow 9472
```

### Authentication Failed

```
Error: Authentication failed
```

**Solution:**

```bash
# Check JWT secret matches
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="correct-secret" \
./build/baradadb
```

```python
client.authenticate("correct-jwt-token")
```

### SSL/TLS Errors

```
Error: TLS handshake failed
```

**Solution:**

```bash
# Disable TLS for local testing
BARADB_TLS_ENABLED=false ./build/baradadb

# Or provide valid certificates
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/path/to/cert.pem \
BARADB_KEY_FILE=/path/to/key.pem \
./build/baradadb
```

## Performance Issues

### Slow Queries

**Diagnose:**

```bash
# Check query plan
curl -X POST http://localhost:9470/api/explain \
  -d '{"query": "SELECT * FROM large_table"}'
```

**Solutions:**

1. Add indexes:
```sql
CREATE INDEX idx_users_name ON users(name);
```

2. Use LIMIT:
```sql
SELECT * FROM users LIMIT 100;
```

3. Increase cache:
```bash
BARADB_CACHE_SIZE_MB=1024 ./build/baradadb
```

### High CPU Usage

**Causes:**
- Compaction running
- Large vector search without HNSW
- Complex graph traversal

**Solutions:**

```bash
# Adjust compaction interval
BARADB_COMPACTION_INTERVAL_MS=300000 ./build/baradadb

# Use approximate vector search
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

### High Memory Usage

**Monitor:**

```bash
curl http://localhost:9470/metrics | grep memory
```

**Solutions:**

```bash
# Reduce memtable size
BARADB_MEMTABLE_SIZE_MB=64

# Reduce cache
BARADB_CACHE_SIZE_MB=256

# Limit HNSW graph size
BARADB_VECTOR_M=8
```

## Cluster Issues

### Raft Split-Brain

```
Warning: Multiple leaders detected
```

**Solution:** Ensure odd number of nodes (3, 5, 7). Restart minority partition.

### Replication Lag

```
Warning: Replication lag > 10s
```

**Solution:**

```bash
# Check network latency
ping replica-node

# Increase replication threads
BARADB_REPLICATION_THREADS=4 ./build/baradadb

# Switch to async replication
BARADB_REPLICATION_MODE=async
```

### Shard Imbalance

```
Warning: Shard 3 has 2× data of others
```

**Solution:**

```bash
# Trigger rebalancing
curl -X POST http://localhost:9470/api/admin/rebalance
```

## Data Corruption

### Checksum Mismatch

```
Error: SSTable checksum mismatch
```

**Solution:**

```bash
# Remove corrupted SSTable (data will be recovered from WAL)
rm ./data/sstables/corrupted.sst

# Restart and recover
./build/baradadb --recover
```

### WAL Corruption

```
Error: WAL segment corrupted
```

**Solution:**

```bash
# Truncate WAL to last good segment
./build/baradadb --truncate-wal --wal-sequence=15419

# Restore from snapshot if needed
./build/baradadb --recover --checkpoint=/backup/snapshot.db
```

## Debug Mode

Enable debug logging for detailed diagnostics:

```bash
BARADB_LOG_LEVEL=debug \
BARADB_LOG_FILE=/tmp/baradb_debug.log \
./build/baradadb
```

## Getting Help

If the issue persists:

1. Check logs: `tail -f /var/log/baradb/baradb.log`
2. Check metrics: `curl http://localhost:9470/metrics`
3. Run diagnostics: `./build/baradadb --diagnose`
4. Open an issue with:
   - BaraDB version (`./build/baradadb --version`)
   - OS and architecture
   - Relevant log excerpts
   - Steps to reproduce
