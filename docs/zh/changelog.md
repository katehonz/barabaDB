# 更新日志

## [0.1.0] — 2025-01-15

### 新增功能

- **核心存储引擎**
  - LSM-Tree 包含 MemTable、WAL、SSTables 和 size-tiered compaction
  - B-Tree 有序索引支持范围扫描和 MVCC copy-on-write
  - Bloom 过滤器优化 SSTable 跳过
  - Memory-mapped I/O
  - LRU 页面缓存

- **查询引擎 (BaraQL)**
  - SQL 兼容的词法分析器，80+ 种标记类型
  - 递归下降解析器，生成 25+ 种节点类型的 AST
  - 中间表示（IR）
  - 自适应查询优化器，支持跨模态规划
  - 并行查询执行器

- **BaraQL 语言功能**
  - SELECT、INSERT、UPDATE、DELETE
  - WHERE、ORDER BY、LIMIT、OFFSET
  - GROUP BY、HAVING、聚合函数
  - INNER JOIN、LEFT JOIN、RIGHT JOIN、FULL JOIN、CROSS JOIN
  - CTEs (WITH)
  - 子查询
  - CASE 表达式
  - UNION、INTERSECT、EXCEPT

- **向量引擎**
  - HNSW 近似最近邻搜索
  - IVF-PQ 大规模向量搜索
  - SIMD 优化的距离函数
  - 量化：标量 8-bit/4-bit、乘积量化、二进制

- **图引擎**
  - 邻接表存储
  - BFS 和 DFS 遍历
  - Dijkstra 最短路径
  - PageRank
  - Louvain 社区检测
  - Cypher 查询解析器

- **全文搜索**
  - 倒排索引
  - BM25 排名
  - TF-IDF
  - 模糊搜索
  - 多语言分词器

- **协议**
  - Binary wire protocol
  - HTTP/REST JSON API
  - WebSocket
  - Connection pooling
  - JWT 认证
  - TLS/SSL

- **分布式系统**
  - Raft 共识
  - Hash、range、consistent-hash 分片
  - 同步/异步/半同步复制
  - Gossip 协议
  - 两阶段提交

### 性能

- LSM-Tree: 580K 写入/秒，720K 读取/秒
- B-Tree: 1.2M 插入/秒，1.5M 查找/秒
- Vector SIMD: 850K 余弦距离/秒（dim=768）

### 测试

- 56 个测试套件中的 262 个测试
- 100% 通过率