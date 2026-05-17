# Protokoll-Referenz

BaraDB unterstützt mehrere Protokolle für Client-Kommunikation:
- **Binär Wire Protokoll** — hochperformant, niedrige Latenz
- **HTTP/REST API** — sprachunabhängig, einfach zu debuggen
- **WebSocket** — Streaming und Pub/Sub

---

## Binär Wire Protokoll

Das Binärprotokoll verwendet Big-Endian-Kodierung für alle Multi-Byte-Werte.

### Verbindungslebenszyklus

```
Client                          Server
  |                               |
  |─── TCP connect ──────────────>|
  |<── TLS handshake (optional) ──|
  |─── Auth message ─────────────>|
  |<── Auth_OK / Error ───────────|
  |─── Query message ────────────>|
  |<── Data / Complete / Error ───|
  |─── Close message ────────────>|
  |<── TCP close ─────────────────|
```

### Nachrichtenformat

Jede Nachricht beginnt mit einem 8-Byte-Header:

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Length     │  Type       │  Sequence   │  Payload            │
│  (4 bytes)  │  (1 byte)   │  (1 byte)   │  (Length - 6 bytes) │
│  uint32 BE  │  uint8      │  uint8      │                     │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

### Nachrichtentypen

| Typ | ID | Richtung | Beschreibung |
|------|----|-----------|-------------|
| Query | 0x01 | C→S | Abfrage ausführen |
| Insert | 0x02 | C→S | Daten einfügen |
| Update | 0x03 | C→S | Daten aktualisieren |
| Delete | 0x04 | C→S | Daten löschen |
| Ready | 0x05 | S→C | Bereit für nächsten Befehl |
| Error | 0x06 | S→C | Fehlerantwort |
| Auth | 0x07 | C→S | Authentifizierungsanfrage |
| Batch | 0x08 | C→S | Batch-Operationen |
| Ping | 0x09 | C→S | Keepalive Ping |
| Data | 0x81 | S→C | Abfrageergebnis-Daten |
| Complete | 0x82 | S→C | Abfrage abgeschlossen |
| Auth_OK | 0x83 | S→C | Authentifizierung erfolgreich |
| Pong | 0x84 | S→C | Keepalive-Antwort |

### Query-Nachrichten-Payload

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Result Format│ Query Length │ Query String               │
│ (1 byte)     │ (4 bytes)    │ (Query Length bytes)       │
│ 0x00=Binary │ uint32 BE    │ UTF-8                     │
│ 0x01=JSON   │              │                            │
│ 0x02=Text   │              │                            │
└──────────────┴──────────────┴────────────────────────────┘
```

### Data-Nachrichten-Payload

```
┌──────────────┬─────────────────────────────────────────────┐
│ Column Count │ Column Definitions + Row Data               │
│ (2 bytes)    │                                             │
│ uint16 BE    │                                             │
└──────────────┴─────────────────────────────────────────────┘
```

### Spaltendefinition

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Name Length  │ Name         │ Type                       │
│ (2 bytes)    │ (N bytes)    │ (1 byte)                   │
│ uint16 BE    │ UTF-8        │ Siehe FieldKind-Tabelle    │
└──────────────┴──────────────┴────────────────────────────┘
```

### Feldtypen

| Typ | ID | Größe | Beschreibung |
|------|----|------|-------------|
| NULL | 0x00 | 0 | NULL-Wert |
| BOOL | 0x01 | 1 | true/false |
| INT8 | 0x02 | 1 | Signed 8-bit Integer |
| INT16 | 0x03 | 2 | Signed 16-bit Integer |
| INT32 | 0x04 | 4 | Signed 32-bit Integer |
| INT64 | 0x05 | 8 | Signed 64-bit Integer |
| FLOAT32 | 0x06 | 4 | IEEE 754 Single Precision (Big-Endian) |
| FLOAT64 | 0x07 | 8 | IEEE 754 Double Precision (Big-Endian) |
| STRING | 0x08 | variable | UTF-8 String (4-Byte Längenpräfix) |
| BYTES | 0x09 | variable | Raw Bytes (4-Byte Längenpräfix) |
| ARRAY | 0x0A | variable | Array von Werten |
| OBJECT | 0x0B | variable | Key-Value Objekt |
| VECTOR | 0x0C | variable | Float32 Array (4-Byte Längenpräfix, Big-Endian Floats) |

### Fehler-Nachrichten-Payload

```
┌──────────────┬──────────────┬────────────────────────────┐
│ Error Code   │ Message Len  │ Error Message              │
│ (4 bytes)    │ (4 bytes)    │ (Message Len bytes)        │
│ uint32 BE    │ uint32 BE    │ UTF-8                     │
└──────────────┴──────────────┴────────────────────────────┘
```

### Beispiel: Raw TCP-Session

```bash
# Verbinden
nc localhost 9472

# Senden: Auth-Anfrage (Token "mytoken")
# Header: length=15, type=0x07, seq=1
# Payload: token length=7, token="mytoken"
printf '\x00\x00\x00\x0f\x07\x01\x00\x00\x00\x07mytoken' > /dev/tcp/localhost/9472

# Empfangen: Auth_OK
# \x00\x00\x00\x06\x83\x01

# Senden: Query "SELECT 1"
printf '\x00\x00\x00\x12\x01\x02\x00\x00\x00\x00\x08SELECT 1' > /dev/tcp/localhost/9472

# Empfangen: Data + Complete
```

---

## HTTP/REST API

Basis-URL: `http://localhost:9470/api/v1`

### Endpoints

#### Health

```http
GET /health
```

Antwort:
```json
{
  "status": "healthy",
  "version": "0.1.0",
  "uptime_seconds": 86400
}
```

#### Ready

```http
GET /ready
```

Gibt `200` zurück wenn bereit, `503` während des Starts.

#### Query

```http
POST /query
Content-Type: application/json
Authorization: Bearer <token>

{
  "query": "SELECT name, age FROM users WHERE age > 18",
  "params": [],
  "format": "json"
}
```

#### Batch

```http
POST /batch
Content-Type: application/json

{
  "queries": [
    "INSERT users { name := 'Alice', age := 30 }",
    "INSERT users { name := 'Bob', age := 25 }"
  ]
}
```

### HTTP-Statuscodes

| Code | Bedeutung |
|------|----------|
| 200 | Erfolg |
| 400 | Bad request (Syntaxfehler) |
| 401 | Unauthorized (Auth erforderlich) |
| 403 | Forbidden (ungenügende Berechtigungen) |
| 404 | Not found (Tabelle/Typ existiert nicht) |
| 429 | Too many requests (Rate limitiert) |
| 500 | Internal server error |
| 503 | Service unavailable (wird gestartet) |

---

## WebSocket-Protokoll

URL: `ws://localhost:9471`

### Frame-Format

WebSocket Text-Frames enthalten JSON-Nachrichten:

```json
{
  "id": 1,
  "type": "query",
  "query": "SELECT * FROM users"
}
```

### Nachrichtentypen

| Typ | Richtung | Beschreibung |
|------|-----------|--------------|
| `query` | C→S | Abfrage ausführen |
| `subscribe` | C→S | Änderungen abonnieren |
| `unsubscribe` | C→S | Abonnement beenden |
| `ping` | C→S | Keepalive |
| `result` | S→C | Abfrageergebnis |
| `notification` | S→C | Änderungsbenachrichtigung |
| `error` | S→C | Fehler |
| `pong` | S→C | Keepalive-Antwort |
