# BaraDB Mimarisi

## Genel Bakış

BaraDB, Nim ile yazılmış bir **çok modlu veritabanı motorudur** — doküman (KV), grafik, vektör, kolonlu ve tam metin arama depolamasını **BaraQL** sorgu diliyle birleştirir.

## Katmanlı Mimari

```
┌─────────────────────────────────────────────────────────┐
│ 1. İSTEMCİ KATMANI                                      │
│    İkili Protokol │ HTTP/REST │ WebSocket │ Gömülü      │
├─────────────────────────────────────────────────────────┤
│ 2. SORGU KATMANI (BaraQL)                               │
│    Lexer → Parser → AST → IR → Optimizör → Kod Üretimi  │
├─────────────────────────────────────────────────────────┤
│ 3. ÇALIŞTIRMA MOTORLARI                                │
│    Doküman │ Grafik │ Vektör │ Kolonlu │ FTS            │
├─────────────────────────────────────────────────────────┤
│ 4. DEPOLAMA                                             │
│    LSM-Tree │ B-Tree │ WAL │ Bloom │ Sıkıştırma │ Önbellek│
├─────────────────────────────────────────────────────────┤
│ 5. DAĞITIK                                               │
│    Raft Consensus │ Parçalama │ Çoğaltma │ Gossip        │
└─────────────────────────────────────────────────────────┘
```

## Katman 1: İstemci Katmanı

- **İkili Protokol**: Verimli big-endian ikili protokol
- **HTTP/REST**: JSON tabanlı REST API
- **WebSocket**: Tam çift yönlü akış
- **Gömülü**: Süreç içi doğrudan erişim

## Katman 2: Sorgu Katmanı (BaraQL)

1. **Lexer** (`query/lexer.nim`): 80+ token tipi
2. **Parser** (`query/parser.nim`): Recursive descent parser
3. **AST** (`query/ast.nim`): 25+ node çeşidi
4. **IR** (`query/ir.nim`): Ara temsil
5. **Optimizör** (`query/adaptive.nim`): Çapraz modlu optimizasyon
6. **Kod Üretimi** (`query/codegen.nim`): Depolama operasyonlarına çeviri
7. **Çalıştırıcı** (`query/executor.nim`): Paralel yürütme

## Katman 3: Çalıştırma Motorları

### Doküman/KV Motoru
- **LSM-Tree** (`storage/lsm.nim`): MemTable, WAL, SSTables

### Vektör Motoru (`vector/`)
- **HNSW İndeksi** (`vector/engine.nim`): Hiyerarşik Navigable Small World
- **IVF-PQ İndeksi**: Ters dosya indeksi
- **SIMD İşlemleri** (`vector/simd.nim`): AVX2-optimized

### Grafik Motoru (`graph/`)
- BFS, DFS, Dijkstra, PageRank
- **Louvain**: Topluluk tespiti

### Tam Metin Arama (`fts/`)
- Ters indeks, BM25, TF-IDF
- **Çok Dilli**: EN, BG, DE, FR, RU tokenizerları

## Katman 4: Depolama

- **LSM-Tree**: MemTable, WAL, SSTable, Bloom Filter
- **Sayfa Önbelleği**: LRU önbellek
- **Hafıza-eşlenmiş I/O**: mmap tabanlı erişim
- **Kurtarma**: WAL yeniden oynatma

## Katman 5: Dağıtık

- **Raft Consensus** (`core/raft.nim`): Lider seçimi, log çoğaltma
- **Parçalama** (`core/sharding.nim`): Hash, range, consistent hashing
- **Çoğaltma** (`core/replication.nim`): Sync, async, semi-sync
- **Gossip Protokolü** (`core/gossip.nim`): SWIM benzeri

## Temel Tasarım Kararları

1. **Saf Nim**: Cython, Python veya Rust bağımlılığı yok
2. **Birleşik Depolama**: Tek motor KV, grafik, vektör, FTS ve kolonluyi yönetir
3. **Gömülü Mod**: Kütüphane veya sunucu olarak çalışabilir
4. **İkili Protokol**: Özel verimli kablo protokolü
5. **MVCC**: Çok sürümlü eşzamanlılık kontrolü
6. **Şema-Önce**: Kalıtım destekli güçlü tipli şema sistemi
7. **Çapraz Modlu**: Tüm veri modellerinde tek sorgu dili
8. **Resmi Doğrulama**: Temel dağıtık algoritmalar TLA+'da belirtilmiş ve TLC ile model kontrolü yapılmış

## Modül İstatistikleri

| Kategori | Modüller | Kod Satırı | Amaç |
|----------|---------|------------|------|
| Core | 16 | ~4,200 | Sunucu, protokoller, işlemler, dağıtık |
| Storage | 7 | ~3,100 | LSM, B-Tree, WAL, bloom, sıkıştırma, mmap |
| Query | 7 | ~2,800 | Lexer, parser, AST, IR, optimizör, kod üretimi |
| Vector | 3 | ~1,200 | HNSW, IVF-PQ, nicemleme, SIMD |
| Graph | 3 | ~1,000 | Bitişik liste, algoritmalar, topluluk tespiti |
| FTS | 2 | ~900 | Ters indeks, BM25, belirsiz, çok dilli |
| Protocol | 7 | ~2,400 | Wire, HTTP, WebSocket, havuz, auth, hız sınırı |
| Schema | 1 | ~600 | Tipler, bağlantılar, kalıtım |
| Client | 2 | ~800 | Nim ikili istemcisi |
| CLI | 1 | ~400 | İnteraktif BaraQL kabuğu |
| **Toplam** | **49** | **~14,100** | |