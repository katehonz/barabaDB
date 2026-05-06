# User Defined Functions

Extend BaraQL with custom functions.

## Usage

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

# Register standard library
reg.registerStdlib()  # abs, sqrt, pow, lower, upper, len, trim, substr, toString, toInt

# Custom function
reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## Standard Library Functions

| Function | Description | Example |
|----------|-------------|---------|
| `abs(n)` | Absolute value | `abs(-5)` → 5 |
| `sqrt(n)` | Square root | `sqrt(16)` → 4 |
| `pow(n, e)` | Power | `pow(2, 3)` → 8 |
| `lower(s)` | Lowercase | `lower('ABC')` → 'abc' |
| `upper(s)` | Uppercase | `upper('abc')` → 'ABC' |
| `len(s)` | Length | `len('hello')` → 5 |
| `trim(s)` | Trim whitespace | `trim(' hello ')` → 'hello' |
| `substr(s, start, len)` | Substring | `substr('hello', 0, 3)` → 'hel' |
| `toString(n)` | Convert to string | `toString(123)` → '123' |
| `toInt(s)` | Convert to integer | `toInt('123')` → 123 |

## Function Registration

```nim
reg.register(
  name: "my_function",
  params: @[
    UDFParam(name: "arg1", typeName: "str"),
    UDFParam(name: "arg2", typeName: "int32")
  ],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    # Implementation
    result = Value(kind: vkString, strVal: "")
)
```

## Using UDFs in Queries

```sql
SELECT greet(name) FROM users;
```