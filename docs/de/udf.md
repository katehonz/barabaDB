# Benutzerdefinierte Funktionen

BaraQL mit benutzerdefinierten Funktionen erweitern.

## Verwendung

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

# Standard-Bibliothek registrieren
reg.registerStdlib()  # abs, sqrt, pow, lower, upper, len, trim, substr, toString, toInt

# Benutzerdefinierte Funktion
reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## Standard-Bibliotheksfunktionen

| Funktion | Beschreibung | Beispiel |
|----------|-------------|---------|
| `abs(n)` | Absoluter Wert | `abs(-5)` → 5 |
| `sqrt(n)` | Quadratwurzel | `sqrt(16)` → 4 |
| `pow(n, e)` | Potenz | `pow(2, 3)` → 8 |
| `lower(s)` | Kleinbuchstaben | `lower('ABC')` → 'abc' |
| `upper(s)` | Großbuchstaben | `upper('abc')` → 'ABC' |
| `len(s)` | Länge | `len('hello')` → 5 |
| `trim(s)` | Leerzeichen trimmen | `trim(' hello ')` → 'hello' |
| `substr(s, start, len)` | Substring | `substr('hello', 0, 3)` → 'hel' |
| `toString(n)` | In String konvertieren | `toString(123)` → '123' |
| `toInt(s)` | In Integer konvertieren | `toInt('123')` → 123 |

## Funktionsregistrierung

```nim
reg.register(
  name: "my_function",
  params: @[
    UDFParam(name: "arg1", typeName: "str"),
    UDFParam(name: "arg2", typeName: "int32")
  ],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    # Implementierung
    result = Value(kind: vkString, strVal: "")
)
```

## UDFs in Abfragen verwenden

```sql
SELECT greet(name) FROM users;
```
