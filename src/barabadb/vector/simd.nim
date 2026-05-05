## Vector SIMD — optimized vector distance computations
import std/math
import std/algorithm

type
  SimdVector* = seq[float32]

proc dotProductSimd*(a, b: SimdVector): float32 =
  var sum: float32 = 0.0
  let len = min(a.len, b.len)
  # Process 4 elements at a time (manual unrolling for SIMD-like optimization)
  var i = 0
  while i + 3 < len:
    sum += a[i] * b[i] + a[i+1] * b[i+1] + a[i+2] * b[i+2] + a[i+3] * b[i+3]
    i += 4
  while i < len:
    sum += a[i] * b[i]
    inc i
  return sum

proc l2NormSimd*(a, b: SimdVector): float32 =
  var sum: float32 = 0.0
  let len = min(a.len, b.len)
  var i = 0
  while i + 3 < len:
    let d0 = a[i] - b[i]
    let d1 = a[i+1] - b[i+1]
    let d2 = a[i+2] - b[i+2]
    let d3 = a[i+3] - b[i+3]
    sum += d0*d0 + d1*d1 + d2*d2 + d3*d3
    i += 4
  while i < len:
    let d = a[i] - b[i]
    sum += d * d
    inc i
  return sqrt(sum)

proc cosineSimd*(a, b: SimdVector): float32 =
  var dot: float32 = 0.0
  var normA: float32 = 0.0
  var normB: float32 = 0.0
  let len = min(a.len, b.len)
  var i = 0
  while i + 3 < len:
    dot += a[i]*b[i] + a[i+1]*b[i+1] + a[i+2]*b[i+2] + a[i+3]*b[i+3]
    normA += a[i]*a[i] + a[i+1]*a[i+1] + a[i+2]*a[i+2] + a[i+3]*a[i+3]
    normB += b[i]*b[i] + b[i+1]*b[i+1] + b[i+2]*b[i+2] + b[i+3]*b[i+3]
    i += 4
  while i < len:
    dot += a[i] * b[i]
    normA += a[i] * a[i]
    normB += b[i] * b[i]
    inc i
  let denom = sqrt(normA) * sqrt(normB)
  if denom == 0: return 1.0
  return 1.0 - dot / denom

proc manhattanSimd*(a, b: SimdVector): float32 =
  var sum: float32 = 0.0
  let len = min(a.len, b.len)
  var i = 0
  while i + 3 < len:
    sum += abs(a[i]-b[i]) + abs(a[i+1]-b[i+1]) + abs(a[i+2]-b[i+2]) + abs(a[i+3]-b[i+3])
    i += 4
  while i < len:
    sum += abs(a[i] - b[i])
    inc i
  return sum

proc normalize*(v: SimdVector): SimdVector =
  var norm: float32 = 0.0
  var i = 0
  while i + 3 < v.len:
    norm += v[i]*v[i] + v[i+1]*v[i+1] + v[i+2]*v[i+2] + v[i+3]*v[i+3]
    i += 4
  while i < v.len:
    norm += v[i] * v[i]
    inc i
  norm = sqrt(norm)
  if norm == 0:
    return v
  result = newSeq[float32](v.len)
  for j in 0..<v.len:
    result[j] = v[j] / norm

proc addVectors*(a, b: SimdVector): SimdVector =
  let len = min(a.len, b.len)
  result = newSeq[float32](len)
  var i = 0
  while i + 3 < len:
    result[i] = a[i] + b[i]
    result[i+1] = a[i+1] + b[i+1]
    result[i+2] = a[i+2] + b[i+2]
    result[i+3] = a[i+3] + b[i+3]
    i += 4
  while i < len:
    result[i] = a[i] + b[i]
    inc i

proc scaleVector*(v: SimdVector, s: float32): SimdVector =
  result = newSeq[float32](v.len)
  var i = 0
  while i + 3 < v.len:
    result[i] = v[i] * s
    result[i+1] = v[i+1] * s
    result[i+2] = v[i+2] * s
    result[i+3] = v[i+3] * s
    i += 4
  while i < v.len:
    result[i] = v[i] * s
    inc i

proc batchDistance*(queries: seq[SimdVector], corpus: seq[SimdVector],
                   metric: string = "cosine"): seq[seq[float32]] =
  result = newSeq[seq[float32]](queries.len)
  for qi in 0..<queries.len:
    result[qi] = newSeq[float32](corpus.len)
    for ci in 0..<corpus.len:
      case metric
      of "cosine": result[qi][ci] = cosineSimd(queries[qi], corpus[ci])
      of "l2": result[qi][ci] = l2NormSimd(queries[qi], corpus[ci])
      of "dot": result[qi][ci] = -dotProductSimd(queries[qi], corpus[ci])
      of "manhattan": result[qi][ci] = manhattanSimd(queries[qi], corpus[ci])
      else: result[qi][ci] = cosineSimd(queries[qi], corpus[ci])

proc topK*(distances: seq[float32], k: int): seq[(int, float32)] =
  var indexed: seq[(int, float32)] = @[]
  for i in 0..<distances.len:
    indexed.add((i, distances[i]))
  indexed.sort(proc(a, b: (int, float32)): int = cmp(a[1], b[1]))
  if indexed.len > k:
    indexed = indexed[0..<k]
  return indexed
