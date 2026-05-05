## Rate Limiter — token bucket and sliding window algorithms
import std/tables
import std/monotimes
import std/locks

type
  RateLimitAlgo* = enum
    rlaTokenBucket
    rlaSlidingWindow
    rlaFixedWindow

  TokenBucket* = ref object
    tokens: float64
    maxTokens: float64
    refillRate: float64  # tokens per second
    lastRefill: int64

  SlidingWindow* = ref object
    windowSize: int64  # nanoseconds
    maxRequests: int
    timestamps: seq[int64]

  RateLimiter* = ref object
    lock: Lock
    algo: RateLimitAlgo
    buckets: Table[string, TokenBucket]
    windows: Table[string, SlidingWindow]
    globalRate*: int
    perClientRate*: int

proc newTokenBucket*(maxTokens: float64, refillRate: float64): TokenBucket =
  TokenBucket(
    tokens: maxTokens,
    maxTokens: maxTokens,
    refillRate: refillRate,
    lastRefill: getMonoTime().ticks(),
  )

proc consume*(bucket: TokenBucket, tokens: float64 = 1.0): bool =
  let now = getMonoTime().ticks()
  let elapsed = float64(now - bucket.lastRefill) / 1_000_000_000.0
  bucket.tokens = min(bucket.maxTokens, bucket.tokens + elapsed * bucket.refillRate)
  bucket.lastRefill = now

  if bucket.tokens >= tokens:
    bucket.tokens -= tokens
    return true
  return false

proc available*(bucket: TokenBucket): float64 =
  let now = getMonoTime().ticks()
  let elapsed = float64(now - bucket.lastRefill) / 1_000_000_000.0
  return min(bucket.maxTokens, bucket.tokens + elapsed * bucket.refillRate)

proc newSlidingWindow*(windowSize: int64, maxRequests: int): SlidingWindow =
  SlidingWindow(
    windowSize: windowSize,
    maxRequests: maxRequests,
    timestamps: @[],
  )

proc allow*(window: SlidingWindow): bool =
  let now = getMonoTime().ticks()
  let cutoff = now - window.windowSize

  # Remove old timestamps
  var newTs: seq[int64] = @[]
  for ts in window.timestamps:
    if ts > cutoff:
      newTs.add(ts)
  window.timestamps = newTs

  if window.timestamps.len < window.maxRequests:
    window.timestamps.add(now)
    return true
  return false

proc requestCount*(window: SlidingWindow): int = window.timestamps.len

proc newRateLimiter*(algo: RateLimitAlgo = rlaTokenBucket,
                    globalRate: int = 1000, perClientRate: int = 100): RateLimiter =
  new(result)
  initLock(result.lock)
  result.algo = algo
  result.buckets = initTable[string, TokenBucket]()
  result.windows = initTable[string, SlidingWindow]()
  result.globalRate = globalRate
  result.perClientRate = perClientRate

proc allowRequest*(rl: RateLimiter, clientId: string): bool =
  acquire(rl.lock)

  case rl.algo
  of rlaTokenBucket:
    if clientId notin rl.buckets:
      rl.buckets[clientId] = newTokenBucket(float64(rl.perClientRate),
                                            float64(rl.perClientRate) / 60.0)
    result = rl.buckets[clientId].consume()
  of rlaSlidingWindow:
    if clientId notin rl.windows:
      rl.windows[clientId] = newSlidingWindow(60_000_000_000, rl.perClientRate)
    result = rl.windows[clientId].allow()
  of rlaFixedWindow:
    if clientId notin rl.windows:
      rl.windows[clientId] = newSlidingWindow(60_000_000_000, rl.perClientRate)
    result = rl.windows[clientId].allow()

  release(rl.lock)

proc remainingQuota*(rl: RateLimiter, clientId: string): int =
  acquire(rl.lock)
  case rl.algo
  of rlaTokenBucket:
    if clientId in rl.buckets:
      result = int(rl.buckets[clientId].available())
    else:
      result = rl.perClientRate
  of rlaSlidingWindow, rlaFixedWindow:
    if clientId in rl.windows:
      result = rl.perClientRate - rl.windows[clientId].requestCount()
    else:
      result = rl.perClientRate
  release(rl.lock)

proc resetClient*(rl: RateLimiter, clientId: string) =
  acquire(rl.lock)
  rl.buckets.del(clientId)
  rl.windows.del(clientId)
  release(rl.lock)

proc clientCount*(rl: RateLimiter): int =
  acquire(rl.lock)
  result = max(rl.buckets.len, rl.windows.len)
  release(rl.lock)
