import std/tables
import std/sets
import std/algorithm
import std/locks

type
  FacetField* = object
    name*: string
    values*: Table[string, HashSet[uint64]]

  FacetIndex* = ref object
    fields*: Table[string, FacetField]
    lock*: Lock

  FacetCount* = object
    value*: string
    count*: int

  FacetFilter* = object
    field*: string
    values*: seq[string]
    exclude*: bool

proc newFacetIndex*(): FacetIndex =
  result = FacetIndex(fields: initTable[string, FacetField]())
  initLock(result.lock)

proc addDocument*(idx: FacetIndex, docId: uint64,
                  facets: Table[string, seq[string]]) =
  acquire(idx.lock)
  try:
    for fieldName, vals in facets:
      if fieldName notin idx.fields:
        idx.fields[fieldName] = FacetField(
          name: fieldName,
          values: initTable[string, HashSet[uint64]](),
        )
      for v in vals:
        if v notin idx.fields[fieldName].values:
          idx.fields[fieldName].values[v] = initHashSet[uint64]()
        idx.fields[fieldName].values[v].incl(docId)
  finally:
    release(idx.lock)

proc removeDocument*(idx: FacetIndex, docId: uint64) =
  acquire(idx.lock)
  try:
    for fieldName, field in idx.fields.mpairs:
      var emptyKeys: seq[string] = @[]
      for val, docIds in field.values.mpairs:
        docIds.excl(docId)
        if docIds.len == 0:
          emptyKeys.add(val)
      for key in emptyKeys:
        field.values.del(key)
  finally:
    release(idx.lock)

proc updateDocument*(idx: FacetIndex, docId: uint64,
                     facets: Table[string, seq[string]]) =
  idx.removeDocument(docId)
  idx.addDocument(docId, facets)

proc getFacetCounts*(idx: FacetIndex, field: string,
                     candidateDocs: HashSet[uint64] = initHashSet[uint64](),
                     limit: int = 10): seq[FacetCount] =
  acquire(idx.lock)
  try:
    result = @[]
    if field notin idx.fields:
      return
    let useFilter = candidateDocs.len > 0
    for val, docIds in idx.fields[field].values:
      var count = 0
      if useFilter:
        for docId in docIds:
          if docId in candidateDocs:
            inc count
      else:
        count = docIds.len
      if count > 0:
        result.add(FacetCount(value: val, count: count))
    result.sort(proc(a, b: FacetCount): int = cmp(b.count, a.count))
    if result.len > limit:
      result = result[0..<limit]
  finally:
    release(idx.lock)

proc filterByFacets*(idx: FacetIndex, filters: seq[FacetFilter]): HashSet[uint64] =
  acquire(idx.lock)
  try:
    result = initHashSet[uint64]()
    if filters.len == 0:
      return
    var first = true
    for filter in filters:
      var filterDocs = initHashSet[uint64]()
      if filter.field in idx.fields:
        for val in filter.values:
          if val in idx.fields[filter.field].values:
            filterDocs = filterDocs + idx.fields[filter.field].values[val]
      if filter.exclude:
        var allFieldDocs = initHashSet[uint64]()
        if filter.field in idx.fields:
          for val, docIds in idx.fields[filter.field].values:
            allFieldDocs = allFieldDocs + docIds
        filterDocs = allFieldDocs - filterDocs
      if first:
        result = filterDocs
        first = false
      else:
        result = result * filterDocs
  finally:
    release(idx.lock)

proc aggregate*(idx: FacetIndex, fields: seq[string],
                candidateDocs: HashSet[uint64] = initHashSet[uint64](),
                limit: int = 10): Table[string, seq[FacetCount]] =
  result = initTable[string, seq[FacetCount]]()
  for field in fields:
    result[field] = idx.getFacetCounts(field, candidateDocs, limit)
