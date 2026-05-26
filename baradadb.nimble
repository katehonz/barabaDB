# Package
version       = "1.1.6"
author        = "BaraDB Team"
description   = "BaraDB — Multimodal database written in Nim"
license       = "Apache-2.0"
srcDir        = "src"
bin           = @["baradadb", "baramcp"]
binDir        = "build"

# Dependencies
requires "nim >= 2.2.0"
requires "https://github.com/katehonz/hunos >= 1.3.0"
requires "https://github.com/katehonz/jwt-nim-baraba#fbe084b" # v2.1.2 - security fixes & Nim 2.2 compat
requires "checksums >= 0.2.0"

# Tasks
task build_debug, "Build debug version":
  exec "nim c --debugger:native --linedir:on -o:build/baradadb src/baradadb.nim"
  exec "nim c --debugger:native --linedir:on -o:build/baramcp src/baramcp.nim"

task build_release, "Build release version":
  exec "nim c -d:release --opt:speed -o:build/baradadb src/baradadb.nim"
  exec "nim c -d:release --opt:speed -o:build/baramcp src/baramcp.nim"

task test, "Run all tests":
  exec "nim c -r tests/test_all.nim"

task bench, "Run benchmarks":
  exec "nim c -d:release -r benchmarks/bench_all.nim"
