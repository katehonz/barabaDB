## BaraDB client exception hierarchy

type
  BaraError* = object of CatchableError
  BaraProtocolError* = object of BaraError
  BaraServerError* = object of BaraError
    code*: uint32
  BaraAuthError* = object of BaraError
  BaraIoError* = object of BaraError
  BaraPoolTimeoutError* = object of BaraError
