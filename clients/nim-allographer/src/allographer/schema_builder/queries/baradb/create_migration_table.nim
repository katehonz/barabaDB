import std/strformat
import ../../models/table
import ./baradb_query_type

proc createMigrationTable*(self: BaradbSchema) =
  let sql = """CREATE TABLE IF NOT EXISTS "schema_migrations" (
    "id" SERIAL PRIMARY KEY,
    "name" VARCHAR(255) NOT NULL,
    "checksum" VARCHAR(64) NOT NULL,
    "created_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  )"""
  discard waitFor self.rdb.raw(sql).exec()
