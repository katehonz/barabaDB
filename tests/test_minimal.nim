import std/unittest
import barabadb/core/types

suite "Minimal":
  test "Value creation":
    let v = Value(kind: vkInt, intVal: 42)
    check v.intVal == 42
