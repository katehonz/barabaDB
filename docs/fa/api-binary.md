# API پروتکل باینری

پروتکل سطح پایین برای اتصالات با کارایی بالا.

## فرمت پیام

همه پیام‌ها از ترتیب big-endian استفاده می‌کنند:

```
┌────────┬────────┬────────┬────────┬─────────────┐
│ Length │  Type  │  Seq   │ Status │   Payload   │
│ 4 bytes│ 1 byte │ 2 bytes│ 1 byte │  N bytes    │
└────────┴────────┴────────┴────────┴─────────────┘
```

## انواع پیام

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

## کدهای پاسخ

| کد | نام | توضیح |
|----|-----|--------|
| 0x00 | OK | موفق |
| 0x01 | ERROR | خطای عمومی |
| 0x02 | AUTH_REQUIRED | نیاز به احراز هویت |
| 0x03 | INVALID_QUERY | خطای نحوی |
| 0x04 | NOT_FOUND | منبع یافت نشد |