## Bloom filter — probabilistic set membership
import std/hashes
import std/math

type
  BloomFilter* = object
    bits: seq[bool]
    numHashes: int
    size: int

proc newBloomFilter*(expectedItems: int, fpRate: float = 0.01): BloomFilter =
  let size = int(-float(expectedItems) * ln(fpRate) / (ln(2.0) * ln(2.0)))
  let numHashes = int(float(size) / float(expectedItems) * ln(2.0))
  BloomFilter(
    bits: newSeq[bool](max(size, 64)),
    numHashes: max(numHashes, 1),
    size: max(size, 64),
  )

proc hash1*(bf: BloomFilter, data: openArray[byte]): uint64 =
  var h: Hash = 0
  for b in data:
    h = h !& Hash(b)
  result = uint64(!$h)

proc hash2*(bf: BloomFilter, data: openArray[byte]): uint64 =
  var h: Hash = 5381
  for b in data:
    h = ((h shl 5) + h) + Hash(b)
  result = uint64(h)

proc getHashes(bf: BloomFilter, data: openArray[byte]): seq[int] =
  let h1 = bf.hash1(data)
  let h2 = bf.hash2(data)
  result = newSeq[int](bf.numHashes)
  for i in 0..<bf.numHashes:
    result[i] = int((h1 + uint64(i) * h2) mod uint64(bf.size))

proc add*(bf: var BloomFilter, data: openArray[byte]) =
  for idx in bf.getHashes(data):
    bf.bits[idx] = true

proc contains*(bf: BloomFilter, data: openArray[byte]): bool =
  for idx in bf.getHashes(data):
    if not bf.bits[idx]:
      return false
  return true

proc clear*(bf: var BloomFilter) =
  for i in 0..<bf.size:
    bf.bits[i] = false
