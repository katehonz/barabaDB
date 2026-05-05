## B-Tree Index — ordered key-value index
import std/tables

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

proc newBTreeNode[K, V](isLeaf: bool = true): BTreeNode[K, V] =
  BTreeNode[K, V](
    keys: @[], values: @[], children: @[],
    isLeaf: isLeaf, next: nil,
  )

proc newBTreeIndex*[K, V](order: int = DefaultBTreeOrder): BTreeIndex[K, V] =
  BTreeIndex[K, V](root: newBTreeNode[K, V](), order: order, size: 0)

proc search[K, V](node: BTreeNode[K, V], key: K): seq[V] =
  var i = 0
  while i < node.keys.len and key > node.keys[i]:
    inc i
  if node.isLeaf:
    if i < node.keys.len and key == node.keys[i]:
      return node.values[i]
    return @[]
  else:
    return search(node.children[i], key)

proc splitChild[K, V](parent: BTreeNode[K, V], index: int, order: int) =
  let child = parent.children[index]
  let mid = (order - 1) div 2
  let newNode = newBTreeNode[K, V](child.isLeaf)

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
  child.keys.setLen(mid)
  if child.isLeaf:
    child.values.setLen(mid)

proc insertNonFull[K, V](node: BTreeNode[K, V], key: K, value: V, order: int) =
  var i = node.keys.len - 1
  if node.isLeaf:
    while i >= 0 and key < node.keys[i]:
      dec i
    if i >= 0 and key == node.keys[i]:
      node.values[i].add(value)
      return
    node.keys.insert(key, i + 1)
    node.values.insert(@[value], i + 1)
  else:
    while i >= 0 and key < node.keys[i]:
      dec i
    inc i
    if node.children[i].keys.len == order - 1:
      splitChild(node, i, order)
      if key > node.keys[i]:
        inc i
    insertNonFull(node.children[i], key, value, order)

proc insert*[K, V](btree: var BTreeIndex[K, V], key: K, value: V) =
  if btree.root.keys.len == btree.order - 1:
    var newRoot = newBTreeNode[K, V](isLeaf = false)
    newRoot.children.add(btree.root)
    splitChild(newRoot, 0, btree.order)
    btree.root = newRoot
    insertNonFull(btree.root, key, value, btree.order)
  else:
    insertNonFull(btree.root, key, value, btree.order)
  inc btree.size

proc get*[K, V](btree: BTreeIndex[K, V], key: K): seq[V] =
  search(btree.root, key)

proc contains*[K, V](btree: BTreeIndex[K, V], key: K): bool =
  return btree.get(key).len > 0

proc scan*[K, V](btree: BTreeIndex[K, V], startKey, endKey: K): seq[(K, seq[V])] =
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

proc len*[K, V](btree: BTreeIndex[K, V]): int = btree.size
