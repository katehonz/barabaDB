# Package
version       = "0.1.0"
author        = "BaraDB Team"
description   = "BaraDB — Multimodal database written in Nim"
license       = "Apache-2.0"
srcDir        = "src"
bin           = @["baradadb"]
binDir        = "build"

switch("define", "ssl")

# Dependencies
requires "nim >= 2.2.0"
requires "https://github.com/katehonz/hunos >= 1.2.0"
requires "jwt >= 0.3.0"
requires "checksums >= 0.2.0"

# Tasks
task build_debug, "Build debug version":
  exec "nim c -d:ssl --debugger:native --linedir:on -o:build/baradadb src/baradadb.nim"

task build_release, "Build release version":
  exec "nim c -d:ssl -d:release --opt:speed -o:build/baradadb src/baradadb.nim"

task test, "Run all tests":
  exec "nim c -d:ssl -r tests/test_all.nim"

task bench, "Run benchmarks":
  exec "nim c -d:ssl -d:release -r benchmarks/bench_storage.nim"
