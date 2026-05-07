# Protokol Referansı

BaraDB istemci iletişimi için birden fazla protokol destekler:
- **Binary Wire Protocol** — yüksek performanslı, düşük gecikme
- **HTTP/REST API** — dil agnostik, kolay hata ayıklama
- **WebSocket** — akış ve pub/sub

## Binary Wire Protocol

Tüm çok baytlı değerler için big-endian kodlama kullanır.

### Bağlantı Döngüsü

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |─── Auth message ─────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
```

### Mesaj Formatı

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### Mesaj Türleri

| Tip | ID | Açıklama |
|-----|----|----------|
| Query | 0x01 | Sorgu çalıştır |
| Insert | 0x02 | Veri ekle |
| Update | 0x03 | Veri güncelle |
| Delete | 0x04 | Veri sil |
| Ready | 0x05 | Sonraki komut için hazır |
| Error | 0x06 | Hata yanıtı |

## HTTP/REST API

Base URL: `http://localhost:9470/api/v1`

### Uç Noktalar

#### Health

```http
GET /health
```

#### Sorgu

```http
POST /query
{
  "query": "SELECT * FROM users"
}
```

## WebSocket Protocol

URL: `ws://localhost:9471`