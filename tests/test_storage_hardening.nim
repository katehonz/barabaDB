## Focused storage hardening tests (avoids full suite compile issues)
import std/unittest
import std/os
import std/locks
import barabadb/storage/lsm
import barabadb/storage/rwlock
import barabadb/storage/gate

suite "Core Storage Hardening":
  test "MemTable overwrite keeps newest value":
    let testDir = "/tmp/baradb_th_mem"
    removeDir(testDir)
    var db = newLSMTree(testDir, 64 * 1024)
    db.put("k", cast[seq[byte]]("v1"))
    db.put("k", cast[seq[byte]]("v3"))
    let (found, val) = db.get("k")
    check found
    check cast[string](val) == "v3"
    db.close()

  test "scanRange inclusive":
    let testDir = "/tmp/baradb_th_range"
    removeDir(testDir)
    var db = newLSMTree(testDir, 256)
    for ch in ['a', 'b', 'c', 'd', 'e']:
      db.put($ch, cast[seq[byte]]("v" & $ch))
    db.flush()
    db.put("c", cast[seq[byte]]("vC2"))
    let rows = db.scanRange("b", "d")
    check rows.len == 3
    check rows[0][0] == "b"
    check rows[1][0] == "c"
    check cast[string](rows[1][1]) == "vC2"
    db.close()

  test "WAL group commit":
    let testDir = "/tmp/baradb_th_group"
    removeDir(testDir)
    const n = 200
    const ge = 50
    var db = newLSMTree(testDir, 8 * 1024 * 1024,
                        walSyncMode = wsmGroup, walGroupEvery = ge)
    let base = db.wal.fsyncCount
    for i in 0 ..< n:
      db.put("g" & $i, cast[seq[byte]]("v"))
    let after = db.wal.fsyncCount - base
    check after >= uint64(n div ge)
    check after < uint64(n)
    db.close()

  test "RwLock concurrent readers":
    var rw: RwLock
    initRwLock(rw)
    var counter = 0
    var maxReaders = 0
    var curReaders = 0
    var metaLock: Lock
    initLock(metaLock)
    var bad = false

    type TArgs = object
      rw: ptr RwLock
      meta: ptr Lock
      counter: ptr int
      curReaders: ptr int
      maxReaders: ptr int
      bad: ptr bool
      isWriter: bool

    proc worker(a: TArgs) {.thread, gcsafe.} =
      for i in 0 ..< 200:
        if a.isWriter:
          acquireWrite(a.rw[])
          a.counter[] += 1
          acquire(a.meta[])
          if a.curReaders[] != 0:
            a.bad[] = true
          release(a.meta[])
          releaseWrite(a.rw[])
        else:
          acquireRead(a.rw[])
          acquire(a.meta[])
          inc a.curReaders[]
          if a.curReaders[] > a.maxReaders[]:
            a.maxReaders[] = a.curReaders[]
          release(a.meta[])
          var x = 0
          for k in 0 ..< 50: x += k
          discard x
          acquire(a.meta[])
          dec a.curReaders[]
          release(a.meta[])
          releaseRead(a.rw[])

    var threads: array[8, Thread[TArgs]]
    for t in 0 ..< 8:
      let args = TArgs(
        rw: addr rw, meta: addr metaLock,
        counter: addr counter, curReaders: addr curReaders,
        maxReaders: addr maxReaders, bad: addr bad,
        isWriter: t == 0 or t == 1,
      )
      createThread(threads[t], worker, args)
    for t in 0 ..< 8:
      joinThread(threads[t])

    check not bad
    check counter == 400
    check maxReaders >= 2
    deinitLock(metaLock)
    deinitRwLock(rw)

  test "Interleaved put/get/flush single-threaded stress":
    ## ORC is not multi-thread-safe for shared refs; stress the exclusive path serially.
    let testDir = "/tmp/baradb_th_stress"
    removeDir(testDir)
    var db = newLSMTree(testDir, 4 * 1024, walSyncMode = wsmGroup, walGroupEvery = 32)
    for i in 0 ..< 2000:
      db.put("k" & $i, cast[seq[byte]]("v" & $i))
      if i mod 100 == 0:
        let (f, v) = db.get("k0")
        check f and cast[string](v) == "v0"
      if i mod 400 == 0:
        db.flush()
    for i in [0, 500, 1000, 1999]:
      let (f, v) = db.get("k" & $i)
      check f and cast[string](v) == "v" & $i
    db.close()

  test "StorageGate serializes concurrent critical sections":
    initStorageGate()
    var counter = 0
    var bad = false
    var meta: Lock
    initLock(meta)

    type GArgs = object
      n: int
      counter: ptr int
      bad: ptr bool
      meta: ptr Lock

    proc worker(a: GArgs) {.thread, gcsafe.} =
      for i in 0 ..< a.n:
        withStorageGate:
          # Under the gate, only one thread should touch counter
          let before = a.counter[]
          a.counter[] = before + 1
          # Simulate work
          var x = 0
          for k in 0 ..< 20: x += k
          discard x
          if a.counter[] != before + 1:
            acquire(a.meta[])
            a.bad[] = true
            release(a.meta[])

    var threads: array[6, Thread[GArgs]]
    for t in 0 ..< 6:
      createThread(threads[t], worker, GArgs(
        n: 100, counter: addr counter, bad: addr bad, meta: addr meta))
    for t in 0 ..< 6:
      joinThread(threads[t])

    check not bad
    check counter == 600
    deinitLock(meta)