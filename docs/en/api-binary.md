# Binary Protocol API

Low-level wire protocol for high-performance client connections.

## Message Format

All messages use big-endian byte order:

```
┌────────┬────────┬────────┬────────┬─────────────┐
│ Length │  Type  │  Seq   │ Status │   Payload   │
│ 4 bytes│ 1 byte │ 2 bytes│ 1 byte │  N bytes    │
└────────┴────────┴────────┴────────┴─────────────┘
```

## Message Types

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

## Response Codes

| Code | Name | Description |
|------|------|-------------|
| 0x00 | OK | Success |
| 0x01 | ERROR | General error |
| 0x02 | AUTH_REQUIRED | Authentication needed |
| 0x03 | INVALID_QUERY | Query syntax error |
| 0x04 | NOT_FOUND | Resource not found |

## Serialization

```nim
import barabadb/protocol/wire

# Serialize value
let bytes = serializeValue(Value(kind: vkString, strVal: "test"))

# Deserialize value
let value = deserializeValue(bytes)
```