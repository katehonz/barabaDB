# دليل الأمان

## تشفير TLS/SSL

تدعم BaraDB TLS 1.3 لجميع البروتوكولات. إذا لم يتم توفير شهادة، ينشئ الخادم شهادة ذاتية التوقيع تلقائياً عند البدء.

### استخدام شهادات مخصصة

```bash
BARADB_TLS_ENABLED=true \
BARADB_CERT_FILE=/etc/baradb/server.crt \
BARADB_KEY_FILE=/etc/baradb/server.key \
./build/baradadb
```

### إنشاء شهادة ذاتية التوقيع

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

## المصادقة

### المصادقة المبنية على JWT

تستخدم BaraDB JWT مع توقيع HMAC-SHA256.

### تمكين المصادقة

```bash
BARADB_AUTH_ENABLED=true \
BARADB_JWT_SECRET="$(openssl rand -hex 32)" \
./build/baradadb
```

### التحكم في الوصول القائم على الأدوار

| الدور | الأذونات |
|-------|----------|
| `admin` | وصول كامل |
| `write` | قراءة + كتابة |
| `read` | قراءة فقط |
| `monitor` | المقاييس والصحة فقط |

## تحديد المعدل

منع إساءة الاستخدام:

```nim
var rl = newRateLimiter(
  rlaTokenBucket,
  globalRate = 10000,
  perClientRate = 1000,
  burstSize = 100
)
```

## أمان الشبكة

### عنوان الربط

```bash
BARADB_ADDRESS=0.0.0.0 ./build/baradadb
```

## قائمة التحقق الأمنية

- [ ] تغيير سر JWT الافتراضي
- [ ] تمكين TLS بشهادات صالحة
- [ ] الربط بواجهات محددة
- [ ] تمكين المصادقة في الإنتاج
- [ ] تكوين تحديد المعدل
- [ ] تمكين سجل التدقيق
- [ ] تشفير البيانات في حالة السكون
- [ ] تشغيل BaraDB كمستخدم غير root