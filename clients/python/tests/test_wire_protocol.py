"""
Unit tests for BaraDB Python client wire protocol.
No running server required.
"""

import struct
import pytest
from baradb import WireValue, FieldKind, MsgKind, ResultFormat


class TestWireValue:
    """Tests for WireValue serialization / deserialization."""

    def test_null(self):
        wv = WireValue.null()
        assert wv.kind == FieldKind.NULL
        data = wv.serialize()
        assert data == b"\x00"

    def test_bool_true(self):
        wv = WireValue.bool_val(True)
        assert wv.serialize() == b"\x01\x01"

    def test_bool_false(self):
        wv = WireValue.bool_val(False)
        assert wv.serialize() == b"\x01\x00"

    def test_int8(self):
        wv = WireValue.int8(-42)
        data = wv.serialize()
        assert data[0] == FieldKind.INT8
        assert struct.unpack(">b", data[1:])[0] == -42

    def test_int16(self):
        wv = WireValue.int16(-1000)
        data = wv.serialize()
        assert data[0] == FieldKind.INT16
        assert struct.unpack(">h", data[1:])[0] == -1000

    def test_int32(self):
        wv = WireValue.int32(123456)
        data = wv.serialize()
        assert data[0] == FieldKind.INT32
        assert struct.unpack(">i", data[1:])[0] == 123456

    def test_int64(self):
        wv = WireValue.int64(9999999999)
        data = wv.serialize()
        assert data[0] == FieldKind.INT64
        assert struct.unpack(">q", data[1:])[0] == 9999999999

    def test_float32(self):
        wv = WireValue.float32(3.14)
        data = wv.serialize()
        assert data[0] == FieldKind.FLOAT32
        assert abs(struct.unpack(">f", data[1:])[0] - 3.14) < 0.01

    def test_float64(self):
        wv = WireValue.float64(2.718281828)
        data = wv.serialize()
        assert data[0] == FieldKind.FLOAT64
        assert abs(struct.unpack(">d", data[1:])[0] - 2.718281828) < 1e-9

    def test_string(self):
        wv = WireValue.string("hello")
        data = wv.serialize()
        assert data[0] == FieldKind.STRING
        length = struct.unpack(">I", data[1:5])[0]
        assert length == 5
        assert data[5:] == b"hello"

    def test_bytes(self):
        wv = WireValue.bytes_val(b"\xde\xad\xbe\xef")
        data = wv.serialize()
        assert data[0] == FieldKind.BYTES
        length = struct.unpack(">I", data[1:5])[0]
        assert length == 4
        assert data[5:] == b"\xde\xad\xbe\xef"

    def test_vector(self):
        wv = WireValue.vector([1.0, 2.0, 3.0])
        data = wv.serialize()
        assert data[0] == FieldKind.VECTOR
        dim = struct.unpack(">I", data[1:5])[0]
        assert dim == 3
        floats = [struct.unpack(">f", data[5 + i * 4 : 9 + i * 4])[0] for i in range(3)]
        assert floats == [1.0, 2.0, 3.0]

    def test_json(self):
        wv = WireValue.json_val('{"key": "value"}')
        data = wv.serialize()
        assert data[0] == FieldKind.JSON
        length = struct.unpack(">I", data[1:5])[0]
        assert length == 16

    def test_array(self):
        inner = [WireValue.string("a"), WireValue.string("b")]
        wv = WireValue.array_val(inner)
        data = wv.serialize()
        assert data[0] == FieldKind.ARRAY
        count = struct.unpack(">I", data[1:5])[0]
        assert count == 2

    def test_object(self):
        inner = {"name": WireValue.string("Bara"), "age": WireValue.int32(42)}
        wv = WireValue.object_val(inner)
        data = wv.serialize()
        assert data[0] == FieldKind.OBJECT
        count = struct.unpack(">I", data[1:5])[0]
        assert count == 2


class TestMessageKinds:
    """Sanity checks for protocol constants."""

    def test_client_kinds(self):
        assert MsgKind.CLIENT_HANDSHAKE == 0x01
        assert MsgKind.QUERY == 0x02
        assert MsgKind.QUERY_PARAMS == 0x03
        assert MsgKind.EXECUTE == 0x04
        assert MsgKind.BATCH == 0x05
        assert MsgKind.TRANSACTION == 0x06
        assert MsgKind.CLOSE == 0x07
        assert MsgKind.PING == 0x08
        assert MsgKind.AUTH == 0x09

    def test_server_kinds(self):
        assert MsgKind.SERVER_HANDSHAKE == 0x80
        assert MsgKind.READY == 0x81
        assert MsgKind.DATA == 0x82
        assert MsgKind.COMPLETE == 0x83
        assert MsgKind.ERROR == 0x84
        assert MsgKind.AUTH_CHALLENGE == 0x85
        assert MsgKind.AUTH_OK == 0x86
        assert MsgKind.SCHEMA_CHANGE == 0x87
        assert MsgKind.PONG == 0x88
        assert MsgKind.TRANSACTION_STATE == 0x89

    def test_result_formats(self):
        assert ResultFormat.BINARY == 0x00
        assert ResultFormat.JSON == 0x01
        assert ResultFormat.TEXT == 0x02
