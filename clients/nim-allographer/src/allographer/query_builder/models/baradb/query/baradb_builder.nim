import std/json
import ../baradb_types
import ./baradb_generator


# ==================== SELECT ====================

proc selectBuilder*(self: BaradbQuery): string =
  return self
    .selectSql()
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereBetweenStringSql()
    .whereNotBetweenSql()
    .whereNotBetweenStringSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .limitSql()
    .offsetSql()
    .queryString


proc selectFirstBuilder*(self: BaradbQuery): string =
  return self
    .selectSql()
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereBetweenStringSql()
    .whereNotBetweenSql()
    .whereNotBetweenStringSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .selectFirstSql()
    .offsetSql()
    .queryString


proc selectFindBuilder*(self: BaradbQuery, key: string): string =
  return self
    .selectSql()
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereBetweenStringSql()
    .whereNotBetweenSql()
    .whereNotBetweenStringSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .selectByIdSql(key)
    .queryString


# ==================== INSERT ====================

proc insertValueBuilder*(self: BaradbQuery, items: JsonNode): string =
  return self
    .insertSql()
    .insertValueSql(items)
    .queryString


proc insertValuesBuilder*(self: BaradbQuery, rows: openArray[JsonNode]): string =
  return self
    .insertSql()
    .insertValuesSql(rows)
    .queryString


# ==================== UPDATE ====================

proc updateBuilder*(self: BaradbQuery, items: JsonNode): string =
  return self
    .updateSql()
    .updateValuesSql(items)
    .whereSql()
    .orWhereSql()
    .limitSql()
    .offsetSql()
    .queryString


# ==================== DELETE ====================

proc deleteBuilder*(self: BaradbQuery): string =
  return self
    .deleteSql()
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .limitSql()
    .offsetSql()
    .queryString


proc deleteByIdBuilder*(self: BaradbQuery, id: int, key: string): string =
  return self
    .deleteSql()
    .fromSql()
    .deleteByIdSql(id, key)
    .queryString


# ==================== Aggregates ====================

proc countBuilder*(self: BaradbQuery): string =
  return self
    .selectCountSql()
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereNotBetweenSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .limitSql()
    .offsetSql()
    .queryString


proc maxBuilder*(self: BaradbQuery, column: string): string =
  return self
    .selectMaxSql(column)
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereNotBetweenSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .limitSql()
    .offsetSql()
    .queryString


proc minBuilder*(self: BaradbQuery, column: string): string =
  return self
    .selectMinSql(column)
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereNotBetweenSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .limitSql()
    .offsetSql()
    .queryString


proc avgBuilder*(self: BaradbQuery, column: string): string =
  return self
    .selectAvgSql(column)
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereNotBetweenSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .limitSql()
    .offsetSql()
    .queryString


proc sumBuilder*(self: BaradbQuery, column: string): string =
  return self
    .selectSumSql(column)
    .fromSql()
    .joinSql()
    .leftJoinSql()
    .whereSql()
    .orWhereSql()
    .whereBetweenSql()
    .whereNotBetweenSql()
    .whereInSql()
    .whereNotInSql()
    .whereNullSql()
    .groupBySql()
    .havingSql()
    .orderBySql()
    .limitSql()
    .offsetSql()
    .queryString


proc columnBuilder*(self: BaradbQuery): string =
  return self
    .selectSql()
    .fromSql()
    .selectFirstSql()
    .queryString
