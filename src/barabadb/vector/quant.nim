## Vector Quantization — scalar, product, binary quantization
import std/math

type
  QuantizationKind* = enum
    qkNone
    qkScalar8
    qkScalar4
    qkProduct
    qkBinary

  ScalarQuantizer* = ref object
    mins: seq[float32]
    maxes: seq[float32]
    dimensions: int
    bits: int

  ProductQuantizer* = ref object
    codebooks: seq[seq[seq[float32]]]  # subspace -> cluster -> centroid
    nSubspaces: int
    nClusters: int
    dimensions: int
    subDim: int

  QuantizedVector* = ref object
    case kind*: QuantizationKind
    of qkScalar8: int8Data*: seq[int8]
    of qkScalar4: int4Data*: seq[int8]  # packed
    of qkProduct: pqCodes*: seq[int8]
    of qkBinary: binData*: seq[uint64]  # packed bits
    of qkNone: orig*: seq[float32]

proc newScalarQuantizer*(dimensions: int, bits: int = 8): ScalarQuantizer =
  ScalarQuantizer(
    mins: newSeq[float32](dimensions),
    maxes: newSeq[float32](dimensions),
    dimensions: dimensions,
    bits: bits,
  )

proc train*(sq: ScalarQuantizer, vectors: openArray[seq[float32]]) =
  if vectors.len == 0:
    return
  for d in 0..<sq.dimensions:
    var minVal: float32 = high(float32)
    var maxVal: float32 = low(float32)
    for v in vectors:
      if d < v.len:
        if v[d] < minVal: minVal = v[d]
        if v[d] > maxVal: maxVal = v[d]
    sq.mins[d] = minVal
    sq.maxes[d] = maxVal

proc encode*(sq: ScalarQuantizer, vector: seq[float32]): QuantizedVector =
  result = QuantizedVector(kind: if sq.bits == 8: qkScalar8 else: qkScalar4)
  let levels = float32(1 shl sq.bits) - 1.0'f32

  if sq.bits == 8:
    result.int8Data = newSeq[int8](sq.dimensions)
    for d in 0..<sq.dimensions:
      let range = sq.maxes[d] - sq.mins[d]
      if range == 0:
        result.int8Data[d] = 0
      else:
        let normalized = (vector[d] - sq.mins[d]) / range
        result.int8Data[d] = int8(normalized * levels)
  elif sq.bits == 4:
    # Pack 2 values per byte
    result.int4Data = newSeq[int8](sq.dimensions div 2 + sq.dimensions mod 2)
    for d in 0..<sq.dimensions:
      let range = sq.maxes[d] - sq.mins[d]
      var val: int8 = 0
      if range != 0:
        let normalized = (vector[d] - sq.mins[d]) / range
        val = int8(normalized * 15)
      let idx = d div 2
      if d mod 2 == 0:
        result.int4Data[idx] = val shl 4
      else:
        result.int4Data[idx] = result.int4Data[idx] or val

proc decode*(sq: ScalarQuantizer, qv: QuantizedVector): seq[float32] =
  result = newSeq[float32](sq.dimensions)
  if qv.kind == qkScalar8:
    let levels = 255.0'f32
    for d in 0..<sq.dimensions:
      let range = sq.maxes[d] - sq.mins[d]
      result[d] = sq.mins[d] + float32(qv.int8Data[d]) / levels * range
  elif qv.kind == qkScalar4:
    let levels = 15.0'f32
    for d in 0..<sq.dimensions:
      let idx = d div 2
      var val: int8
      if d mod 2 == 0:
        val = (qv.int4Data[idx] shr 4) and 0x0F
      else:
        val = qv.int4Data[idx] and 0x0F
      let range = sq.maxes[d] - sq.mins[d]
      result[d] = sq.mins[d] + float32(val) / levels * range

proc distance*(sq: ScalarQuantizer, qv: QuantizedVector, query: seq[float32]): float64 =
  let decoded = sq.decode(qv)
  var sum: float64
  for d in 0..<sq.dimensions:
    let diff = float64(decoded[d]) - float64(query[d])
    sum += diff * diff
  return sqrt(sum)

proc newProductQuantizer*(dimensions: int, nSubspaces: int = 8, nClusters: int = 256): ProductQuantizer =
  let subDim = dimensions div nSubspaces
  ProductQuantizer(
    codebooks: newSeq[seq[seq[float32]]](nSubspaces),
    nSubspaces: nSubspaces,
    nClusters: nClusters,
    dimensions: dimensions,
    subDim: subDim,
  )

proc train*(pq: ProductQuantizer, vectors: openArray[seq[float32]], nIterations: int = 20) =
  if vectors.len == 0:
    return

  for s in 0..<pq.nSubspaces:
    pq.codebooks[s] = newSeq[seq[float32]](pq.nClusters)
    for c in 0..<pq.nClusters:
      pq.codebooks[s][c] = newSeq[float32](pq.subDim)

    # Initialize centroids randomly from data
    for c in 0..<pq.nClusters:
      let idx = min(c, vectors.len - 1)
      for d in 0..<pq.subDim:
        let globalD = s * pq.subDim + d
        if globalD < vectors[idx].len:
          pq.codebooks[s][c][d] = vectors[idx][globalD]

    # K-means per subspace
    var assignments = newSeq[int](vectors.len)
    for iter in 0..<nIterations:
      # Assign vectors to clusters
      for vi, v in vectors:
        var bestCluster = 0
        var bestDist = high(float64)
        for ci in 0..<pq.nClusters:
          var dist: float64 = 0
          for d in 0..<pq.subDim:
            let globalD = s * pq.subDim + d
            if globalD < v.len:
              let diff = float64(v[globalD]) - float64(pq.codebooks[s][ci][d])
              dist += diff * diff
          if dist < bestDist:
            bestDist = dist
            bestCluster = ci
        assignments[vi] = bestCluster

      # Update centroids
      var clusterCounts = newSeq[int](pq.nClusters)
      var newCentroids = newSeq[seq[float64]](pq.nClusters)
      for c in 0..<pq.nClusters:
        newCentroids[c] = newSeq[float64](pq.subDim)

      for vi, v in vectors:
        let ci = assignments[vi]
        inc clusterCounts[ci]
        for d in 0..<pq.subDim:
          let globalD = s * pq.subDim + d
          if globalD < v.len:
            newCentroids[ci][d] += float64(v[globalD])

      for ci in 0..<pq.nClusters:
        if clusterCounts[ci] > 0:
          for d in 0..<pq.subDim:
            pq.codebooks[s][ci][d] = float32(newCentroids[ci][d] / float64(clusterCounts[ci]))

proc encode*(pq: ProductQuantizer, vector: seq[float32]): QuantizedVector =
  result = QuantizedVector(kind: qkProduct, pqCodes: newSeq[int8](pq.nSubspaces))
  for s in 0..<pq.nSubspaces:
    var bestCluster: int8 = 0
    var bestDist = high(float64)
    for ci in 0..<pq.nClusters:
      var dist: float64 = 0
      for d in 0..<pq.subDim:
        let globalD = s * pq.subDim + d
        if globalD < vector.len:
          let diff = float64(vector[globalD]) - float64(pq.codebooks[s][ci][d])
          dist += diff * diff
      if dist < bestDist:
        bestDist = dist
        bestCluster = int8(ci)
    result.pqCodes[s] = bestCluster

proc distance*(pq: ProductQuantizer, qv: QuantizedVector, query: seq[float32]): float64 =
  var sum: float64 = 0
  for s in 0..<pq.nSubspaces:
    let ci = qv.pqCodes[s]
    for d in 0..<pq.subDim:
      let globalD = s * pq.subDim + d
      if globalD < query.len:
        let diff = float64(pq.codebooks[s][ci][d]) - float64(query[globalD])
        sum += diff * diff
  return sqrt(sum)

# Binary quantization
proc binaryQuantize*(vector: seq[float32]): QuantizedVector =
  result = QuantizedVector(kind: qkBinary)
  let bits = vector.len
  let words = (bits + 63) div 64
  result.binData = newSeq[uint64](words)
  for i in 0..<vector.len:
    if vector[i] >= 0:
      let wordIdx = i div 64
      let bitIdx = i mod 64
      result.binData[wordIdx] = result.binData[wordIdx] or (1'u64 shl bitIdx)

proc binaryDistance*(a, b: QuantizedVector): int =
  result = 0
  let words = min(a.binData.len, b.binData.len)
  for i in 0..<words:
    let val = a.binData[i] xor b.binData[i]
    var cnt = 0
    var v = val
    while v != 0:
      v = v and (v - 1)
      inc cnt
    result += cnt

proc compressionRatio*(sq: ScalarQuantizer): float64 =
  if sq.bits == 8: return 4.0
  if sq.bits == 4: return 8.0
  return 1.0

proc compressionRatio*(pq: ProductQuantizer): float64 =
  let origBytes = pq.dimensions * 4
  let pqBytes = pq.nSubspaces  # one byte per subspace code
  return float64(origBytes) / float64(pqBytes)
