## BaraDB Structured JSON Logger
import std/json
import std/times
import std/os

type
  LogLevel* = enum
    llDebug = 0
    llInfo = 1
    llWarn = 2
    llError = 3

  Logger* = ref object
    level*: LogLevel
    output*: File

var defaultLogger* = Logger(level: llInfo, output: stdout)

proc newLogger*(level: LogLevel = llInfo, filepath: string = ""): Logger =
  var f = stdout
  if filepath.len > 0:
    f = open(filepath, fmAppend)
  Logger(level: level, output: f)

proc log*(logger: Logger, level: LogLevel, msg: string, extra: JsonNode = newJNull()) =
  if level < logger.level: return
  let entry = %*{
    "ts": $now(),
    "level": $level,
    "msg": msg,
    "extra": extra
  }
  logger.output.writeLine($entry)
  logger.output.flushFile()

proc log*(msg: string, level: LogLevel = llInfo) =
  defaultLogger.log(level, msg)

proc debug*(msg: string) = defaultLogger.log(llDebug, msg)
proc info*(msg: string) = defaultLogger.log(llInfo, msg)
proc warn*(msg: string) = defaultLogger.log(llWarn, msg)
proc errorMsg*(msg: string) = defaultLogger.log(llError, msg)

proc setLevel*(logger: Logger, level: LogLevel) =
  logger.level = level

proc close*(logger: Logger) =
  if logger.output != stdout:
    logger.output.close()
