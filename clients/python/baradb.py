"""
BaraDB Python Client

Binary protocol client for BaraDB database.
Communicates via the BaraDB Wire Protocol (binary, big-endian).

Install:
    pip install baradb

Quick Start:
    from baradb import Client
    client = Client("localhost", 5432)
    client.connect()
    result = client.query("SELECT name FROM users WHERE age > 18")
    for row in result:
        print(row["name"])
    client.close()
"""

import socket
import struct
import json
from typing import Any, Optional, Sequence


class FieldKind:
    NULL = 0x00
    BOOL = 0x01
    INT8 = 0x02
    INT16 = 0x03
    INT32 = 0x04
    INT64 = 0x05
    FLOAT32 = 0x06
    FLOAT64 = 0x07
    STRING = 0x08
    BYTES = 0x09
    ARRAY = 0x0A
    OBJECT = 0x0B
    VECTOR = 0x0C


class MsgKind:
    QUERY = 0x02
    BATCH = 0x05
    TRANSACTION = 0x06
    CLOSE = 0x07
    PING = 0x08
    AUTH = 0x09
    # Server messages
    READY = 0x81
    DATA = 0x82
    COMPLETE = 0x83
    ERROR = 0x84


class ResultFormat:
    BINARY = 0x00
    JSON = 0x01
    TEXT = 0x02


class WireValue:
    def __init__(self, kind: int, value: Any = None):
        self.kind = kind
        self.value = value

    @staticmethod
    def null():
        return WireValue(FieldKind.NULL)

    @staticmethod
    def int64(val: int):
        return WireValue(FieldKind.INT64, val)

    @staticmethod
    def string(val: str):
        return WireValue(FieldKind.STRING, val)

    @staticmethod
    def float64(val: float):
        return WireValue(FieldKind.FLOAT64, val)

    @staticmethod
    def bool_val(val: bool):
        return WireValue(FieldKind.BOOL, val)


class QueryResult:
    def __init__(self):
        self.columns: list[str] = []
        self.rows: list[list[Any]] = []
        self.row_count: int = 0
        self.affected_rows: int = 0

    def __iter__(self):
        for row in self.rows:
            yield dict(zip(self.columns, row))

    def __len__(self):
        return self.row_count

    def __repr__(self):
        return f"<QueryResult rows={self.row_count}>"


class Client:
    """BaraDB database client."""

    def __init__(self, host: str = "localhost", port: int = 5432,
                 database: str = "default", username: str = "admin",
                 password: str = "", timeout: int = 30):
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.timeout = timeout
        self._sock: Optional[socket.socket] = None
        self._connected = False
        self._request_id = 0

    def connect(self) -> None:
        """Connect to the BaraDB server."""
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.settimeout(self.timeout)
        self._sock.connect((self.host, self.port))
        self._connected = True

    def close(self) -> None:
        if self._sock:
            self._sock.close()
        self._connected = False

    def is_connected(self) -> bool:
        return self._connected

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def query(self, sql: str) -> QueryResult:
        """Execute a BaraQL query."""
        payload = self._encode_string(sql)
        payload += bytes([ResultFormat.BINARY])

        msg = self._build_message(MsgKind.QUERY, payload)
        self._sock.send(msg)

        result = QueryResult()

        # Read response header
        header = self._sock.recv(12)
        kind, length, req_id = struct.unpack(">III", header)

        if kind == MsgKind.ERROR:
            error_data = self._sock.recv(length)
            code, msg_len = struct.unpack(">II", error_data[:8])
            error_msg = error_data[8:8 + msg_len].decode()
            raise Exception(f"BaraDB error {code}: {error_msg}")

        if kind == MsgKind.DATA:
            data = self._sock.recv(length)
            pos = [0]
            col_count = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            cols = []
            for _ in range(col_count):
                s = self._read_string(data, pos)
                cols.append(s)
            row_count = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            rows = []
            for _ in range(row_count):
                row = []
                for _ in range(col_count):
                    val = self._deserialize_value(data, pos)
                    row.append(val)
                rows.append(row)
            result.columns = cols
            result.rows = rows
            result.row_count = row_count
            # Read following COMPLETE message
            comp_header = self._sock.recv(12)
            ckind, clen, _ = struct.unpack(">III", comp_header)
            if ckind == MsgKind.COMPLETE:
                comp_data = self._sock.recv(clen)
                result.affected_rows = struct.unpack(">I", comp_data[:4])[0]
            return result

        if kind == MsgKind.COMPLETE:
            comp_data = self._sock.recv(length)
            result.affected_rows = struct.unpack(">I", comp_data[:4])[0]
            return result

        return result

    def execute(self, sql: str) -> int:
        result = self.query(sql)
        return result.affected_rows

    def _build_message(self, kind: int, payload: bytes) -> bytes:
        req_id = self._next_id()
        return struct.pack(">III", kind, len(payload), req_id) + payload

    @staticmethod
    def _encode_string(s: str) -> bytes:
        data = s.encode("utf-8")
        return struct.pack(">I", len(data)) + data

    @staticmethod
    def _read_string(data: bytes, pos: list) -> str:
        """Read length-prefixed UTF-8 string from data at pos[0]. Updates pos[0]."""
        length = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
        pos[0] += 4
        s = data[pos[0]:pos[0]+length].decode("utf-8")
        pos[0] += length
        return s

    def _deserialize_value(self, data: bytes, pos: list) -> Any:
        kind = data[pos[0]]
        pos[0] += 1
        if kind == FieldKind.NULL:
            return None
        elif kind == FieldKind.BOOL:
            val = data[pos[0]] != 0
            pos[0] += 1
            return val
        elif kind == FieldKind.INT8:
            val = int.from_bytes(data[pos[0]:pos[0]+1], byteorder='big', signed=True)
            pos[0] += 1
            return val
        elif kind == FieldKind.INT16:
            val = int.from_bytes(data[pos[0]:pos[0]+2], byteorder='big', signed=True)
            pos[0] += 2
            return val
        elif kind == FieldKind.INT32:
            val = int.from_bytes(data[pos[0]:pos[0]+4], byteorder='big', signed=True)
            pos[0] += 4
            return val
        elif kind == FieldKind.INT64:
            val = int.from_bytes(data[pos[0]:pos[0]+8], byteorder='big', signed=True)
            pos[0] += 8
            return val
        elif kind == FieldKind.FLOAT32:
            val = struct.unpack(">f", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            return val
        elif kind == FieldKind.FLOAT64:
            val = struct.unpack(">d", data[pos[0]:pos[0]+8])[0]
            pos[0] += 8
            return val
        elif kind == FieldKind.STRING:
            return self._read_string(data, pos)
        elif kind == FieldKind.BYTES:
            length = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            val = data[pos[0]:pos[0]+length]
            pos[0] += length
            return val
        elif kind == FieldKind.ARRAY:
            count = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            arr = []
            for _ in range(count):
                arr.append(self._deserialize_value(data, pos))
            return arr
        elif kind == FieldKind.OBJECT:
            count = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            obj = {}
            for _ in range(count):
                key = self._read_string(data, pos)
                val = self._deserialize_value(data, pos)
                obj[key] = val
            return obj
        elif kind == FieldKind.VECTOR:
            dim = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
            pos[0] += 4
            vec = []
            for _ in range(dim):
                vec.append(struct.unpack(">f", data[pos[0]:pos[0]+4])[0])
                pos[0] += 4
            return vec
        return None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.close()


class QueryBuilder:
    """Fluent query builder for BaraQL."""

    def __init__(self, client: Client):
        self.client = client
        self._select = []
        self._from = ""
        self._where = []
        self._joins = []
        self._group_by = []
        self._having = ""
        self._order_by = []
        self._limit = 0
        self._offset = 0

    def select(self, *cols: str) -> "QueryBuilder":
        self._select.extend(cols)
        return self

    def from_(self, table: str) -> "QueryBuilder":
        self._from = table
        return self

    def where(self, clause: str) -> "QueryBuilder":
        self._where.append(clause)
        return self

    def join(self, table: str, on: str) -> "QueryBuilder":
        self._joins.append(f"JOIN {table} ON {on}")
        return self

    def left_join(self, table: str, on: str) -> "QueryBuilder":
        self._joins.append(f"LEFT JOIN {table} ON {on}")
        return self

    def group_by(self, *cols: str) -> "QueryBuilder":
        self._group_by.extend(cols)
        return self

    def having(self, clause: str) -> "QueryBuilder":
        self._having = clause
        return self

    def order_by(self, col: str, direction: str = "ASC") -> "QueryBuilder":
        self._order_by.append(f"{col} {direction}")
        return self

    def limit(self, n: int) -> "QueryBuilder":
        self._limit = n
        return self

    def offset(self, n: int) -> "QueryBuilder":
        self._offset = n
        return self

    def build(self) -> str:
        sql = "SELECT " + (", ".join(self._select) if self._select else "*")
        sql += " FROM " + self._from
        for j in self._joins:
            sql += " " + j
        if self._where:
            sql += " WHERE " + " AND ".join(self._where)
        if self._group_by:
            sql += " GROUP BY " + ", ".join(self._group_by)
        if self._having:
            sql += " HAVING " + self._having
        if self._order_by:
            sql += " ORDER BY " + ", ".join(self._order_by)
        if self._limit:
            sql += " LIMIT " + str(self._limit)
        if self._offset:
            sql += " OFFSET " + str(self._offset)
        return sql

    def exec(self) -> QueryResult:
        return self.client.query(self.build())


# BaraDB Binary Protocol Specification
"""
Protocol Format:

Each message: [kind: uint32] [length: uint32] [request_id: uint32] [payload: bytes...]

Client Messages:
  0x01 CLIENT_HANDSHAKE
  0x02 QUERY          (string query, uint8 format)
  0x03 QUERY_PARAMS   (string query, uint16 param_count, params...)
  0x04 EXECUTE        (prepared statement)
  0x05 BATCH          (batch of queries)
  0x06 TRANSACTION    (begin/commit/rollback)
  0x07 CLOSE
  0x08 PING
  0x09 AUTH           (auth method, credentials)

Server Messages:
  0x80 SERVER_HANDSHAKE
  0x81 READY          (transaction state)
  0x82 DATA           (column count, column names, rows)
  0x83 COMPLETE       (affected rows)
  0x84 ERROR          (error code, error message)
  0x85 AUTH_CHALLENGE
  0x86 AUTH_OK
  0x87 SCHEMA_CHANGE
  0x88 PONG
  0x89 TRANSACTION_STATE

Value Encoding:
  value ::= kind:uint8 + data
  NULL:   0x00
  BOOL:   0x01 + uint8(0|1)
  INT8:   0x02 + int8
  INT16:  0x03 + int16(big-endian)
  INT32:  0x04 + int32(big-endian)
  INT64:  0x05 + int64(big-endian)
  FLOAT32: 0x06 + float32(ieee754)
  FLOAT64: 0x07 + float64(ieee754)
  STRING: 0x08 + uint32(length) + utf8bytes
  BYTES:  0x09 + uint32(length) + bytes
  ARRAY:  0x0A + uint32(count) + value*
  OBJECT: 0x0B + uint32(count) + (string_key + value)*
  VECTOR: 0x0C + uint32(dim) + float32*
"""
