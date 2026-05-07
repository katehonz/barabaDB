# 二进制协议 API

用于高性能客户端连接的低级 wire 协议。

## 消息格式

所有消息使用大端字节序：

```
┌────────┬────────┬────────┬────────┬─────────────┐
│ Length │  Type  │  Seq   │ Status │   Payload   │
│ 4 bytes│ 1 byte │ 2 bytes│ 1 byte │  N bytes    │
└────────┴────────┴────────┴────────┴─────────────┘
```

## 消息类型

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

## 响应码

| 代码 | 名称 | 描述 |
|------|------|------|
| 0x00 | OK | 成功 |
| 0x01 | ERROR | 一般错误 |
| 0x02 | AUTH_REQUIRED | 需要认证 |
| 0x03 | INVALID_QUERY | 查询语法错误 |
| 0x04 | NOT_FOUND | 资源未找到 |