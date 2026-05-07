# عیب‌یابی

## مشکلات نصب

### Nim یافت نشد

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

### خطای کامپایل SSL

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### وابستگی‌های گم‌شده

```bash
nimble install -d -y
```

## مشکلات زمان اجرا

### پورت در حال استفاده

```bash
BARADB_PORT=5433 ./build/baradadb
```

### Permission denied

```bash
mkdir -p ./data
chmod 755 ./data
```

### کمبود حافظه

```bash
BARADB_MEMTABLE_SIZE_MB=32 \
BARADB_CACHE_SIZE_MB=128 \
./build/baradadb
```

## مشکلات کوئری

### خطای نحوی

```sql
SELECT name, age FROM users WHERE age > 18;
```

### جدول یافت نشد

```sql
CREATE TYPE User { name: str, age: int32 };
```

### عدم تطابق نوع

```sql
SELECT * FROM users WHERE age > 18;
```

## مشکلات اتصال

### Connection refused

```bash
./build/baradadb
sudo ufw allow 9472
```

## مشکلات عملکرد

### کوئری‌های کند

1. ایجاد اندیس: `CREATE INDEX idx_users_name ON users(name);`
2. استفاده از LIMIT
3. افزایش کش: `BARADB_CACHE_SIZE_MB=1024`

## حالت اشکال‌زدایی

```bash
BARADB_LOG_LEVEL=debug ./build/baradadb
```