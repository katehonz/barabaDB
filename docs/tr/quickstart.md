# BaraDB - Hızlı Başlangıç Rehberi

## Sunucuyu Başlatma

```bash
./build/baradadb
```

Sunucu varsayılan olarak `localhost:9470` üzerinde başlar.

## CLI ile Bağlanma

```bash
./build/baradadb --shell
```

## Temel İşlemler

### Şema Oluşturma

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};
```

### Veri Ekleme

```sql
INSERT Person { name := 'Alice', age := 30 };
```

### Veri Sorgulama

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### Veri Güncelleme

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### Veri Silme

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## Gelişmiş Sorgular

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### CTE

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## Vektör Arama

```sql
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## Grafik Operasyonları

```sql
MATCH (p:Person)-[:KNOWS]->(other:Person)
WHERE p.name = 'Alice'
RETURN other.name;
```

## HTTP/REST API

```bash
curl http://localhost:9470/api/users
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## Sonraki Adımlar

- [BaraQL Referans](baraql.md)
- [Depolama Motorları](storage.md)
- [Mimari Genel Bakış](architecture.md)