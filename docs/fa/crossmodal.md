# پرس‌وجوهای بین‌حالتی

توانایی منحصربه‌فرد BaraDB برای اجرای کوئری‌هایی که چندین موتور ذخیره‌سازی را در یک عبارت BaraQL واحد پوشش می‌دهند.

## نمای کلی

- **سند/KV** (LSM-Tree) — رکوردهای ساختاریافته
- **گراف** (لیست مجاورت) — روابط
- **بردار** (HNSW/IVF-PQ) — جستجوی شباهت
- **تمام‌متن** (اندیس معکوس) — جستجوی متنی
- **ستونی** — تجمیع‌های تحلیلی

## پترن‌های کوئری

### بردار + تمام‌متن

```sql
SELECT title FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

### گراف + بردار

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name;
```

## بهینه‌سازی

### برنامه‌ریز پرس‌وجو

1. فیلتر انتخابی‌ترین اول
2. پوش‌داون پریدایکت‌ها به هر موتور
3. فیلترهای Bloom برای جستجوهای KV
4. موازی‌سازی شاخه‌های مستقل