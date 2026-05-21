import std/json
import std/strformat
import std/strutils
import ../baradb_types


proc quote(input:string):string =
  var tmp = newSeq[string]()
  for segment in input.split("."):
    if segment.contains(" as "):
      let parts = segment.split(" as ", maxsplit = 1)
      let expression = parts[0]
      let alias = parts[1]
      if expression.contains("("):
        let funcStart = expression.find('(')
        let funcEnd = expression.find(')', funcStart)
        let funcName = expression[0 ..< funcStart]
        let columnName = expression[funcStart + 1 ..< funcEnd]
        tmp.add(&"{funcName}(`{columnName}`) as `{alias}`")
      else:
        tmp.add(&"`{expression}` as `{alias}`")
    elif segment.contains("("):
      tmp.add(segment)
    else:
      tmp.add(&"`{segment}`")
  return tmp.join(".")


# ==================== SELECT ====================

proc selectSql*(self: BaradbQuery): BaradbQuery =
  var queryString = ""

  if self.query.hasKey("distinct"):
    queryString.add("SELECT DISTINCT")
  else:
    queryString.add("SELECT")

  if self.query.hasKey("select"):
    for i, item in self.query["select"].getElems():
      if i > 0: queryString.add(",")
      var column = item.getStr()
      if column != "*": column = quote(column)
      queryString.add(&" {column}")
  else:
    queryString.add(" *")

  self.queryString = queryString
  return self


proc fromSql*(self: BaradbQuery): BaradbQuery =
  let table = self.query["table"].getStr()
  self.queryString.add(&" FROM `{table}`")
  return self


proc selectFirstSql*(self: BaradbQuery): BaradbQuery =
  self.queryString.add(" LIMIT 1")
  return self


proc selectByIdSql*(self: BaradbQuery, key: string): BaradbQuery =
  let key = key.quote()
  if self.queryString.contains("WHERE"):
    self.queryString.add(&" AND {key} = ? LIMIT 1")
  else:
    self.queryString.add(&" WHERE {key} = ? LIMIT 1")
  return self


proc joinSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("join"):
    for row in self.query["join"]:
      let table = row["table"].getStr().quote()
      let column1 = row["column1"].getStr().quote()
      let symbol = row["symbol"].getStr()
      let column2 = row["column2"].getStr().quote()

      self.queryString.add(&" INNER JOIN {table} ON {column1} {symbol} {column2}")
  return self


proc leftJoinSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("left_join"):
    for row in self.query["left_join"]:
      let table = row["table"].getStr().quote()
      let column1 = row["column1"].getStr().quote()
      let symbol = row["symbol"].getStr()
      let column2 = row["column2"].getStr().quote()

      self.queryString.add(&" LEFT JOIN {table} ON {column1} {symbol} {column2}")
  return self


proc whereSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where"):
    for i, row in self.query["where"].getElems():
      let column = row["column"].getStr().quote()
      let symbol = row["symbol"].getStr()
      if i == 0:
        self.queryString.add(&" WHERE {column} {symbol} ?")
      else:
        self.queryString.add(&" AND {column} {symbol} ?")
  return self


proc orWhereSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("or_where"):
    for row in self.query["or_where"]:
      let column = row["column"].getStr().quote()
      let symbol = row["symbol"].getStr()

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" OR {column} {symbol} ?")
      else:
        self.queryString.add(&" WHERE {column} {symbol} ?")
  return self


proc whereBetweenSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_between"):
    for row in self.query["where_between"]:
      let column = row["column"].getStr().quote()

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} BETWEEN ? AND ?")
      else:
        self.queryString.add(&" WHERE {column} BETWEEN ? AND ?")
  return self


proc whereBetweenStringSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_between_string"):
    for row in self.query["where_between_string"]:
      let column = row["column"].getStr().quote()

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} BETWEEN ? AND ?")
      else:
        self.queryString.add(&" WHERE {column} BETWEEN ? AND ?")
  return self


proc whereNotBetweenSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_not_between"):
    for row in self.query["where_not_between"]:
      let column = row["column"].getStr().quote()

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} NOT BETWEEN ? AND ?")
      else:
        self.queryString.add(&" WHERE {column} NOT BETWEEN ? AND ?")
  return self


proc whereNotBetweenStringSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_not_between_string"):
    for row in self.query["where_not_between_string"]:
      let column = row["column"].getStr().quote()

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} NOT BETWEEN ? AND ?")
      else:
        self.queryString.add(&" WHERE {column} NOT BETWEEN ? AND ?")
  return self


proc whereInSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_in"):
    var widthString = ""
    for row in self.query["where_in"]:
      let column = row["column"].getStr().quote()
      for i, val in row["width"].getElems():
        if i > 0: widthString.add(", ")
        widthString.add("?")

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} IN ({widthString})")
      else:
        self.queryString.add(&" WHERE {column} IN ({widthString})")
  return self


proc whereNotInSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_not_in"):
    var widthString = ""
    for row in self.query["where_not_in"]:
      let column = row["column"].getStr().quote()
      for i, val in row["width"].getElems():
        if i > 0: widthString.add(", ")
        widthString.add("?")

      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} NOT IN ({widthString})")
      else:
        self.queryString.add(&" WHERE {column} NOT IN ({widthString})")
  return self


proc whereNullSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("where_null"):
    for row in self.query["where_null"]:
      let column = row["column"].getStr().quote()
      let symbol = row["symbol"].getStr()
      if self.queryString.contains("WHERE"):
        self.queryString.add(&" AND {column} {symbol} null")
      else:
        self.queryString.add(&" WHERE {column} {symbol} null")
  return self


proc groupBySql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("group_by"):
    for row in self.query["group_by"]:
      let column = row["column"].getStr().quote()
      if self.queryString.contains("GROUP BY"):
        self.queryString.add(&", {column}")
      else:
        self.queryString.add(&" GROUP BY {column}")
  return self


proc havingSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("having"):
    for i, row in self.query["having"].getElems():
      let column = row["column"].getStr().quote()
      let symbol = row["symbol"].getStr()

      if i == 0:
        self.queryString.add(&" HAVING {column} {symbol} ?")
      else:
        self.queryString.add(&" AND {column} {symbol} ?")

  return self


proc orderBySql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("order_by"):
    for row in self.query["order_by"]:
      let column = row["column"].getStr().quote()
      let order = row["order"].getStr()

      if self.queryString.contains("ORDER BY"):
        self.queryString.add(&", {column} {order}")
      else:
        self.queryString.add(&" ORDER BY {column} {order}")
  return self


proc limitSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("limit"):
    let num = self.query["limit"].getInt()
    self.queryString.add(&" LIMIT {num}")

  return self


proc offsetSql*(self: BaradbQuery): BaradbQuery =
  if self.query.hasKey("offset"):
    let num = self.query["offset"].getInt()
    self.queryString.add(&" OFFSET {num}")

  return self


# ==================== INSERT ====================

proc insertSql*(self: BaradbQuery): BaradbQuery =
  let table = self.query["table"].getStr()
  self.queryString = &"INSERT INTO `{table}`"
  return self


proc insertValueSql*(self: BaradbQuery, items: JsonNode): BaradbQuery =
  var columns = ""
  var values = ""

  var i = 0
  for key, val in items.pairs:
    defer: i += 1
    if i > 0:
      columns.add(", ")
      values.add(", ")
    columns.add(&"`{key}`")

    self.placeHolder.add(%*{"key": key, "value": val})
    values.add("?")

  self.queryString.add(&" ({columns}) VALUES ({values})")
  return self


proc insertValuesSql*(self: BaradbQuery, rows: openArray[JsonNode]): BaradbQuery =
  var columns = ""

  var i = 0
  for key, value in rows[0]:
    defer: i += 1
    if i > 0: columns.add(", ")
    columns.add(&"`{key}`")

  var values = ""
  var valuesCount = 0
  for items in rows:
    var valueCount = 0
    var value = ""
    for key, val in items.pairs:
      defer: valueCount += 1
      if valueCount > 0: value.add(", ")

      self.placeHolder.add(%*{"key": key, "value": val})
      value.add("?")

    if valuesCount > 0: values.add(", ")
    valuesCount += 1
    values.add(&"({value})")

  self.queryString.add(&" ({columns}) VALUES {values}")
  return self


# ==================== UPDATE ====================

proc updateSql*(self: BaradbQuery): BaradbQuery =
  var queryString = ""
  queryString.add("UPDATE")

  var table = self.query["table"].getStr()
  queryString.add(&" `{table}` SET")
  self.queryString = queryString
  return self


proc updateValuesSql*(self: BaradbQuery, items: JsonNode): BaradbQuery =
  var value = ""
  let placeHolder = newJArray()

  var i = 0
  for key, val in items.pairs:
    defer: i += 1
    if i > 0: value.add(",")
    value.add(&" `{key}` = ?")
    placeHolder.add(%*{"key": key, "value": val})

  for row in self.placeHolder.items:
    placeHolder.add(row)

  self.placeHolder = placeHolder

  self.queryString.add(value)
  return self


# ==================== DELETE ====================

proc deleteSql*(self: BaradbQuery): BaradbQuery =
  self.queryString = "DELETE"
  return self


proc deleteByIdSql*(self: BaradbQuery, id: int, key: string): BaradbQuery =
  self.queryString.add(&" WHERE `{key}` = ?")
  return self


# ==================== Aggregates ====================

proc selectCountSql*(self: BaradbQuery): BaradbQuery =
  let queryString =
    if self.query.hasKey("select"):
      let column = self.query["select"][0].getStr
      &"`{column}`"
    else:
      "*"
  self.queryString = &"SELECT count({queryString}) as aggregate"
  return self


proc selectMaxSql*(self: BaradbQuery, column: string): BaradbQuery =
  self.queryString = &"SELECT max(`{column}`) as aggregate"
  return self


proc selectMinSql*(self: BaradbQuery, column: string): BaradbQuery =
  self.queryString = &"SELECT min(`{column}`) as aggregate"
  return self


proc selectAvgSql*(self: BaradbQuery, column: string): BaradbQuery =
  self.queryString = &"SELECT avg(`{column}`) as aggregate"
  return self


proc selectSumSql*(self: BaradbQuery, column: string): BaradbQuery =
  self.queryString = &"SELECT sum(`{column}`) as aggregate"
  return self
