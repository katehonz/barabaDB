# Kullanıcı Tanımlı Fonksiyonlar

BaraQL'i özel fonksiyonlarla genişlet.

## Kullanım

```nim
import barabadb/query/udf

var reg = newUDFRegistry()

reg.registerStdlib()

reg.register("greet", @[UDFParam(name: "name", typeName: "str")],
  "str", proc(args: seq[Value]): Value =
    return Value(kind: vkString, strVal: "Hello, " & args[0].strVal & "!"))
```

## Standart Kütüphane Fonksiyonları

| Fonksiyon | Açıklama | Örnek |
|-----------|----------|-------|
| `abs(n)` | Mutlak değer | `abs(-5)` → 5 |
| `sqrt(n)` | Karekök | `sqrt(16)` → 4 |
| `pow(n, e)` | Üs | `pow(2, 3)` → 8 |
| `lower(s)` | Küçük harf | `lower('ABC')` → 'abc' |
| `upper(s)` | Büyük harf | `upper('abc')` → 'ABC' |
| `len(s)` | Uzunluk | `len('hello')` → 5 |
| `trim(s)` | Boşluk kırpma | `trim(' hello ')` → 'hello' |

## Fonksiyon Kaydetme

```nim
reg.register(
  name: "my_function",
  params: @[UDFParam(name: "arg1", typeName: "str")],
  returnType: "str",
  body: proc(args: seq[Value]): Value =
    result = Value(kind: vkString, strVal: "")
)
```

## Sorgularda UDF Kullanımı

```sql
SELECT greet(name) FROM users;
```