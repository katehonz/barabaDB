import std/strformat
import ../../models/table
import ./baradb_query_type

proc createMigrationTable*(self: BaradbSchema) =
  ## BaraDB tracks migrations natively via BaraQL (CREATE MIGRATION, MIGRATION STATUS).
  ## No client-side migration table needed — server stores state in LSM-Tree.
  discard