# API البروتوكول الثنائي

بروتوكول سلكي منخفض المستوى لاتصالات العميل عالية الأداء.

## تنسيق الرسالة

جميع الرسائل تستخدم ترتيب big-endian:

```
┌────────┬────────┬────────┬────────┬─────────────┐
│ Length │  Type  │  Seq   │ Status │   Payload   │
│ 4 bytes│ 1 byte │ 2 bytes│ 1 byte │  N bytes    │
└────────┴────────┴────────┴────────┴─────────────┘
```

## أنواع الرسائل

### Query (0x01)

```nim
let msg = makeQueryMessage(seq, "SELECT * FROM users")
```

### Insert (0x02)

```nim
let msg = makeInsertMessage(seq, "users", data)
```

### Update (0x03)

```nim
let msg = makeUpdateMessage(seq, "users", updates, where)
```

### Delete (0x04)

```nim
let msg = makeDeleteMessage(seq, "users", where)
```

### Ready (0x05)

```nim
let msg = makeReadyMessage(seq)
```

### Error (0x06)

```nim
let msg = makeErrorMessage(seq, code, message)
```

## رموز الاستجابة

| الرمز | الاسم | الوصف |
|-------|-------|-------|
| 0x00 | OK | نجاح |
| 0x01 | ERROR | خطأ عام |
| 0x02 | AUTH_REQUIRED | مطلوب مصادقة |
| 0x03 | INVALID_QUERY | خطأ في بناء الجملة |
| 0x04 | NOT_FOUND | المورد غير موجود |