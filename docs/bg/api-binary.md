# API за Бинарен Протокол

Ниско-нивов wire протокол за високопроизводителни клиентски връзки.

## Формат на Съобщенията

Всички съобщения използват big-endian byte order:

```
┌─────────────┬─────────────┬─────────────┬─────────────────────┐
│  Kind        │  Length     │  RequestId  │  Payload            │
│  (4 bytes)   │  (4 bytes)  │  (4 bytes)  │                     │
│  uint32 BE   │  uint32 BE  │  uint32 BE  │  (Length bytes)     │
└─────────────┴─────────────┴─────────────┴─────────────────────┘
```

## Типове Съобщения

### Query (0x01)

```nim
let msg = makeQueryMessage(requestId, "SELECT * FROM users")
```

### QueryParams (0x02)

```nim
let msg = makeQueryParamsMessage(requestId, "SELECT * FROM users WHERE name = ?", params)
```

### Auth (0x07)

```nim
let msg = makeAuthMessage(requestId, token)
```

### Ping (0x09)

```nim
let msg = makePingMessage(requestId)
```

### Close (0x0A)

```nim
let msg = makeCloseMessage(requestId)
```

## Отговорни Съобщения

### Ready (0x05)

```nim
let msg = makeReadyMessage(requestId)
```

### Error (0x06)

```nim
let msg = makeErrorMessage(requestId, code, message)
```

### Data (0x81)

```nim
# Съдържа резултатите от заявката с колони и редове
```

### Complete (0x82)

```nim
# Потвърждава завършване на заявката
```

### Auth_OK (0x83)

```nim
# Потвърждава успешна автентикация
```

### Pong (0x84)

```nim
# Keepalive отговор
```

## Кодове за Грешки

| Код | Име | Описание |
|------|-----|----------|
| 0x00 | OK | Успех |
| 0x01 | ERROR | Обща грешка |
| 0x02 | AUTH_REQUIRED | Изисква се автентикация |
| 0x03 | INVALID_QUERY | Синтактична грешка в заявката |
| 0x04 | NOT_FOUND | Ресурсът не е намерен |

## Сериализация

```nim
import barabadb/protocol/wire

# Сериализиране на стойност
let bytes = serializeValue(Value(kind: vkString, strVal: "test"))

# Десериализиране на стойност
let value = deserializeValue(bytes)
```
