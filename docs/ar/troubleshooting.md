# دليل حل المشكلات

## مشاكل التثبيت

### Nim غير موجود

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

### خطأ تجميع SSL

```bash
nim c -d:ssl -d:release -o:build/baradadb src/baradadb.nim
```

### تبعيات مفقودة

```bash
nimble install -d -y
```

## مشاكل وقت التشغيل

### المنفذ قيد الاستخدام

```bash
BARADB_PORT=5433 ./build/baradadb
```

### تم رفض الإذن

```bash
mkdir -p ./data
chmod 755 ./data
```

### ذاكرة غير كافية

```bash
BARADB_MEMTABLE_SIZE_MB=32 \
BARADB_CACHE_SIZE_MB=128 \
./build/baradadb
```

## مشاكل الاستعلام

### خطأ في الصياغة

```sql
SELECT name, age FROM users WHERE age > 18;
```

### الجدول غير موجود

```sql
CREATE TYPE User { name: str, age: int32 };
```

## مشاكل الاتصال

### تم رفض الاتصال

```bash
./build/baradadb
sudo ufw allow 9472
```

## مشاكل الأداء

### استعلامات بطيئة

1. إضافة فهارس: `CREATE INDEX idx_users_name ON users(name);`
2. استخدام LIMIT
3. زيادة ذاكرة التخزين المؤقت: `BARADB_CACHE_SIZE_MB=1024`

## وضع التصحيح

```bash
BARADB_LOG_LEVEL=debug ./build/baradadb
```