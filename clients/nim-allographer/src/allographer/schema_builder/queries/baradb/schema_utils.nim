import std/strformat
import ../../../query_builder/models/baradb/baradb_types
import ../../models/table

proc execThenSaveHistory*(rdb: BaradbConnections, name: string, queries: seq[string], checksum: string) =
  for sql in queries:
    discard waitFor rdb.raw(sql).exec()
  let hist = &"INSERT INTO `schema_migrations` (`name`, `checksum`) VALUES ('{name}', '{checksum}')"
  discard waitFor rdb.raw(hist).exec()

proc shouldRun*(rdb: BaradbConnections, table: Table, checksum: string, isReset: bool): bool =
  return true
