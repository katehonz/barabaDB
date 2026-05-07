# Değişiklik Günlüğü

## [0.1.0] — 2025-01-15

### Eklenenler

- **Çekirdek Depolama Motorları**
  - MemTable, WAL, SSTables ve size-tiered compaction ile LSM-Tree
  - MVCC copy-on-write ile aralık tarama ve B-Tree sıralı indeks
  - Bloom filtreleri
  - Memory-mapped I/O
  - LRU sayfa önbelleği

- **Sorgu Motoru (BaraQL)**
  - 80+ token türüyle SQL uyumlu lexer
  - 25+ düğüm türüyle AST üreten recursive descent parser
  - IR ara temsili
  - Çapraz modlu planlama ile adaptif sorgu optimizatörü
  - Paralelleştirme ile sorgu yürütücüsü

- **BaraQL Dil Özellikleri**
  - SELECT, INSERT, UPDATE, DELETE
  - WHERE, ORDER BY, LIMIT, OFFSET
  - GROUP BY, HAVING, toplama fonksiyonları
  - INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN
  - CTEs (WITH)
  - Alt sorgular
  - CASE ifadeleri
  - UNION, INTERSECT, EXCEPT

- **Vektör Motoru**
  - HNSW indeksi
  - IVF-PQ indeksi
  - SIMD optimize edilmiş mesafe fonksiyonları
  - Nicemleme: skaler 8-bit/4-bit, ürün, ikili

- **Grafik Motoru**
  - Bitişik liste depolaması
  - BFS ve DFS geçişi
  - Dijkstra en kısa yol
  - PageRank
  - Louvain topluluk tespiti
  - Cypher sorgu ayrıştırıcısı

- **Tam Metin Arama**
  - Ters indeks
  - BM25 sıralaması
  - TF-IDF
  - Fuzzy arama
  - Çok dilli tokenizatörler

- **Protokoller**
  - 16 mesaj türüyle Binary wire protocol
  - HTTP/REST JSON API
  - WebSocket akışı
  - Connection pooling
  - JWT kimlik doğrulama
  - TLS/SSL

- **Dağıtık Sistemler**
  - Raft konsensüs
  - Hash, range, consistent-hash parçalama
  - Sync/async/semi-sync çoğaltma
  - Gossip protokolü
  - İki aşamalı commit

### Performans

- LSM-Tree: 580K yazma/s, 720K okuma/s
- B-Tree: 1.2M ekleme/s, 1.5M arama/s
- Vector SIMD: 850K kosinüs mesafesi/s (dim=768)

### Testler

- 56 test paketinde 262 test
- %100 geçme oranı