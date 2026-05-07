# سیاهه تغییرات

## [0.1.0] — 2025-01-15

### افزوده شده

- **موتورهای ذخیره‌سازی اصلی**
  - LSM-Tree با MemTable، WAL، SSTables و size-tiered compaction
  - B-Tree اندیس مرتب با اسکن بازه‌ای و MVCC copy-on-write
  - Bloom filterها
  - Memory-mapped I/O
  - LRU page cache

- **موتور کوئری (BaraQL)**
  - لکسر SQL-سازگار با 80+ نوع توکن
  - پارسر تولیدکننده AST با 25+ نوع گره
  - نمایش میانی (IR)
  - بهینه‌ساز تطبیقی
  - اجراکننده موازی

- **قابلیت‌های زبان BaraQL**
  - SELECT, INSERT, UPDATE, DELETE
  - WHERE, ORDER BY, LIMIT, OFFSET
  - GROUP BY, HAVING
  - INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN
  - CTEs با WITH
  - زیرکوئری‌ها
  - CASE
  - UNION, INTERSECT, EXCEPT

- **موتور برداری**
  - اندیس HNSW
  - IVF-PQ
  - SIMD-بهینه‌شده

- **موتور گراف**
  - لیست مجاورت
  - BFS و DFS
  - Dijkstra
  - PageRank
  - Louvain
  - Cypher

- **جستجوی تمام‌متن**
  - اندیس معکوس
  - BM25
  - TF-IDF
  - جستجوی فازی
  - چندزبانه

- **پروتکل‌ها**
  - Binary wire protocol
  - HTTP/REST JSON API
  - WebSocket
  - Connection pooling
  - JWT auth
  - TLS/SSL

- **سیستم توزیع‌شده**
  - Raft consensus
  - Sharding
  - Replication
  - Gossip
  - Two-phase commit

### عملکرد

- LSM-Tree: 580K نوشتن/ثانیه، 720K خواندن/ثانیه
- B-Tree: 1.2M درج/ثانیه
- Vector SIMD: 850K فاصله کسینوسی/ثانیه