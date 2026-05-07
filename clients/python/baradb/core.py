"""
BaraDB Python Client

Binary protocol client for BaraDB database.
Communicates via the BaraDB Wire Protocol (binary, big-endian).

Install:
    pip install baradb

Quick Start:
    from baradb import Client
    client = Client("localhost", 9472)
    client.connect()
    result = client.query("SELECT name FROM users WHERE age > 18")
    for row in result:
        print(row["name"])
    client.close()

Parameterized Queries:
    result = client.query_params("SELECT * FROM users WHERE age > $1", [WireValue.int64(18)])

Authentication:
    client = Client("localhost", 9472, username="admin", password="secret")
    client.connect()
    client.auth("jwt-token-here")
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
    JSON = 0x0D


class MsgKind:
    # Client messages
    CLIENT_HANDSHAKE = 0x01
    QUERY = 0x02
    QUERY_PARAMS = 0x03
    EXECUTE = 0x04
    BATCH = 0x05
    TRANSACTION = 0x06
    CLOSE = 0x07
    PING = 0x08
    AUTH = 0x09
    # Server messages
    SERVER_HANDSHAKE = 0x80
    READY = 0x81
    DATA = 0x82
    COMPLETE = 0x83
    ERROR = 0x84
    AUTH_CHALLENGE = 0x85
    AUTH_OK = 0x86
    SCHEMA_CHANGE = 0x87
    PONG = 0x88
    TRANSACTION_STATE = 0x89


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
    def bool_val(val: bool):
        return WireValue(FieldKind.BOOL, val)

    @staticmethod
    def int8(val: int):
        return WireValue(FieldKind.INT8, val)

    @staticmethod
    def int16(val: int):
        return WireValue(FieldKind.INT16, val)

    @staticmethod
    def int32(val: int):
        return WireValue(FieldKind.INT32, val)

    @staticmethod
    def int64(val: int):
        return WireValue(FieldKind.INT64, val)

    @staticmethod
    def float32(val: float):
        return WireValue(FieldKind.FLOAT32, val)

    @staticmethod
    def float64(val: float):
        return WireValue(FieldKind.FLOAT64, val)

    @staticmethod
    def string(val: str):
        return WireValue(FieldKind.STRING, val)

    @staticmethod
    def bytes_val(val: bytes):
        return WireValue(FieldKind.BYTES, val)

    @staticmethod
    def array_val(val: list):
        return WireValue(FieldKind.ARRAY, val)

    @staticmethod
    def object_val(val: dict):
        return WireValue(FieldKind.OBJECT, val)

    @staticmethod
    def vector(val: list):
        return WireValue(FieldKind.VECTOR, val)

    @staticmethod
    def json_val(val: str):
        return WireValue(FieldKind.JSON, val)

    def serialize(self) -> bytes:
        buf = bytes([self.kind])
        if self.kind == FieldKind.NULL:
            pass
        elif self.kind == FieldKind.BOOL:
            buf += bytes([1 if self.value else 0])
        elif self.kind == FieldKind.INT8:
            buf += struct.pack(">b", self.value)
        elif self.kind == FieldKind.INT16:
            buf += struct.pack(">h", self.value)
        elif self.kind == FieldKind.INT32:
            buf += struct.pack(">i", self.value)
        elif self.kind == FieldKind.INT64:
            buf += struct.pack(">q", self.value)
        elif self.kind == FieldKind.FLOAT32:
            buf += struct.pack(">f", self.value)
        elif self.kind == FieldKind.FLOAT64:
            buf += struct.pack(">d", self.value)
        elif self.kind == FieldKind.STRING:
            encoded = self.value.encode("utf-8")
            buf += struct.pack(">I", len(encoded)) + encoded
        elif self.kind == FieldKind.BYTES:
            buf += struct.pack(">I", len(self.value)) + self.value
        elif self.kind == FieldKind.ARRAY:
            buf += struct.pack(">I", len(self.value))
            for item in self.value:
                buf += item.serialize()
        elif self.kind == FieldKind.OBJECT:
            buf += struct.pack(">I", len(self.value))
            for key, val in self.value.items():
                key_bytes = key.encode("utf-8")
                buf += struct.pack(">I", len(key_bytes)) + key_bytes
                buf += val.serialize()
        elif self.kind == FieldKind.VECTOR:
            buf += struct.pack(">I", len(self.value))
            for f in self.value:
                buf += struct.pack(">f", f)
        elif self.kind == FieldKind.JSON:
            encoded = self.value.encode("utf-8")
            buf += struct.pack(">I", len(encoded)) + encoded
        return buf


class QueryResult:
    def __init__(self):
        self.columns: list[str] = []
        self.column_types: list[int] = []
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

    def __init__(self, host: str = "localhost", port: int = 9472,
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
            try:
                msg = self._build_message(MsgKind.CLOSE, b"")
                self._sock.send(msg)
            except Exception:
                pass
            self._sock.close()
        self._connected = False

    def is_connected(self) -> bool:
        return self._connected

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def _recv_exact(self, size: int) -> bytes:
        """Receive exactly `size` bytes from the socket."""
        data = b""
        while len(data) < size:
            chunk = self._sock.recv(size - len(data))
            if not chunk:
                raise ConnectionError("Connection closed by server")
            data += chunk
        return data

    def _read_response_header(self) -> tuple[int, int, int]:
        """Read a 12-byte message header. Returns (kind, length, request_id)."""
        header = self._recv_exact(12)
        kind, length, req_id = struct.unpack(">III", header)
        return kind, length, req_id

    def _read_error(self, length: int) -> Exception:
        """Read and parse an ERROR payload."""
        data = self._recv_exact(length)
        code = struct.unpack(">I", data[:4])[0]
        msg_len = struct.unpack(">I", data[4:8])[0]
        error_msg = data[8:8 + msg_len].decode("utf-8")
        return Exception(f"BaraDB error {code}: {error_msg}")

    def _read_data_response(self, length: int) -> QueryResult:
        """Read and parse a DATA payload, then follow up with COMPLETE."""
        data = self._recv_exact(length)
        pos = [0]

        col_count = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
        pos[0] += 4

        cols = []
        for _ in range(col_count):
            cols.append(self._read_string(data, pos))

        col_types = []
        for _ in range(col_count):
            col_types.append(data[pos[0]])
            pos[0] += 1

        row_count = struct.unpack(">I", data[pos[0]:pos[0]+4])[0]
        pos[0] += 4

        rows = []
        for _ in range(row_count):
            row = []
            for _ in range(col_count):
                val = self._deserialize_value(data, pos)
                row.append(val)
            rows.append(row)

        result = QueryResult()
        result.columns = cols
        result.column_types = col_types
        result.rows = rows
        result.row_count = row_count

        comp_kind, comp_len, _ = self._read_response_header()
        if comp_kind == MsgKind.COMPLETE:
            comp_data = self._recv_exact(comp_len)
            result.affected_rows = struct.unpack(">I", comp_data[:4])[0]
        elif comp_kind == MsgKind.ERROR:
            raise self._read_error(comp_len)

        return result

    def auth(self, token: str) -> None:
        """Authenticate with the server using a JWT token."""
        encoded = token.encode("utf-8")
        payload = struct.pack(">I", len(encoded)) + encoded
        msg = self._build_message(MsgKind.AUTH, payload)
        self._sock.send(msg)

        kind, length, _ = self._read_response_header()
        if kind == MsgKind.AUTH_OK:
            return
        elif kind == MsgKind.ERROR:
            raise self._read_error(length)
        else:
            raise Exception(f"Unexpected auth response: 0x{kind:02x}")

    def ping(self) -> bool:
        """Ping the server. Returns True if pong received."""
        msg = self._build_message(MsgKind.PING, b"")
        self._sock.send(msg)

        kind, length, _ = self._read_response_header()
        if kind == MsgKind.PONG:
            return True
        elif kind == MsgKind.ERROR:
            raise self._read_error(length)
        return False

    def query(self, sql: str) -> QueryResult:
        """Execute a BaraQL query."""
        payload = self._encode_string(sql)
        payload += bytes([ResultFormat.BINARY])

        msg = self._build_message(MsgKind.QUERY, payload)
        self._sock.send(msg)

        kind, length, _ = self._read_response_header()

        if kind == MsgKind.ERROR:
            raise self._read_error(length)

        if kind == MsgKind.DATA:
            return self._read_data_response(length)

        if kind == MsgKind.COMPLETE:
            data = self._recv_exact(length)
            result = QueryResult()
            result.affected_rows = struct.unpack(">I", data[:4])[0]
            return result

        return QueryResult()

    def query_params(self, sql: str, params: Sequence[WireValue]) -> QueryResult:
        """Execute a parameterized BaraQL query."""
        payload = self._encode_string(sql)
        payload += bytes([ResultFormat.BINARY])
        payload += struct.pack(">I", len(params))
        for p in params:
            payload += p.serialize()

        msg = self._build_message(MsgKind.QUERY_PARAMS, payload)
        self._sock.send(msg)

        kind, length, _ = self._read_response_header()

        if kind == MsgKind.ERROR:
            raise self._read_error(length)

        if kind == MsgKind.DATA:
            return self._read_data_response(length)

        if kind == MsgKind.COMPLETE:
            data = self._recv_exact(length)
            result = QueryResult()
            result.affected_rows = struct.unpack(">I", data[:4])[0]
            return result

        return QueryResult()

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
        elif kind == FieldKind.JSON:
            return self._read_string(data, pos)
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
