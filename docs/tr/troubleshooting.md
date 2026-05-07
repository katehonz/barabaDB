# Sorun Giderme Rehberi

## Kurulum Sorunları

### Nim Bulunamadı

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

### SSL Derleme Hatası

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### Eksik Bağımlılıklar

```bash
nimble install -d -y
```

## Çalışma Zamanı Sorunları

### Port Zaten Kullanımda

```bash
BARADB_PORT=5433 ./build/baradadb
```

### İzin Reddedildi

```bash
mkdir -p ./data
chmod 755 ./data
```

### Yetersiz Bellek

```bash
BARADB_MEMTABLE_SIZE_MB=32 \
BARADB_CACHE_SIZE_MB=128 \
./build/baradadb
```

## Sorgu Sorunları

### Sözdizimi Hatası

```sql
SELECT name, age FROM users WHERE age > 18;
```

### Tablo Bulunamadı

```sql
CREATE TYPE User { name: str, age: int32 };
```

## Bağlantı Sorunları

### Bağlantı Reddedildi

```bash
./build/baradadb
sudo ufw allow 9472
```

## Performans Sorunları

### Yavaş Sorgular

1. İndeks ekleyin: `CREATE INDEX idx_users_name ON users(name);`
2. LIMIT kullanın
3. Önbelleği artırın: `BARADB_CACHE_SIZE_MB=1024`

## Hata Ayıklama Modu

```bash
BARADB_LOG_LEVEL=debug ./build/baradadb
```