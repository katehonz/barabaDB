# Nodebara Compatibility Fixes

This PR bundles three independent fixes discovered while integrating BaraDB with [NodeBB](https://nodebb.org/) (a large Node.js forum application). Each commit is self-contained and can be reviewed separately.

---

## 1. fix(protocol): serialize float32/float64 in big-endian

**Problem:**  
The JavaScript client reads `FLOAT32`/`FLOAT64` wire values with `readFloatBE()` / `readDoubleBE()` (big-endian), but the Nim server was writing them with `copyMem(..., unsafeAddr fl, N)` — i.e. **native byte order**. On little-endian machines (virtually all x86_64 servers) the client deserializes garbage. Example: a zset `score = 1.0` becomes `3.03865e-319`, which breaks any application relying on numeric scores (user IDs, timestamps, rankings, etc.).

**Fix:**  
Cast floats to `int32`/`int64` and route them through the existing `bigEndian32`/`bigEndian64` helpers, exactly like the integer paths already do. Same change applied to deserialization.

**Impact:**  
Breaking fix for cross-platform wire compatibility. No API changes.

---

## 2. feat(client): add TCP request queue for safe concurrency

**Problem:**  
`Client.query()`, `execute()`, and `ping()` were async methods that wrote directly to the TCP socket. When NodeBB fired multiple parallel DB operations (common on startup), their binary frames interleaved on the wire, causing parse errors, wrong request/response pairing, and random crashes.

**Fix:**  
Introduce an internal `_requestQueue` + `_requestLock`. Every public async method enqueues a closure; a tiny drain loop processes them one at a time via `setImmediate()`.

**Impact:**  
No breaking API change. Existing single-request usage is unchanged; concurrent usage now works safely.

---

## 3. fix(gossip): use async UDP socket to avoid blocking the event loop

**Problem:**  
`startGossipListener` created a **synchronous** UDP socket (`newSocket`) and called blocking `recvFrom` inside an `async` proc. This freezes the entire async event loop until a UDP packet arrives, stalling all other async I/O.

**Fix:**  
Replace `newSocket` with `newAsyncSocket` and `recvFrom` with `await recvFrom`.

**Impact:**  
Non-breaking. Gossip remains optional; when enabled it no longer blocks the main loop.

---

## Testing

- [x] NodeBB v4.11.2 setup completes end-to-end  
- [x] Admin login works (relies on correct FLOAT64 score deserialization)  
- [x] Concurrent DB queries during startup no longer corrupt frames  
- [x] Gossip listener no longer blocks other async tasks

---

## Checklist

- [x] Each commit is atomic and compiles on its own  
- [x] No Nim compiler warnings introduced  
- [x] JS client backward-compatible for single-request callers  
- [x] Existing tests (`nimble test`) still pass
