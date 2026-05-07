# الاستعلامات عبر الأنماط

القدرة الفريدة لـ BaraDB هي تنفيذ استعلامات تمتد عبر محركات تخزين متعددة في بيان BaraQL موحد واحد.

## نظرة عامة

- **مستند/KV** (LSM-Tree) — السجلات المهيكلة
- **رسم بياني** (قائمة المجاورة) — العلاقات
- **متجهي** (HNSW/IVF-PQ) — بحث التشابه
- **نص كامل** (الفهرس المقلوب) — البحث النصي
- **عمودي** — التجميعات التحليلية

## أنماط الاستعلام

### متجه + نص كامل

```sql
SELECT title FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

### رسم بياني + متجه

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name;
```

## التحسين

### مخطط استعلام عبر الأنماط

1. العامل الأكثر انتقائية أولاً
2. دفع المسندات إلى كل محرك
3. استخدام فلاتر Bloom لعمليات KV
4. 병렬화 الفروع المستقلة

## الأداء

| نوع الاستعلام | التأخير (10K صف) |
|---------------|------------------|
| FTS + Vector | 15 ms |
| Graph + Vector | 25 ms |
| FTS + Aggregate | 12 ms |