# Design: A Good Nim Client for BaraDB

**Date:** 2026-06-18  
**Status:** Approved (approach B)  
**Scope:** `clients/nim` and `clients/nim-allographer`

## 1. Goal

Turn the existing Nim client code into a production-grade, easy-to-use client for BaraDB with:

- A single source of truth for the binary wire protocol.
- Async + sync APIs that are safe under concurrent use.
- Connection pooling, timeouts, TLS, and reconnect support.
- Typed values (not only strings) for vectors, JSON, bytes, etc.
- Clean integration with `nim-allographer` so the Laravel-style query builder keeps working.
- Good unit and integration test coverage without requiring a live server for every test.

## 2. Current State

- `clients/nim` (`baradb` nimble package) is a self-contained, stdlib-only async/sync client. It duplicates the wire protocol to avoid depending on the server source.
- `clients/nim-allographer` is a fork of `itsumura-h/nim-allographer`. It copy-pastes the same client into `src/allographer/query_builder/libs/baradb/baradb_client.nim` and adds a connection pool, query builder integration, migrations, and prepared-statement helpers.
- `src/barabadb/client/client.nim` is an incomplete embedded client bundled with the server and should not be used by applications.
- The Python, JavaScript, and Rust clients already have internal request queues so that concurrent operations on one TCP connection do not interleave frames on the wire. The Nim clients do not.
- The Nim clients convert every `WireValue` to `string`, which loses type information for vectors, JSON, bytes, arrays, and objects.
- `timeoutMs` and `maxRetries` exist in `ClientConfig` but are not honored.

## 3. Design Principles

1. **Canonical low-level package.** `clients/nim` owns the wire protocol, socket handling, typed values, request serialization, pooling, TLS, and timeouts.
2. **Thin allographer wrapper.** `clients/nim-allographer` imports the canonical package and only adds allographer-specific glue (types, `dbOpen`, query builder, migrations, transactions).
3. **No new runtime dependencies for the standalone client.** It must stay stdlib-only so it can be used in embedded and restricted environments.
4. **Backward compatibility.** Existing `dbOpen(Baradb, ...)` code and the `.table(...).get()` API must keep compiling and behaving the same way.
5. **Fail fast, diagnose clearly.** Distinguish I/O errors, protocol framing errors, server errors, auth errors, and pool timeouts.

## 4. Architecture

```
┌─────────────────────────────────────────┐
│  clients/nim-allographer                │
│  - allographer query builder / schema   │
│  - BaradbConnections pool wrapper       │
│  - migration helpers                    │
│  - thin re-export of baradb/client      │
└──────────────┬──────────────────────────┘
               │ requires "baradb >= 1.2.0"
┌──────────────▼──────────────────────────┐
│  clients/nim (canonical package)        │
│  - wire.nim      (protocol constants)   │
│  - client.nim    (async/sync client)    │
│  - pool.nim      (async connection pool)│
│  - http.nim      (optional HTTP client) │
│  - errors.nim    (exception hierarchy)  │
└─────────────────────────────────────────┘
```

### 4.1 Files in `clients/nim/src/baradb/`

| File | Responsibility |
|------|----------------|
| `wire.nim` | `FieldKind`, `MsgKind`, `WireValue`, serialize/deserialize, `buildMessage`. |
| `client.nim` | `BaraClient`, `SyncClient`, `ClientConfig`, `QueryResult`, query/exec/auth/ping/close. |
| `pool.nim` | `BaraPool`, `PooledClient`, `withClient` template, pool stats, idle/lifetime eviction. |
| `http.nim` | Optional `BaraHttpClient` that posts queries to the HTTP/REST endpoint. |
| `errors.nim` | `BaraError`, `BaraProtocolError`, `BaraServerError`, `BaraAuthError`, `BaraPoolTimeoutError`. |

### 4.2 Files in `clients/nim-allographer/src/allographer/query_builder/libs/baradb/`

| File | Responsibility |
|------|----------------|
| `baradb_client.nim` | Re-exports needed types from `baradb/client` and keeps only allographer-specific helpers (migration SQL builders). The wire code is removed. |
| `baradb_types.nim` | Keeps `BaradbConnections`, `BaradbQuery`, pool bookkeeping, but references `BaraClient` from the canonical package. |
| `baradb_open.nim` | `dbOpen` constructors; may create either a `BaraPool` or keep the current simple pool, depending on migration step. |
| `baradb_exec.nim` / `baradb_query.nim` / `baradb_transaction.nim` | Unchanged API surface; internally use the canonical client. |

## 5. Low-Level Client Improvements

### 5.1 Typed `WireValue` rows

`QueryResult` gains a typed view:

```nim
type
  QueryResult* = object
    columns*: seq[string]
    columnTypes*: seq[FieldKind]
    rows*: seq[seq[string]]          # legacy string view
    typedRows*: seq[seq[WireValue]]  # new typed view
    rowCount*: int
    affectedRows*: int
    executionTimeMs*: float64
    lastInsertId*: int64
```

`wireValueToString` stays for backward compatibility. `typedRows` is populated during deserialization and lets callers inspect vectors, JSON, bytes, etc., without string parsing.

### 5.2 Per-connection request queue

A single `BaraClient` must be safe when multiple async fibers call `query`/`exec` on it. Add an internal queue:

```nim
type
  BaraClient* = ref object
    config: ClientConfig
    socket: AsyncSocket
    connected: bool
    requestId: uint32
    sendLock: AsyncLock            # or a Future chain queue
    pending: Deque[PendingRequest]
```

Design choice: **serialize sends and reads per connection**. This matches the Python/JS clients and is simple to reason about. It is not pipelining; it is request/response queueing. If higher throughput is needed later, add pipelining on top of the pool.

### 5.3 Connection pool

`BaraPool` is an async pool with:

- `minConnections`, `maxConnections`
- `maxIdleTime`, `maxLifetime`
- `connectTimeout`, `queryTimeout`
- `withClient` template / proc that borrows a connection, runs an async callback, and returns it
- `stats(): (total, idle, inUse)`
- Eviction of expired/stale connections
- Health check via `ping` before lending

The sync API gets a matching `SyncPool` that uses a blocking socket and a `Lock`.

### 5.4 TLS

`ClientConfig` gets optional TLS fields:

```nim
  ClientConfig* = object
    host*: string
    port*: int
    database*: string
    username*: string
    password*: string
    timeoutMs*: int
    maxRetries*: int
    ssl*: bool
    sslContext*: SslContext       # optional, user-supplied
```

If `ssl` is true and no `sslContext` is supplied, the client creates a default `net.newContext()` and wraps the socket. TLS uses Nim's stdlib `net`/`asyncnet` OpenSSL wrappers. The standalone client remains stdlib-only at the Nim level, but the host must provide the OpenSSL system libraries.

### 5.5 Timeouts and reconnect

- `connect` honors `timeoutMs` via `asyncdispatch.withTimeout`.
- `recv` is wrapped with `withTimeout` using `timeoutMs`.
- If a send/recv fails with `ECONNRESET` or a timeout and `maxRetries > 0`, the client closes the socket, reconnects, and retries the request once. Retries are not attempted for server-side errors (`mkError`).

### 5.6 Batch and transactions

The protocol defines `mkBatch` and `mkTransaction`, but their server-side semantics are not stable enough in the current codebase. The client will expose:

```nim
proc batch*(client: BaraClient, queries: seq[string]): Future[seq[QueryResult]]
proc transaction*(client: BaraClient, body: proc(): Future[void]): Future[void]
```

The first implementation will use explicit SQL `BEGIN`/`COMMIT`/`ROLLBACK` over a single borrowed connection (via the pool). When `mkBatch`/`mkTransaction` server support is verified, the implementation can switch to the native messages without changing the public API.

### 5.7 HTTP fallback (optional module)

`baradb/http` provides `BaraHttpClient` that sends JSON `{"query": ...}` to `POST /api/query` (HTTP endpoint, default port `TCP+440`) and parses the JSON response. Useful for environments where only the HTTP port is open or for debugging. Not loaded by default.

## 6. Allographer Integration Plan

1. **Add `requires "baradb >= 1.2.0"` to `clients/nim-allographer/allographer.nimble`.**
2. **Replace `baradb_client.nim` wire code with re-exports.** Keep the allographer-specific query builder and migration helpers.
3. **Update `baradb_types.nim`.** `Connection.client` stays `BaraClient`; remove local duplicates of `ClientConfig`, `WireValue`, `QueryResult`.
4. **Keep the current pool or migrate to `BaraPool`.** Phase 1: keep the existing `Connections` pool because the allographer query builder relies on its busy-flag semantics. Phase 2 (optional): replace it with `BaraPool.withClient` to reduce code.
5. **Use typed rows internally.** Update `toJson(resultSet)` in `baradb_exec.nim` to read from `resultSet.typedRows` instead of parsing strings. This fixes wrong JSON/vector/int parsing.
6. **Fix `formatSql` / prepared statements.** The current code sometimes builds SQL by string concatenation in `baradb_exec.nim`; ensure all user input goes through `mkQueryParams` so the server handles parameter binding.

## 7. Public API Sketch

### Standalone async

```nim
import asyncdispatch, baradb/client, baradb/pool

proc main() {.async.} =
  let cfg = ClientConfig(host: "127.0.0.1", port: 9472, timeoutMs: 30_000)
  let pool = newBaraPool(cfg, minConnections = 2, maxConnections = 10)
  await withClient(pool) do (c: BaraClient) -> Future[void]:
    let r = await c.query("SELECT name, age FROM users WHERE age > ?",
                          @[WireValue(kind: fkInt32, int32Val: 18)])
    echo r.typedRows

waitFor main()
```

### Standalone sync

```nim
import baradb/client

let c = newSyncClient()
c.connect()
let r = c.query("SELECT * FROM users")
echo r.rows
c.close()
```

### Allographer (unchanged)

```nim
import allographer/connection, allographer/query_builder

let rdb = dbOpen(Baradb, "default", "admin", "", "127.0.0.1", 9472,
                 maxConnections = 5)

proc main() {.async.} =
  let users = await rdb.table("users").select("id", "name").get()
  echo users

waitFor main()
```

## 8. Data Flow

1. Caller invokes `await pool.withClient(...)` or `await client.query(sql, params)`.
2. The request is enqueued on the connection (or the pool lends a free connection).
3. The queue serializes the request: send header + payload, wait for response.
4. The response loop reads the 12-byte header, then the payload, then any trailing `mkComplete`.
5. `mkData` payloads are deserialized into `typedRows`; `rows` is populated via `wireValueToString`.
6. Server errors (`mkError`) raise `BaraServerError` with code and message.
7. The connection is returned to the pool.

## 9. Error Handling

| Exception | When raised | Retry? |
|-----------|-------------|--------|
| `BaraError` | Base type | depends |
| `BaraProtocolError` | Bad framing, unexpected message kind | no |
| `BaraServerError` | Server replied with `mkError` | no |
| `BaraAuthError` | Auth failed / rejected | no |
| `BaraIoError` | Connection lost, timeout, ECONNREFUSED | yes (up to `maxRetries`) |
| `BaraPoolTimeoutError` | No connection available within `timeoutMs` | no |

All exceptions inherit from `BaraError` so callers can catch a single type.

## 10. Testing Strategy

1. **Mock async TCP server in `clients/nim/tests/test_wire.nim`.** Verifies framing, request/response serialization, and the request queue without a real BaraDB instance.
2. **Property/round-trip tests for `WireValue`.** Serialize then deserialize random values and compare.
3. **Pool unit tests.** Check acquire/release, max size, eviction, and timeout behavior using a mock client factory.
4. **Integration tests.** Reuse `clients/nim/tests/test_integration.nim` and `clients/nim-allographer/tests/baradb/*`; run them when a server is available on `localhost:9472`.
5. **Allographer regression tests.** Ensure existing tests still pass after switching to the canonical client.

## 11. Migration & Rollout

1. Release `clients/nim` as `baradb 1.2.0` with the new modules.
2. Update `clients/nim-allographer` to depend on `baradb >= 1.2.0` and remove the duplicated wire code.
3. Mark `src/barabadb/client/client.nim` as deprecated with a `{.deprecated.}` pragma pointing to `baradb/client`.
4. Document the new pool and typed-row APIs in `clients/nim/README.md` and `docs/en/clients.md`.

## 12. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking allographer tests | Run the full `tests/baradb/` suite after every change; keep API unchanged. |
| TLS support depends on OpenSSL Nim wrapper | Gate TLS behind `when defined(ssl)` and document how to build with `-d:ssl`. |
| Async request queue hurts throughput | Benchmark before/after; add per-request `requestId` matching and pipelining later if needed. |
| Server `mkBatch`/`mkTransaction` semantics unclear | Implement via SQL `BEGIN`/`COMMIT` first; switch to native messages later. |
| Nim 2.0 vs 2.2 compatibility | Keep code compatible with Nim 2.0; test on both versions in CI. |

## 13. Open Questions

1. Should `clients/nim-allographer` keep its own pool (Phase 1) or switch fully to `BaraPool` (Phase 2)?  
   *Recommendation:* Phase 1 keeps risk low; Phase 2 can be done after the canonical pool is proven stable.
2. Should the HTTP fallback be part of the `baradb` package or a separate `baradb_http` package?  
   *Recommendation:* Keep it as an optional module `baradb/http` inside the same package so `import baradb/http` is explicit and does not pull in `httpclient` for users who do not need it.
