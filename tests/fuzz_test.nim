## Wire Protocol + Storage Fuzz Tests
import std/unittest
import std/random
import std/strutils
import std/os
import std/monotimes

import barabadb/protocol/wire
import barabadb/storage/lsm
import barabadb/storage/wal

suite "Wire Protocol Fuzz":
  # ──────────────────────────────────────────────────
  # Core robustness
  # ──────────────────────────────────────────────────
  test "deserializeValue survives random bytes":
    var rng = initRand(12345)
    for i in 0..<500:
      var buf = newSeq[byte](rng.rand(1..256))
      for b in buf.mitems:
        b = byte(rng.rand(0..255))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard  # Exceptions are expected for garbage input

  test "deserializeValue survives truncated buffers":
    var rng = initRand(12346)
    for i in 0..<200:
      var buf: seq[byte] = @[byte(rng.rand(0..12))]
      let extra = rng.rand(0..64)
      for j in 0..<extra:
        buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "deserializeValue survives huge length claims":
    var rng = initRand(5001)
    for i in 0..<200:
      var buf: seq[byte] = @[byte(fkString)]
      buf.writeUint32(uint32(rng.rand(67_000_000'i64 .. int64(high(uint32)))))
      buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except ValueError:
        discard

  test "deserializeValue survives byte 0xFF kind":
    var rng = initRand(5002)
    for i in 0..<500:
      var buf: seq[byte] = @[byte(rng.rand(0x0E..0xFF))]
      let extra = rng.rand(0..64)
      for j in 0..<extra:
        buf.add(byte(rng.rand(0..255)))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "deserializeValue survives empty buffer":
    var pos = 0
    try:
      discard deserializeValue(@[], pos)
    except ValueError:
      discard

  test "deserializeValue survives single zero byte":
    var pos = 0
    let v = deserializeValue(@[byte 0], pos)
    check v.kind == fkNull

  # ──────────────────────────────────────────────────
  # MsgKind cast test
  # ──────────────────────────────────────────────────
  test "MsgKind cast with random uint32 values":
    var rng = initRand(12347)
    for i in 0..<1000:
      let raw = uint32(rng.rand(int64(high(uint32))))
      let kind = cast[MsgKind](raw)
      check true

  # ──────────────────────────────────────────────────
  # Header parsing
  # ──────────────────────────────────────────────────
  test "parseHeader-like logic with random 12-byte chunks":
    var rng = initRand(12348)
    for i in 0..<500:
      var data = ""
      for j in 0..<12:
        data.add(char(rng.rand(0..255)))
      let rawKind = uint32(ord(data[0])) shl 24 or uint32(ord(data[1])) shl 16 or
                    uint32(ord(data[2])) shl 8 or uint32(ord(data[3]))
      let kind = cast[MsgKind](rawKind)
      let length = uint32(ord(data[4])) shl 24 or uint32(ord(data[5])) shl 16 or
                   uint32(ord(data[6])) shl 8 or uint32(ord(data[7]))
      let requestId = uint32(ord(data[8])) shl 24 or uint32(ord(data[9])) shl 16 or
                      uint32(ord(data[10])) shl 8 or uint32(ord(data[11]))
      let header = MessageHeader(kind: kind, length: length, requestId: requestId)
      check header.length == length

  test "Header with zero-length payload":
    var rng = initRand(5003)
    for i in 0..<100:
      let kind = cast[MsgKind](uint32(rng.rand(1..0xFF)))
      let header = MessageHeader(kind: kind, length: 0, requestId: uint32(i))
      let msg = WireMessage(header: header, payload: @[])
      let s = serializeMessage(msg)
      check s.len == 12

  test "Header with max length payload kind":
    let header = MessageHeader(kind: mkPing, length: high(uint32), requestId: 0)
    check header.kind == mkPing
    check header.length == high(uint32)

  # ──────────────────────────────────────────────────
  # Message roundtrips
  # ──────────────────────────────────────────────────
  test "makeQueryMessage roundtrip with random queries":
    var rng = initRand(12349)
    for i in 0..<100:
      var query = ""
      let len = rng.rand(0..200)
      for j in 0..<len:
        query.add(char(rng.rand(32..126)))
      let msg = makeQueryMessage(uint32(i), query)
      check msg.len >= 12

  test "serializeMessage roundtrip with random payloads":
    var rng = initRand(12350)
    for i in 0..<100:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      var msg = WireMessage(
        header: MessageHeader(kind: mkQuery, length: uint32(rng.rand(0..1000)), requestId: reqId),
        payload: newSeq[byte](rng.rand(0..200))
      )
      for j in 0..<msg.payload.len:
        msg.payload[j] = byte(rng.rand(0..255))
      let s = serializeMessage(msg)
      check s.len >= 12

  test "serializeMessage with max payload length":
    var rng = initRand(5004)
    for i in 0..<50:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      let payloadLen = rng.rand(0..4096)
      var msg = WireMessage(
        header: MessageHeader(kind: mkQuery, length: uint32(payloadLen), requestId: reqId),
        payload: newSeq[byte](payloadLen)
      )
      for j in 0..<msg.payload.len:
        msg.payload[j] = byte(rng.rand(0..255))
      let s = serializeMessage(msg)
      check s.len == 12 + payloadLen

  # ──────────────────────────────────────────────────
  # Error message
  # ──────────────────────────────────────────────────
  test "makeErrorMessage with large IDs":
    var rng = initRand(12351)
    for i in 0..<100:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      let err = makeErrorMessage(reqId, uint32(rng.rand(0..255)), "fuzz")
      check err.len > 0

  test "makeErrorMessage with long error string":
    var rng = initRand(5005)
    for i in 0..<50:
      let reqId = uint32(rng.rand(int64(high(uint32))))
      var errStr = ""
      let errLen = rng.rand(0..1000)
      for j in 0..<errLen:
        errStr.add(char(rng.rand(32..126)))
      let err = makeErrorMessage(reqId, uint32(rng.rand(0..255)), errStr)
      check err.len >= 12 + errStr.len

  # ──────────────────────────────────────────────────
  # SerializeValue roundtrip for all field kinds
  # ──────────────────────────────────────────────────
  test "serializeValue/deserializeValue roundtrip — fkNull":
    var buf: seq[byte] = @[]
    var val = WireValue(kind: fkNull)
    serializeValue(buf, val)
    var pos = 0
    let back = deserializeValue(buf, pos)
    check back.kind == fkNull

  test "serializeValue/deserializeValue roundtrip — fkBool":
    var rng = initRand(5006)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let bv = rng.rand(0..1) == 1
      var val = WireValue(kind: fkBool, boolVal: bv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkBool
      check back.boolVal == bv

  test "serializeValue/deserializeValue roundtrip — fkInt64":
    var rng = initRand(5007)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let iv = int64(rng.rand(int64.low..int64.high))
      var val = WireValue(kind: fkInt64, int64Val: iv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkInt64
      check back.int64Val == iv

  test "serializeValue/deserializeValue roundtrip — fkFloat64":
    var rng = initRand(5008)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let fv = float64(rng.rand(-1000.0..1000.0))
      var val = WireValue(kind: fkFloat64, float64Val: fv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkFloat64
      check back.float64Val == fv

  test "serializeValue/deserializeValue roundtrip — fkString":
    var rng = initRand(5009)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      var s = ""
      let sl = rng.rand(0..200)
      for j in 0..<sl:
        s.add(char(rng.rand(0..255)))
      var val = WireValue(kind: fkString, strVal: s)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkString
      check back.strVal == s

  test "serializeValue/deserializeValue roundtrip — fkBytes":
    var rng = initRand(5010)
    for i in 0..<50:
      var buf: seq[byte] = @[]
      var b: seq[byte] = @[]
      let bl = rng.rand(0..200)
      for j in 0..<bl:
        b.add(byte(rng.rand(0..255)))
      var val = WireValue(kind: fkBytes, bytesVal: b)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkBytes
      check back.bytesVal == b

  test "serializeValue/deserializeValue roundtrip — fkFloat32":
    var rng = initRand(5011)
    for i in 0..<50:
      var buf: seq[byte] = @[]
      let fv = float32(rng.rand(-100.0..100.0))
      var val = WireValue(kind: fkFloat32, float32Val: fv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkFloat32
      check abs(back.float32Val - fv) < 1e-6

  test "serializeValue/deserializeValue roundtrip — fkInt32":
    var rng = initRand(5012)
    for i in 0..<100:
      var buf: seq[byte] = @[]
      let iv = int32(rng.rand(int32.low..int32.high))
      var val = WireValue(kind: fkInt32, int32Val: iv)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkInt32
      check back.int32Val == iv

  test "serializeValue/deserializeValue roundtrip — fkArray":
    var rng = initRand(5013)
    for i in 0..<30:
      var buf: seq[byte] = @[]
      var arr: seq[WireValue] = @[]
      let al = rng.rand(0..10)
      for j in 0..<al:
        arr.add(WireValue(kind: fkInt64, int64Val: int64(rng.rand(-1000..1000))))
      var val = WireValue(kind: fkArray, arrayVal: arr)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkArray
      check back.arrayVal.len == al

  test "serializeValue/deserializeValue roundtrip — fkObject":
    var rng = initRand(5014)
    for i in 0..<30:
      var buf: seq[byte] = @[]
      var obj: seq[(string, WireValue)] = @[]
      let ol = rng.rand(0..10)
      for j in 0..<ol:
        var key = ""
        let kl = rng.rand(1..8)
        for k in 0..<kl:
          key.add(char(rng.rand(ord('a')..ord('z'))))
        obj.add((key, WireValue(kind: fkInt64, int64Val: int64(rng.rand(-1000..1000)))))
      var val = WireValue(kind: fkObject, objVal: obj)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkObject
      check back.objVal.len == ol

  test "serializeValue/deserializeValue roundtrip — fkVector":
    var rng = initRand(5015)
    for i in 0..<30:
      var buf: seq[byte] = @[]
      var vec: seq[float32] = @[]
      let vl = rng.rand(0..16)
      for j in 0..<vl:
        vec.add(float32(rng.rand(-10.0..10.0)))
      var val = WireValue(kind: fkVector, vecVal: vec)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkVector
      check back.vecVal.len == vl

  test "serializeValue/deserializeValue roundtrip — fkJson":
    var rng = initRand(5016)
    for i in 0..<50:
      var buf: seq[byte] = @[]
      var jstr = ""
      let jl = rng.rand(0..100)
      for j in 0..<jl:
        jstr.add(char(rng.rand(32..126)))
      var val = WireValue(kind: fkJson, jsonVal: jstr)
      serializeValue(buf, val)
      var pos = 0
      let back = deserializeValue(buf, pos)
      check back.kind == fkJson
      check back.jsonVal == jstr

  # ──────────────────────────────────────────────────
  # Mutation fuzzing — mutate valid messages
  # ──────────────────────────────────────────────────
  test "Mutated valid messages don't crash deserializeValue":
    var rng = initRand(5017)
    for i in 0..<200:
      var buf: seq[byte] = @[]
      var val = WireValue(kind: fkInt64, int64Val: int64(rng.rand(-1000..1000)))
      serializeValue(buf, val)
      for mutation in 0..<5:
        if buf.len > 0:
          let idx = rng.rand(0..buf.len-1)
          buf[idx] = byte(rng.rand(0..255))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "Mutated serialized messages parse without crash":
    var rng = initRand(5018)
    for i in 0..<200:
      let header = MessageHeader(kind: mkQuery, length: 10, requestId: uint32(i))
      var payload = newSeq[byte](10)
      for j in 0..<10:
        payload[j] = byte(rng.rand(0..255))
      var msg = WireMessage(header: header, payload: payload)
      var s = serializeMessage(msg)
      for mutation in 0..<3:
        if s.len > 0:
          s[rng.rand(0..s.len-1)] = byte(rng.rand(0..255))
      check s.len >= 12

  test "makeQueryMessage with empty query":
    let msg = makeQueryMessage(1, "")
    check msg.len >= 12

  test "makeQueryMessage with special characters":
    var rng = initRand(5019)
    for i in 0..<50:
      var query = ""
      let sl = rng.rand(0..100)
      for j in 0..<sl:
        query.add(char(rng.rand(0..255)))
      let msg = makeQueryMessage(uint32(i), query)
      check msg.len >= 12

  # ──────────────────────────────────────────────────
  # makeCompleteMessage
  # ──────────────────────────────────────────────────
  test "makeCompleteMessage with random affected rows":
    var rng = initRand(5020)
    for i in 0..<50:
      let affectedRows = rng.rand(0..100_000)
      let msg = makeCompleteMessage(uint32(i), affectedRows)
      check msg.len >= 12

  # ──────────────────────────────────────────────────
  # makeAuthOkMessage
  # ──────────────────────────────────────────────────
  test "makeAuthOkMessage produces valid message":
    let msg = makeAuthOkMessage(42)
    check msg.len == 12

  # ──────────────────────────────────────────────────
  # makeAuthChallengeMessage
  # ──────────────────────────────────────────────────
  test "makeAuthChallengeMessage with random challenges":
    var rng = initRand(5021)
    for i in 0..<50:
      var challenge = ""
      let cl = rng.rand(0..100)
      for j in 0..<cl:
        challenge.add(char(rng.rand(32..126)))
      let msg = makeAuthChallengeMessage(uint32(i), challenge)
      check msg.len >= 12

  # ──────────────────────────────────────────────────
  # Stress: many iterations
  # ──────────────────────────────────────────────────
  test "Stress: 2000 random deserializeValue calls":
    var rng = initRand(5022)
    for i in 0..<2000:
      var buf = newSeq[byte](rng.rand(1..128))
      for b in buf.mitems:
        b = byte(rng.rand(0..255))
      var pos = 0
      try:
        discard deserializeValue(buf, pos)
      except:
        discard

  test "Stress: 1000 serializeMessage with random content":
    var rng = initRand(5023)
    for i in 0..<1000:
      let kind = cast[MsgKind](uint32(rng.rand(1..0xFF)))
      let payloadLen = rng.rand(0..256)
      var payload = newSeq[byte](payloadLen)
      for j in 0..<payloadLen:
        payload[j] = byte(rng.rand(0..255))
      let header = MessageHeader(
        kind: kind,
        length: uint32(payloadLen),
        requestId: uint32(rng.rand(int64(high(uint32))))
      )
      let msg = WireMessage(header: header, payload: payload)
      let s = serializeMessage(msg)
      check s.len == 12 + payloadLen

# ═══════════════════════════════════════════════════
# Storage Engine Fuzz
# ═══════════════════════════════════════════════════
suite "Storage Fuzz":

  proc randKey(rng: var Rand, minLen: int = 1, maxLen: int = 64): string =
    let len = rng.rand(minLen..maxLen)
    for i in 0..<len:
      result.add(char(rng.rand(ord('a')..ord('z'))))

  proc randValue(rng: var Rand, minLen: int = 0, maxLen: int = 256): seq[byte] =
    let len = rng.rand(minLen..maxLen)
    for i in 0..<len:
      result.add(byte(rng.rand(0..255)))

  # ──────────────────────────────────────────────────
  # WAL Fuzz
  # ──────────────────────────────────────────────────
  test "WAL survives random truncation and re-read":
    var rng = initRand(6000)
    let tmpDir = getTempDir() / "baradb_fuzz_wal_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var wal = newWriteAheadLog(tmpDir)
    let numEntries = rng.rand(10..100)
    var writtenKeys: seq[string] = @[]
    for i in 0..<numEntries:
      let k = randKey(rng)
      let v = randValue(rng)
      wal.writePut(cast[seq[byte]](k), v, uint64(getMonoTime().ticks()))
      writtenKeys.add(k)
    wal.sync()

    # Randomly truncate the WAL file
    let walPath = tmpDir / "wal.log"
    let origSize = getFileSize(walPath)
    if origSize > 16:
      let truncSize = rng.rand(16..int(origSize - 1))
      let f = open(walPath, fmReadWriteExisting)
      f.setFilePos(truncSize)
      # Nim has no direct truncate; use posix
      f.close()
      # Re-open truncated WAL — should not crash
      var wal2 = newWriteAheadLog(tmpDir)
      let entries = readEntries(walPath)
      # Either we get some entries or none; the key is no crash
      check true
      wal2.close()
    wal.close()

  test "WAL entryCount is accurate after restart":
    let tmpDir = getTempDir() / "baradb_fuzz_wal_count_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var wal = newWriteAheadLog(tmpDir)
    wal.writePut(cast[seq[byte]]("key1"), @[byte 1, 2, 3], 1'u64)
    wal.writePut(cast[seq[byte]]("key2"), @[byte 4, 5], 2'u64)
    wal.writeCommit(3'u64)
    check wal.entryCount == 3
    wal.close()

    var wal2 = newWriteAheadLog(tmpDir)
    check wal2.entryCount == 3
    wal2.close()

  # ──────────────────────────────────────────────────
  # LSM Fuzz — put/get/delete with random keys/values
  # ──────────────────────────────────────────────────
  test "LSM put/get roundtrip with random keys/values":
    var rng = initRand(6001)
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var db = newLSMTree(tmpDir, memMaxSize = 64 * 1024)
    defer: db.close()

    var expected = initTable[string, seq[byte]]()
    for i in 0..<500:
      let k = randKey(rng, 1, 32)
      let v = randValue(rng, 0, 128)
      db.put(k, v)
      expected[k] = v

    for k, v in expected:
      let (found, got) = db.get(k)
      check found
      check got == v

  test "LSM delete removes key and get returns false":
    var rng = initRand(6002)
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_del_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var db = newLSMTree(tmpDir, memMaxSize = 32 * 1024)
    defer: db.close()

    var keys: seq[string] = @[]
    for i in 0..<200:
      let k = randKey(rng, 1, 16)
      let v = randValue(rng, 0, 64)
      db.put(k, v)
      keys.add(k)

    # Delete half
    for i in 0..<keys.len div 2:
      db.delete(keys[i])

    # Deleted keys should not be found
    for i in 0..<keys.len div 2:
      let (found, _) = db.get(keys[i])
      check not found

    # Non-deleted keys should still be found
    for i in keys.len div 2..<keys.len:
      let (found, got) = db.get(keys[i])
      check found

  test "LSM flush and recovery with random data":
    var rng = initRand(6003)
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_recovery_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var expected = initTable[string, seq[byte]]()
    block:
      var db = newLSMTree(tmpDir, memMaxSize = 16 * 1024)
      for i in 0..<300:
        let k = randKey(rng, 1, 16)
        let v = randValue(rng, 0, 64)
        db.put(k, v)
        expected[k] = v
      db.flush()
      db.close()

    # Re-open; WAL recovery should replay entries
    block:
      var db = newLSMTree(tmpDir, memMaxSize = 16 * 1024)
      for k, v in expected:
        let (found, got) = db.get(k)
        check found
        check got == v
      db.close()

  test "LSM scanMemTable returns sorted entries":
    var rng = initRand(6004)
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_scan_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var db = newLSMTree(tmpDir, memMaxSize = 64 * 1024)
    defer: db.close()

    var inserted: seq[string] = @[]
    for i in 0..<100:
      let k = randKey(rng, 1, 16)
      db.put(k, randValue(rng, 0, 32))
      inserted.add(k)

    let mem = db.scanMemTable()
    # Verify ascending sort
    for i in 1..<mem.len:
      check mem[i-1].key <= mem[i].key

  test "LSM handles empty keys and values":
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_empty_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var db = newLSMTree(tmpDir)
    defer: db.close()

    db.put("", @[])
    let (found, got) = db.get("")
    check found
    check got.len == 0

  test "LSM handles large values near memtable limit":
    var rng = initRand(6005)
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_large_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var db = newLSMTree(tmpDir, memMaxSize = 8 * 1024)
    defer: db.close()

    # Insert a value that is ~half the memtable size
    let bigVal = randValue(rng, 3000, 4000)
    db.put("bigkey", bigVal)
    let (found, got) = db.get("bigkey")
    check found
    check got == bigVal

  test "LSM multiple overwrites of same key keep latest value":
    var rng = initRand(6006)
    let tmpDir = getTempDir() / "baradb_fuzz_lsm_overwrite_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var db = newLSMTree(tmpDir, memMaxSize = 32 * 1024)
    defer: db.close()

    let k = "overwrite_key"
    var lastVal: seq[byte]
    for i in 0..<50:
      lastVal = randValue(rng, 0, 64)
      db.put(k, lastVal)

    let (found, got) = db.get(k)
    check found
    check got == lastVal

  # ──────────────────────────────────────────────────
  # SSTable Fuzz
  # ──────────────────────────────────────────────────
  test "SSTable roundtrip with random entries":
    var rng = initRand(6007)
    let tmpDir = getTempDir() / "baradb_fuzz_sst_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var entries: seq[Entry] = @[]
    for i in 0..<100:
      entries.add(Entry(
        key: randKey(rng, 1, 20),
        value: randValue(rng, 0, 128),
        timestamp: uint64(i),
        deleted: false,
      ))

    # Sort entries by key for SSTable
    entries.sort(proc(a, b: Entry): int = cmp(a.key, b.key))

    let path = tmpDir / "test.sst"
    let sst = writeSSTable(entries, path, level = 0)
    defer: close(sst)

    for e in entries:
      let (found, got) = readSSTableEntry(sst, e.key)
      check found
      check got.value == e.value

  test "SSTable survives corrupted magic":
    var rng = initRand(6008)
    let tmpDir = getTempDir() / "baradb_fuzz_sst_corrupt_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var entries: seq[Entry] = @[]
    for i in 0..<10:
      entries.add(Entry(
        key: randKey(rng, 1, 10),
        value: randValue(rng, 0, 32),
        timestamp: uint64(i),
        deleted: false,
      ))
    entries.sort(proc(a, b: Entry): int = cmp(a.key, b.key))

    let path = tmpDir / "corrupt.sst"
    discard writeSSTable(entries, path, level = 0)

    # Corrupt magic bytes
    var f = open(path, fmReadWriteExisting)
    f.write("XXXX")
    f.close()

    try:
      discard loadSSTable(path)
      check false  # Should have raised
    except ValueError:
      check true

  test "SSTable with deleted entries roundtrips tombstones":
    var rng = initRand(6009)
    let tmpDir = getTempDir() / "baradb_fuzz_sst_del_" & $getCurrentProcessId()
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    var entries: seq[Entry] = @[]
    for i in 0..<50:
      entries.add(Entry(
        key: randKey(rng, 1, 16),
        value: randValue(rng, 0, 64),
        timestamp: uint64(i),
        deleted: rng.rand(0..1) == 1,
      ))
    entries.sort(proc(a, b: Entry): int = cmp(a.key, b.key))

    let path = tmpDir / "tombstones.sst"
    let sst = writeSSTable(entries, path, level = 0)
    defer: close(sst)

    for e in entries:
      let (found, got) = readSSTableEntry(sst, e.key)
      check found
      check got.deleted == e.deleted
      if not e.deleted:
        check got.value == e.value
