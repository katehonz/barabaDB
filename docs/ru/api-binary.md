# API бинарного протокола

Низкоуровневый wire-протокол для высокопроизводительных клиентских соединений.

## Формат сообщения

Все сообщения используют порядок байтов big-endian:

```
┌────────┬────────┬────────┬────────┬─────────────┐
│ Length │  Type  │  Seq   │ Status │   Payload   │
│ 4 bytes│ 1 byte │ 2 bytes│ 1 byte │  N bytes    │
└────────┴────────┴────────┴────────┴─────────────┘
```

## Типы сообщений

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

## Коды ответов

| Код | Имя | Описание |
|-----|-----|---------|
| 0x00 | OK | Успех |
| 0x01 | ERROR | Общая ошибка |
| 0x02 | AUTH_REQUIRED | Требуется аутентификация |
| 0x03 | INVALID_QUERY | Синтаксическая ошибка запроса |
| 0x04 | NOT_FOUND | Ресурс не найден |

## Сериализация

```nim
import barabadb/protocol/wire

let bytes = serializeValue(Value(kind: vkString, strVal: "test"))
let value = deserializeValue(bytes)
```