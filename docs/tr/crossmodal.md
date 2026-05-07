# Çapraz Modlu Sorgular

BaraDB'nin benzersiz yeteneği: birden fazla depolama motorunu tek bir BaraQL ifadesiyle sorgulama.

## Genel Bakış

- **Belge/KV** (LSM-Tree) — yapılandırılmış kayıtlar
- **Grafik** (Bitişik Liste) — ilişkiler
- **Vektör** (HNSW/IVF-PQ) — benzerlik araması
- **Tam Metin** (Ters İndeks) — metin araması
- **Kolonlu** — analitik toplamalar

## Sorgu Kalıpları

### Vektör + Tam Metin

```sql
SELECT title FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

### Grafik + Vektör

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name;
```

## Optimizasyon

### Çapraz Modlu Sorgu Planlayıcı

1. En seçici filtre önce
2. Yüklemeleri her motora itin
3. KV aramaları için Bloom filtreleri kullan
4. Bağımsız dalları paralelleştir

## Performans

| Sorgu Tipi | Gecikme (10K satır) |
|------------|----------------------|
| FTS + Vector | 15 ms |
| Graph + Vector | 25 ms |
| FTS + Aggregate | 12 ms |