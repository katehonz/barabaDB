import std/asyncdispatch
import std/json
import std/options
import std/strutils
import std/times
import ../../enums
import ./baradb_types


# ================================================================================
# query
# ================================================================================

proc select*(self: BaradbConnections, columnsArg: varargs[string]): BaradbQuery =
  let query = newJObject()

  if columnsArg.len == 0 or columnsArg[0] == "*":
    query["select"] = %["*"]
  else:
    query["select"] = %columnsArg

  let baradbQuery = BaradbQuery(
    log: self.log,
    pools: self.pools,
    query: query,
    queryString: "",
    placeHolder: newJArray(),
    isInTransaction: self.isInTransaction,
    transactionConn: self.transactionConn,
  )
  return baradbQuery


proc table*(self: BaradbConnections, tableArg: string): BaradbQuery =
  let query = newJObject()
  query["table"] = %tableArg

  let baradbQuery = BaradbQuery(
    log: self.log,
    pools: self.pools,
    query: query,
    queryString: "",
    placeHolder: newJArray(),
    isInTransaction: self.isInTransaction,
    transactionConn: self.transactionConn,
  )
  return baradbQuery


proc table*(self: BaradbQuery, tableArg: string): BaradbQuery =
  self.query["table"] = %tableArg
  return self


proc `distinct`*(self: BaradbQuery): BaradbQuery =
  self.query["distinct"] = %true
  return self


# ============================== Conditions ==============================

proc join*(self: BaradbQuery, table: string, column1: string, symbol: string,
            column2: string): BaradbQuery =
  if self.query.hasKey("join") == false:
    self.query["join"] = %*[{
      "table": table,
      "column1": column1,
      "symbol": symbol,
      "column2": column2
    }]
  else:
    self.query["join"].add(%*{
      "table": table,
      "column1": column1,
      "symbol": symbol,
      "column2": column2
    })
  return self


proc leftJoin*(self: BaradbQuery, table: string, column1: string, symbol: string,
              column2: string): BaradbQuery =
  if self.query.hasKey("left_join") == false:
    self.query["left_join"] = %*[{
      "table": table,
      "column1": column1,
      "symbol": symbol,
      "column2": column2
    }]
  else:
    self.query["left_join"].add(%*{
      "table": table,
      "column1": column1,
      "symbol": symbol,
      "column2": column2
    })
  return self


const whereSymbols = ["is", "is not", "=", "!=", "<", "<=", ">=", ">", "<>", "LIKE","%LIKE","LIKE%","%LIKE%"]
const whereSymbolsError = """Arg position 3 is only allowed of ["is", "is not", "=", "!=", "<", "<=", ">=", ">", "<>", "LIKE","%LIKE","LIKE%","%LIKE%"]"""

proc where*(self: BaradbQuery, column: string, symbol: string,
            value: string|int|float): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  self.placeHolder.add(%*{"key": column, "value": value})

  if self.query.hasKey("where") == false:
    self.query["where"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "?"
    }]
  else:
    self.query["where"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "?"
    })
  return self


proc where*(self: BaradbQuery, column: string, symbol: string,
            value: bool): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  self.placeHolder.add(%*{"key": column, "value": value})

  if self.query.hasKey("where") == false:
    self.query["where"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "?"
    }]
  else:
    self.query["where"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "?"
    })
  return self


proc where*(self: BaradbQuery, column: string, symbol: string, value: nil.type): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  if self.query.hasKey("where") == false:
    self.query["where"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "null"
    }]
  else:
    self.query["where"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "null"
    })
  return self


proc orWhere*(self: BaradbQuery, column: string, symbol: string,
              value: string|int|float|bool): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  self.placeHolder.add(%*{"key": column, "value": value})

  if self.query.hasKey("or_where") == false:
    self.query["or_where"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "?"
    }]
  else:
    self.query["or_where"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "?"
    })
  return self


proc orWhere*(self: BaradbQuery, column: string, symbol: string, value: nil.type): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  if self.query.hasKey("or_where") == false:
    self.query["or_where"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "null"
    }]
  else:
    self.query["or_where"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "null"
    })
  return self


proc whereBetween*(self: BaradbQuery, column: string, width: array[2, int|float]): BaradbQuery =
  if self.query.hasKey("where_between") == false:
    self.query["where_between"] = %*[{
      "column": column,
      "width": width
    }]
  else:
    self.query["where_between"].add(%*{
      "column": column,
      "width": width
    })
  return self


proc whereBetween*(self: BaradbQuery, column: string, width: array[2, string]): BaradbQuery =
  if self.query.hasKey("where_between_string") == false:
    self.query["where_between_string"] = %*[{
      "column": column,
      "width": width
    }]
  else:
    self.query["where_between_string"].add(%*{
      "column": column,
      "width": width
    })
  return self


proc whereNotBetween*(self: BaradbQuery, column: string, width: array[2, int|float]): BaradbQuery =
  if self.query.hasKey("where_not_between") == false:
    self.query["where_not_between"] = %*[{
      "column": column,
      "width": width
    }]
  else:
    self.query["where_not_between"].add(%*{
      "column": column,
      "width": width
    })
  return self


proc whereNotBetween*(self: BaradbQuery, column: string, width: array[2, string]): BaradbQuery =
  if self.query.hasKey("where_not_between_string") == false:
    self.query["where_not_between_string"] = %*[{
      "column": column,
      "width": width
    }]
  else:
    self.query["where_not_between_string"].add(%*{
      "column": column,
      "width": width
    })
  return self


proc whereIn*(self: BaradbQuery, column: string, width: seq[int|float|string]): BaradbQuery =
  if self.query.hasKey("where_in") == false:
    self.query["where_in"] = %*[{
      "column": column,
      "width": width
    }]
  else:
    self.query["where_in"].add(%*{
      "column": column,
      "width": width
    })
  return self


proc whereNotIn*(self: BaradbQuery, column: string, width: seq[int|float|string]): BaradbQuery =
  if self.query.hasKey("where_not_in") == false:
    self.query["where_not_in"] = %*[{
      "column": column,
      "width": width
    }]
  else:
    self.query["where_not_in"].add(%*{
      "column": column,
      "width": width
    })
  return self


proc whereNull*(self: BaradbQuery, column: string): BaradbQuery =
  if self.query.hasKey("where_null") == false:
    self.query["where_null"] = %*[{
      "column": column
    }]
  else:
    self.query["where_null"].add(%*{
      "column": column
    })
  return self


proc groupBy*(self: BaradbQuery, column: string): BaradbQuery =
  if self.query.hasKey("group_by") == false:
    self.query["group_by"] = %*[{"column": column}]
  else:
    self.query["group_by"].add(%*{"column": column})
  return self


proc having*(self: BaradbQuery, column: string, symbol: string,
              value: string|int|float|bool): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  self.placeHolder.add(%*{"key": column, "value": value})

  if self.query.hasKey("having") == false:
    self.query["having"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "?"
    }]
  else:
    self.query["having"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "?"
    })
  return self


proc having*(self: BaradbQuery, column: string, symbol: string, value: nil.type): BaradbQuery =
  if not whereSymbols.contains(symbol):
    raise newException(CatchableError, whereSymbolsError)

  if self.query.hasKey("having") == false:
    self.query["having"] = %*[{
      "column": column,
      "symbol": symbol,
      "value": "null"
    }]
  else:
    self.query["having"].add(%*{
      "column": column,
      "symbol": symbol,
      "value": "null"
    })
  return self


proc orderBy*(self: BaradbQuery, column: string, order: Order): BaradbQuery =
  if self.query.hasKey("order_by") == false:
    self.query["order_by"] = %*[{
      "column": column,
      "order": $order
    }]
  else:
    self.query["order_by"].add(%*{
      "column": column,
      "order": $order
    })
  return self


proc limit*(self: BaradbQuery, num: int): BaradbQuery =
  self.query["limit"] = %num
  return self


proc offset*(self: BaradbQuery, num: int): BaradbQuery =
  self.query["offset"] = %num
  return self


proc raw*(self: BaradbConnections, sql: string, arges = newJArray()): RawBaradbQuery =
  let rawQueryRdb = RawBaradbQuery(
    log: self.log,
    pools: self.pools,
    query: newJObject(),
    queryString: sql,
    placeHolder: arges,
    isInTransaction: false,
    transactionConn: 0
  )
  return rawQueryRdb
