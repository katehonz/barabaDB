# سجل التغييرات

## [0.1.0] — 2025-01-15

### المضاف

- **محركات التخزين الأساسية**
  - LSM-Tree مع MemTable و WAL و SSTables و size-tiered compaction
  - فهرس B-Tree مرتب مع المسح النطاقي و MVCC copy-on-write
  - فلاتر Bloom
  - I/O المعينة بالذاكرة
  - ذاكرة صفحة LRU

- **محرك الاستعلام (BaraQL)**
  - lexer متوافق مع SQL مع 80+ نوع رمز
  - parser تنازلي تكراري ينتج AST مع 25+ نوع عقدة
  - تمثيل وسيط (IR)
  - محسن استعلام تكيفي مع تخطيط عبر الأنماط
  - منفذ استعلام مع 병렬화

- **ميزات لغة BaraQL**
  - SELECT و INSERT و UPDATE و DELETE
  - WHERE و ORDER BY و LIMIT و OFFSET
  - GROUP BY و HAVING ودوال التجميع
  - INNER JOIN و LEFT JOIN و RIGHT JOIN و FULL JOIN و CROSS JOIN
  - CTEs مع WITH
  - الاستعلامات الفرعية
  - تعبيرات CASE
  - UNION و INTERSECT و EXCEPT

- **محرك المتجهات**
  - فهرس HNSW
  - فهرس IVF-PQ
  - دوال المسافة المحسنة بـ SIMD
  - التكميم: 8-bit/4-bit القياسي والمنتج والثنائي

- **محرك الرسم البياني**
  - تخزين قائمة المجاورة
  - BFS و DFS للعبور
  - Dijkstra لأقصر مسار
  - PageRank
  - Louvain لكشف المجتمع
  - محلل استعلامات Cypher

- **البحث النصي الكامل**
  - الفهرس المقلوب
  - ترتيب BM25
  - TF-IDF
  - البحث الغامض
  - tokenizers متعدد اللغات

- **البروتوكولات**
  - بروتوكول Wire الثنائي مع 16 نوع رسالة
  - API HTTP/REST JSON
  - WebSocket للدفق
  - تجميع الاتصالات
  - مصادقة JWT
  - TLS/SSL

- **الأنظمة الموزعة**
  - توافق Raft
  - تجزئة hash و range و consistent-hash
  - نسخ متزامن/غير متزامن/شبه متزامن
  - بروتوكول Gossip
  - commit على مرحلتين

### الأداء

- LSM-Tree: 580K كتابة/ثانية، 720K قراءة/ثانية
- B-Tree: 1.2M إدراج/ثانية، 1.5M بحث/ثانية
- Vector SIMD: 850K مسافة جيب التمام/ثانية (dim=768)

### الاختبارات

- 262 اختبار عبر 56 مجموعة اختبار
- 100% معدل النجاح