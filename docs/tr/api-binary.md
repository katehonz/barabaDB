# İkili Protokol API

Yüksek performanslı istemci bağlantıları için düşük seviyeli wire protokolü.

## Mesaj Formatı

Tüm mesajlar big-endian bayt sırası kullanır:

```
┌────────┬────────┬────────┬────────┬─────────────┐
│ Length │  Type  │  Seq   │ Status │   Payload   │
│ 4 bytes│ 1 byte │ 2 bytes│ 1 byte │  N bytes    │
└────────┴────────┴────────┴────────┴─────────────┘
```

## Mesaj Türleri

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

## Yanıt Kodları

| Kod | Ad | Açıklama |
|-----|-----|----------|
| 0x00 | OK | Başarılı |
| 0x01 | ERROR | Genel hata |
| 0x02 | AUTH_REQUIRED | Kimlik doğrulama gerekli |
| 0x03 | INVALID_QUERY | Sözdizimi hatası |
| 0x04 | NOT_FOUND | Kaynak bulunamadı |