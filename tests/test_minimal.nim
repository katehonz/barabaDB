import std/unittest
import barabadb/core/types

suite "Minimal":
  test "Value creation":
    let v = Value(kind: vkInt64, int64Val: 42)
    check v.int64Val == 42
