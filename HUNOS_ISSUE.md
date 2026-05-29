# Bug Report: `hunos` 1.3.1 fails to compile on Nim 2.2.x — `getRandomBytes` removed from `std/sysrand`

## Summary

The `hunos` package (v1.3.1) fails to compile on Nim 2.2.10 with:

```
hunos/sessions.nim(42, 3) Error: undeclared identifier: 'getRandomBytes'
```

The `std/sysrand` module in Nim 2.2.x no longer exports `getRandomBytes`. The API was renamed to `urandom`.

## Affected files (3 locations)

### 1. `hunos/sessions.nim` — `generateSessionId()`

```nim
# BROKEN (line ~42)
proc generateSessionId(): string =
  var bytes = newSeq[byte](16)
  getRandomBytes(bytes)  # ← does not exist in Nim 2.2
  ...
```

**Fix:**
```nim
proc generateSessionId(): string =
  let bytes = urandom(16)
  ...
```

### 2. `hunos/sessions.nim` — `newRandomSecretKey()`

```nim
# BROKEN (line ~222)
proc newRandomSecretKey*(): SignedCookieSecretKey =
  var bytes = newSeq[byte](48)
  getRandomBytes(bytes)  # ← does not exist in Nim 2.2
  result.key = encode(bytes)
```

**Fix:**
```nim
proc newRandomSecretKey*(): SignedCookieSecretKey =
  let bytes = urandom(48)
  result.key = encode(bytes)
```

### 3. `hunos/csrf.nim` — `generateCsrfToken()`

```nim
# BROKEN (line ~27)
proc generateCsrfToken*(): string =
  var bytes = newSeq[byte](csrfTokenLength)
  getRandomBytes(bytes)  # ← does not exist in Nim 2.2
  ...
```

**Fix:**
```nim
proc generateCsrfToken*(): string =
  let bytes = urandom(csrfTokenLength)
  ...
```

## Environment

| Component | Version |
|-----------|---------|
| Nim | 2.2.10 |
| hunos | 1.3.1 |
| OS | Linux (amd64) |

## Root cause

`std/sysrand` in Nim 2.2.x provides:
- `proc urandom*(dest: var openArray[byte]): bool`
- `proc urandom*(size: Natural): seq[byte]`

The old `getRandomBytes` procedure was removed. All three call sites need to switch to `urandom`.

## Impact

Any project depending on `hunos >= 1.3.0, < 1.3.2` with Nim 2.2.x will fail to compile. This is a **build-breaking** issue.

## Workaround

Pin to `hunos >= 1.3.2` (which has the fix) or patch the three files locally as shown above.
