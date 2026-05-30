type
  HeapEntry*[K, V] = object
    key*: K
    value*: V

  BoundedHeap*[K, V] = ref object
    data: seq[HeapEntry[K, V]]
    cap: int
    less: proc(a, b: K): bool {.gcsafe.}

proc newBoundedHeap*[K, V](maxCapacity: int = 0,
    less: proc(a, b: K): bool {.gcsafe.}): BoundedHeap[K, V] =
  BoundedHeap[K, V](data: newSeqOfCap[HeapEntry[K, V]](min(maxCapacity, 4096)),
                     cap: maxCapacity, less: less)

proc len*[K, V](h: BoundedHeap[K, V]): int = h.data.len

proc isEmpty*[K, V](h: BoundedHeap[K, V]): bool = h.data.len == 0

proc peek*[K, V](h: BoundedHeap[K, V]): HeapEntry[K, V] = h.data[0]

proc siftUp[K, V](h: BoundedHeap[K, V], i: int) =
  var idx = i
  while idx > 0:
    let parent = (idx - 1) div 2
    if h.less(h.data[idx].key, h.data[parent].key):
      swap(h.data[idx], h.data[parent])
      idx = parent
    else:
      break

proc siftDown[K, V](h: BoundedHeap[K, V], i: int) =
  var idx = i
  let n = h.data.len
  while true:
    var best = idx
    let left = 2 * idx + 1
    let right = 2 * idx + 2
    if left < n and h.less(h.data[left].key, h.data[best].key):
      best = left
    if right < n and h.less(h.data[right].key, h.data[best].key):
      best = right
    if best == idx:
      break
    swap(h.data[idx], h.data[best])
    idx = best

proc push*[K, V](h: BoundedHeap[K, V], key: K, value: V) =
  if h.cap > 0 and h.data.len == h.cap:
    if h.less(h.data[0].key, key):
      h.data[0] = HeapEntry[K, V](key: key, value: value)
      h.siftDown(0)
  else:
    h.data.add(HeapEntry[K, V](key: key, value: value))
    h.siftUp(h.data.len - 1)

proc pop*[K, V](h: BoundedHeap[K, V]): HeapEntry[K, V] =
  result = h.data[0]
  let last = h.data.len - 1
  if last > 0:
    h.data[0] = h.data[last]
    h.data.setLen(last)
    h.siftDown(0)
  else:
    h.data.setLen(0)

proc toSortedSeq*[K, V](h: BoundedHeap[K, V]): seq[HeapEntry[K, V]] =
  var copy = BoundedHeap[K, V](data: @h.data, cap: h.cap, less: h.less)
  result = newSeqOfCap[HeapEntry[K, V]](copy.len)
  while not copy.isEmpty:
    result.add(copy.pop())

proc items*[K, V](h: BoundedHeap[K, V]): seq[HeapEntry[K, V]] = h.data
