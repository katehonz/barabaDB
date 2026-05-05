## Memory-mapped I/O — mmap-based file access for SSTables
import std/os

const
  PageSize* = 4096

type
  MmapMode* = enum
    mmReadOnly
    mmReadWrite
    mmPrivate  # copy-on-write

  MmapRegion* = object
    data*: ptr UncheckedArray[byte]
    size*: int
    offset*: int64
    fd*: int
    mode*: MmapMode

  MmapFile* = ref object
    path*: string
    regions*: seq[MmapRegion]
    totalSize*: int
    pageSize*: int

# Linux mmap constants
const
  PROT_READ = 1
  PROT_WRITE = 2
  MAP_SHARED = 1
  MAP_PRIVATE = 2
  MAP_FAILED = cast[pointer](-1)

proc mmap(address: pointer, length: int, prot: int, flags: int,
          fd: int, offset: int64): pointer {.importc, header: "<sys/mman.h>".}
proc munmap(address: pointer, length: int): int {.importc, header: "<sys/mman.h>".}
proc madvise(address: pointer, length: int, advice: int): int {.importc, header: "<sys/mman.h>".}

const
  MADV_SEQUENTIAL = 2
  MADV_RANDOM = 1
  MADV_WILLNEED = 3
  MADV_DONTNEED = 4

proc openMmap*(path: string, mode: MmapMode = mmReadOnly): MmapFile =
  let fileSize = getFileSize(path)
  if fileSize == 0:
    return MmapFile(path: path, regions: @[], totalSize: 0, pageSize: PageSize)

  let fd = open(path, if mode == mmReadOnly: fmRead else: fmReadWrite)
  let prot = if mode == mmReadOnly: PROT_READ else: PROT_READ or PROT_WRITE
  let flags = if mode == mmPrivate: MAP_PRIVATE else: MAP_SHARED

  let mapped = mmap(nil, fileSize, prot, flags, fd, 0)
  if mapped == MAP_FAILED:
    close(fd)
    return MmapFile(path: path, regions: @[], totalSize: 0, pageSize: PageSize)

  let region = MmapRegion(
    data: cast[ptr UncheckedArray[byte]](mapped),
    size: fileSize,
    offset: 0,
    fd: fd,
    mode: mode,
  )

  MmapFile(
    path: path,
    regions: @[region],
    totalSize: fileSize,
    pageSize: PageSize,
  )

proc readAt*(mf: MmapFile, offset: int, size: int): seq[byte] =
  if mf.regions.len == 0:
    return @[]
  let region = mf.regions[0]
  if offset + size > region.size:
    return @[]
  result = newSeq[byte](size)
  copyMem(addr result[0], unsafeAddr region.data[offset], size)

proc readByte*(mf: MmapFile, offset: int): byte =
  if mf.regions.len == 0 or offset >= mf.regions[0].size:
    return 0
  return mf.regions[0].data[offset]

proc readUint32*(mf: MmapFile, offset: int): uint32 =
  if mf.regions.len == 0 or offset + 4 > mf.regions[0].size:
    return 0
  var val: uint32
  copyMem(addr val, unsafeAddr mf.regions[0].data[offset], 4)
  return val

proc readUint64*(mf: MmapFile, offset: int): uint64 =
  if mf.regions.len == 0 or offset + 8 > mf.regions[0].size:
    return 0
  var val: uint64
  copyMem(addr val, unsafeAddr mf.regions[0].data[offset], 8)
  return val

proc readString*(mf: MmapFile, offset: int, size: int): string =
  if mf.regions.len == 0 or offset + size > mf.regions[0].size:
    return ""
  result = newString(size)
  copyMem(addr result[0], unsafeAddr mf.regions[0].data[offset], size)

proc adviseSequential*(mf: MmapFile) =
  if mf.regions.len > 0:
    discard madvise(mf.regions[0].data, mf.regions[0].size, MADV_SEQUENTIAL)

proc adviseRandom*(mf: MmapFile) =
  if mf.regions.len > 0:
    discard madvise(mf.regions[0].data, mf.regions[0].size, MADV_RANDOM)

proc adviseWillNeed*(mf: MmapFile, offset: int, size: int) =
  if mf.regions.len > 0:
    discard madvise(addr mf.regions[0].data[offset], size, MADV_WILLNEED)

proc adviseDontNeed*(mf: MmapFile, offset: int, size: int) =
  if mf.regions.len > 0:
    discard madvise(addr mf.regions[0].data[offset], size, MADV_DONTNEED)

proc close*(mf: MmapFile) =
  for region in mf.regions:
    discard munmap(region.data, region.size)
    close(region.fd)
  mf.regions.setLen(0)

proc size*(mf: MmapFile): int = mf.totalSize
proc isOpen*(mf: MmapFile): bool = mf.regions.len > 0
