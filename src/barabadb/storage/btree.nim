## B-Tree Index — ordered key-value index
import std/tables
import std/locks

const
  DefaultBTreeOrder* = 32

type
  BTreeNode[K, V] = ref object
    keys: seq[K]
    values: seq[seq[V]]
    children: seq[BTreeNode[K, V]]
    isLeaf: bool
    next: BTreeNode[K, V]

  BTreeIndex*[K, V] = ref object
    root: BTreeNode[K, V]
    order: int
    size: int
    lock*: Lock

proc newBTreeNode[K, V](isLeaf: bool = true): BTreeNode[K, V] =
  BTreeNode[K, V](
    keys: @[], values: @[], children: @[],
    isLeaf: isLeaf, next: nil,
  )

proc newBTreeIndex*[K, V](order: int = DefaultBTreeOrder): BTreeIndex[K, V] =
  result = BTreeIndex[K, V](root: newBTreeNode[K, V](), order: order, size: 0)
  initLock(result.lock)

proc search[K, V](node: BTreeNode[K, V], key: K): seq[V] =
  var i = 0
  if node.isLeaf:
    while i < node.keys.len and key > node.keys[i]:
      inc i
    # Collect values from this leaf and any subsequent leaves that also contain the key.
    var cur: BTreeNode[K, V] = node
    while cur != nil:
      var j = 0
      while j < cur.keys.len and cur.keys[j] < key:
        inc j
      if j < cur.keys.len and cur.keys[j] == key:
        result &= cur.values[j]
      if j < cur.keys.len and cur.keys[j] > key:
        break
      cur = cur.next
    return result
  else:
    while i < node.keys.len and key > node.keys[i]:
      inc i
    return search(node.children[i], key)

proc splitChild[K, V](parent: BTreeNode[K, V], index: int, order: int) =
  let child = parent.children[index]
  var mid = (order - 1) div 2
  let newNode = newBTreeNode[K, V](child.isLeaf)

  if child.isLeaf:
    # Consolidate duplicate boundary key values before split.
    let midKey = child.keys[mid]
    var hasDup = false
    for j in 0..<child.keys.len:
      if j != mid and child.keys[j] == midKey:
        hasDup = true
        break
    if hasDup:
      var allVals = child.values[mid]
      var j = child.keys.len - 1
      while j >= 0:
        if j != mid and child.keys[j] == midKey:
          allVals &= child.values[j]
          child.keys.delete(j)
          child.values.delete(j)
          if j < mid: dec mid
        dec j
      child.values[mid] = allVals

  for j in mid+1..<child.keys.len:
    newNode.keys.add(child.keys[j])
    if child.isLeaf:
      newNode.values.add(child.values[j])

  if not child.isLeaf:
    for j in mid+1..<child.children.len:
      newNode.children.add(child.children[j])
    child.children.setLen(mid + 1)

  if child.isLeaf:
    newNode.next = child.next
    child.next = newNode

  let midKey = child.keys[mid]
  parent.keys.insert(midKey, index)
  parent.children.insert(newNode, index + 1)
  # In B+ tree, leaf nodes must keep the boundary key for range scans
  if child.isLeaf:
    child.keys.setLen(mid + 1)
    child.values.setLen(mid + 1)
  else:
    child.keys.setLen(mid)

proc insertNonFull[K, V](node: BTreeNode[K, V], key: K, value: V, order: int): bool =
  ## Returns true if a new key was inserted, false if existing key got a new value.
  var i = node.keys.len - 1
  if node.isLeaf:
    while i >= 0 and key < node.keys[i]:
      dec i
    if i >= 0 and key == node.keys[i]:
      node.values[i].add(value)
      return false
    node.keys.insert(key, i + 1)
    node.values.insert(@[value], i + 1)
    return true
  else:
    while i >= 0 and key < node.keys[i]:
      dec i
    inc i
    if node.children[i].keys.len == order - 1:
      splitChild(node, i, order)
      if key > node.keys[i]:
        inc i
    return insertNonFull(node.children[i], key, value, order)

proc insert*[K, V](btree: var BTreeIndex[K, V], key: K, value: V) =
  acquire(btree.lock)
  try:
    var inserted = false
    if btree.root.keys.len == btree.order - 1:
      var newRoot = newBTreeNode[K, V](isLeaf = false)
      newRoot.children.add(btree.root)
      splitChild(newRoot, 0, btree.order)
      btree.root = newRoot
      inserted = insertNonFull(btree.root, key, value, btree.order)
    else:
      inserted = insertNonFull(btree.root, key, value, btree.order)
    if inserted:
      inc btree.size
  finally:
    release(btree.lock)

proc get*[K, V](btree: BTreeIndex[K, V], key: K): seq[V] =
  acquire(btree.lock)
  try:
    result = search(btree.root, key)
  finally:
    release(btree.lock)

proc contains*[K, V](btree: BTreeIndex[K, V], key: K): bool =
  acquire(btree.lock)
  try:
    result = search(btree.root, key).len > 0
  finally:
    release(btree.lock)

proc scan*[K, V](btree: BTreeIndex[K, V], startKey, endKey: K): seq[(K, seq[V])] =
  acquire(btree.lock)
  try:
    result = @[]
    var node = btree.root
    while not node.isLeaf:
      var i = 0
      while i < node.keys.len and startKey > node.keys[i]:
        inc i
      node = node.children[i]

    while node != nil:
      for i in 0..<node.keys.len:
        if node.keys[i] >= startKey:
          if node.keys[i] <= endKey:
            result.add((node.keys[i], node.values[i]))
          else:
            return
      node = node.next
  finally:
    release(btree.lock)

proc len*[K, V](btree: BTreeIndex[K, V]): int =
  acquire(btree.lock)
  try:
    var node = btree.root
    while not node.isLeaf:
      node = node.children[0]
    var lastKey: K
    var hasLast = false
    while node != nil:
      for i in 0..<node.keys.len:
        if hasLast and node.keys[i] == lastKey:
          continue
        lastKey = node.keys[i]
        hasLast = true
        inc result
      node = node.next
  finally:
    release(btree.lock)

proc minKeysForLeaf[K, V](node: BTreeNode[K, V], order: int): int =
  if node.keys.len == 0: return 0
  return (order div 2) - 1

proc borrowFromLeft[K, V](node: BTreeNode[K, V], parent: BTreeNode[K, V], parentIdx: int, order: int) =
  ## Borrow one key from the left sibling.
  let sibling = parent.children[parentIdx - 1]
  if node.isLeaf:
    # Borrow from leaf sibling
    let borrowKey = sibling.keys[^1]
    let borrowVal = sibling.values[^1]
    node.keys.insert(borrowKey, 0)
    node.values.insert(borrowVal, 0)
    sibling.keys.setLen(sibling.keys.len - 1)
    sibling.values.setLen(sibling.values.len - 1)
    parent.keys[parentIdx - 1] = node.keys[0]
  else:
    # Borrow from internal sibling
    let borrowKey = sibling.keys[^1]
    let borrowChild = sibling.children[^1]
    let parentSep = parent.keys[parentIdx - 1]
    node.keys.insert(parentSep, 0)
    node.children.insert(borrowChild, 0)
    sibling.keys.setLen(sibling.keys.len - 1)
    sibling.children.setLen(sibling.children.len - 1)
    parent.keys[parentIdx - 1] = borrowKey

proc borrowFromRight[K, V](node: BTreeNode[K, V], parent: BTreeNode[K, V], parentIdx: int, order: int) =
  ## Borrow one key from the right sibling.
  let sibling = parent.children[parentIdx + 1]
  if node.isLeaf:
    let borrowKey = sibling.keys[0]
    let borrowVal = sibling.values[0]
    node.keys.add(borrowKey)
    node.values.add(borrowVal)
    sibling.keys.delete(0)
    sibling.values.delete(0)
    parent.keys[parentIdx] = sibling.keys[0]
  else:
    let borrowKey = sibling.keys[0]
    let borrowChild = sibling.children[0]
    let parentSep = parent.keys[parentIdx]
    node.keys.add(parentSep)
    node.children.add(borrowChild)
    sibling.keys.delete(0)
    sibling.children.delete(0)
    parent.keys[parentIdx] = borrowKey

proc mergeWithLeft[K, V](node: BTreeNode[K, V], parent: BTreeNode[K, V], parentIdx: int) =
  ## Merge with left sibling, pulling down separator from parent.
  let sibling = parent.children[parentIdx - 1]
  let sepKey = parent.keys[parentIdx - 1]
  if node.isLeaf:
    # Leaf merge: do NOT insert separator key, just concatenate data entries
    for i in 0..<node.keys.len:
      sibling.keys.add(node.keys[i])
      sibling.values.add(node.values[i])
    sibling.next = node.next
  else:
    sibling.keys.add(sepKey)
    for i in 0..<node.keys.len:
      sibling.keys.add(node.keys[i])
    for i in 0..<node.children.len:
      sibling.children.add(node.children[i])
  parent.keys.delete(parentIdx - 1)
  parent.children.delete(parentIdx)

proc mergeWithRight[K, V](node: BTreeNode[K, V], parent: BTreeNode[K, V], parentIdx: int) =
  ## Merge with right sibling, pulling down separator from parent.
  let sibling = parent.children[parentIdx + 1]
  let sepKey = parent.keys[parentIdx]
  if node.isLeaf:
    # Leaf merge: do NOT insert separator key, just concatenate data entries
    for i in 0..<sibling.keys.len:
      node.keys.add(sibling.keys[i])
      node.values.add(sibling.values[i])
    node.next = sibling.next
  else:
    node.keys.add(sepKey)
    for i in 0..<sibling.keys.len:
      node.keys.add(sibling.keys[i])
    for i in 0..<sibling.children.len:
      node.children.add(sibling.children[i])
  parent.keys.delete(parentIdx)
  parent.children.delete(parentIdx + 1)

proc findParentOfKey[K, V](node: BTreeNode[K, V], target: BTreeNode[K, V]): (BTreeNode[K, V], int) =
  ## Find parent and index of target child. Returns (nil, -1) if not found.
  if node == nil: return (nil, -1)
  for i in 0..<node.children.len:
    if node.children[i] == target:
      return (node, i)
    let (p, idx) = findParentOfKey(node.children[i], target)
    if p != nil:
      return (p, idx)
  return (nil, -1)

proc rebalanceAfterDelete[K, V](node: BTreeNode[K, V], root: var BTreeNode[K, V], order: int) =
  ## Ensure node has enough keys after deletion. Borrow or merge if needed.
  if node.keys.len >= minKeysForLeaf(node, order):
    return

  let (parent, parentIdx) = findParentOfKey(root, node)
  if parent == nil:
    # This is the root; if empty, keep it empty
    return

  let hasLeft = parentIdx > 0
  let hasRight = parentIdx < parent.children.len - 1

  # Try to borrow from left sibling
  if hasLeft:
    let leftSibling = parent.children[parentIdx - 1]
    let minForLeft = minKeysForLeaf(leftSibling, order)
    if leftSibling.keys.len > minForLeft:
      borrowFromLeft(node, parent, parentIdx, order)
      return

  # Try to borrow from right sibling
  if hasRight:
    let rightSibling = parent.children[parentIdx + 1]
    let minForRight = minKeysForLeaf(rightSibling, order)
    if rightSibling.keys.len > minForRight:
      borrowFromRight(node, parent, parentIdx, order)
      return

  # Must merge with a sibling
  if hasLeft:
    mergeWithLeft(node, parent, parentIdx)
  elif hasRight:
    mergeWithRight(node, parent, parentIdx)

  # Recursively rebalance parent if it fell below minimum
  if parent == root and parent.keys.len == 0 and parent.children.len == 1:
    root = parent.children[0]

proc remove*[K, V](btree: var BTreeIndex[K, V], key: K, value: V) =
  acquire(btree.lock)
  try:
    proc removeRec(node: BTreeNode[K, V], root: var BTreeNode[K, V], order: int): bool =
      var i = 0
      while i < node.keys.len and key > node.keys[i]:
        inc i
      if node.isLeaf:
        # Traverse leaf linked list to find and remove ALL occurrences
        # of (key, value) across leaves (B+ tree boundary key duplicates).
        var cur: BTreeNode[K, V] = node
        var found = false
        while cur != nil:
          var j = 0
          while j < cur.keys.len and key > cur.keys[j]:
            inc j
          if j < cur.keys.len and key == cur.keys[j]:
            var vals = cur.values[j]
            var idx = -1
            for k in 0..<vals.len:
              if vals[k] == value:
                idx = k
                break
            if idx >= 0:
              vals.delete(idx)
              if vals.len == 0:
                cur.keys.delete(j)
                cur.values.delete(j)
              else:
                cur.values[j] = vals
              found = true
          if j < cur.keys.len and cur.keys[j] > key:
            break
          cur = cur.next
        return found
      else:
        # Internal node: recurse into child
        let child = node.children[i]
        let oldFirstKey = if child.keys.len > 0: child.keys[0] else: default(K)
        let found = removeRec(child, root, order)
        if found:
          # Update separator if child's first key changed.
          # Separator node.keys[i-1] represents child's first key (for i > 0).
          if i > 0 and child.keys.len > 0 and child.keys[0] != oldFirstKey:
            node.keys[i - 1] = child.keys[0]
          # Rebalance the child if needed
          rebalanceAfterDelete(child, root, order)
        return found

    if removeRec(btree.root, btree.root, btree.order):
      dec btree.size
      # Shrink root if it has only one child and is not a leaf
      if not btree.root.isLeaf and btree.root.keys.len == 0 and btree.root.children.len == 1:
        btree.root = btree.root.children[0]
  finally:
    release(btree.lock)
