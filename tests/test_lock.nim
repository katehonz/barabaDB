import std/unittest
import std/locks
import barabadb/storage/lsm

suite "Lock test":
  test "initLock works":
    var l: Lock
    initLock(l)
    acquire(l)
    release(l)
    check true

  test "newLSMTree works":
    var db = newLSMTree("/tmp/test_lock_lsm")
    check db != nil
    db.put("key1", @[1'u8, 2'u8])
    check true
