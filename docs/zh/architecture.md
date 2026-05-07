# BaraDB 架构

## 概述

BaraDB 是一个**多模态数据库引擎**，使用 Nim 编写，将文档 (KV)、图、向量、列式和全文搜索存储整合在单一引擎中，使用统一的查询语言 **BaraQL**。

## 分层架构

```
┌─────────────────────────────────────────────────────────┐
│ 1. 客户端层                                             │
│    二进制协议 │ HTTP/REST │ WebSocket │ 嵌入式            │
├─────────────────────────────────────────────────────────┤
│ 2. 查询层 (BaraQL)                                      │
│    词法分析 → 解析 → AST → IR → 优化器 → 代码生成         │
├─────────────────────────────────────────────────────────┤
│ 3. 执行引擎                                             │
│    文档 │ 图 │ 向量 │ 列式 │ FTS                         │
├─────────────────────────────────────────────────────────┤
│ 4. 存储层                                               │
│    LSM-Tree │ B-Tree │ WAL │ Bloom │ 压缩 │ 缓存         │
├─────────────────────────────────────────────────────────┤
│ 5. 分布式                                               │
│    Raft 共识 │ 分片 │ 复制 │ Gossip                      │
└─────────────────────────────────────────────────────────┘
```

## 第1层: 客户端层

多种通信协议:

- **二进制协议** (`protocol/wire.nim`): 高效的 big-endian 二进制协议，包含 16 种消息类型
- **HTTP/REST** (`core/httpserver.nim`): 基于 JSON 的 REST API，支持多线程
- **WebSocket** (`core/websocket.nim`): 全双工流式传输
- **嵌入式** (`storage/lsm.nim`): 进程内直接访问

### 连接管理

- **连接池** (`protocol/pool.nim`): 最小/最大连接限制，空闲超时
- **限流** (`protocol/ratelimit.nim`): Token-bucket 全局限流和每客户端限流
- **认证** (`protocol/auth.nim`): HMAC-SHA256 的 JWT 和基于角色的访问
- **TLS/SSL** (`protocol/ssl.nim`): TLS 1.3，自动生成证书

## 第2层: 查询层 (BaraQL)

BaraQL 处理管道:

1. **词法分析器** (`query/lexer.nim`): 将输入标记化为 80+ 种标记类型
2. **解析器** (`query/parser.nim`): 递归下降解析器，生成 AST
3. **AST** (`query/ast.nim`): 300+ 行代码，覆盖 25+ 种节点类型
4. **IR** (`query/ir.nim`): 用于执行计划的中间表示
5. **优化器** (`query/adaptive.nim`): 自适应跨模态查询优化
6. **代码生成** (`query/codegen.nim`): 将 IR 转换为存储操作
7. **执行器** (`query/executor.nim`): 并行执行计划

### 跨模态规划

优化器 (`query/adaptive.nim`) 确定跨引擎的执行顺序:

```
1. 估算每个谓词的选择性
2. 将选择性最高的谓词首先推送到其引擎
3. 使用 Bloom 过滤器进行 KV 查找
4. 并行化独立分支
5. 流式传输结果以避免物化
```

## 第3层: 执行引擎

### 文档/KV 引擎
- **LSM-Tree** (`storage/lsm.nim`): 写优化的存储，包含 MemTable、WAL、SSTables
- **B-Tree 索引** (`storage/btree.nim`): 用于范围扫描的有序索引，支持 COW

### 向量引擎 (`vector/`)
- **HNSW 索引** (`vector/engine.nim`): 分层可导航小世界图
- **IVF-PQ 索引** (`vector/engine.nim`): 倒排文件索引，带乘积量化
- **SIMD 操作** (`vector/simd.nim`): AVX2 优化的距离计算
- **量化** (`vector/quant.nim`): 标量、乘积和二进制量化

### 图引擎 (`graph/`)
- **邻接表** (`graph/engine.nim`): 带边权重的有向图
- **算法** (`graph/engine.nim`): BFS、DFS、Dijkstra、PageRank
- **社区检测** (`graph/community.nim`): Louvain 算法
- **模式匹配** (`graph/community.nim`): 子图同构
- **Cypher 解析器** (`graph/cypher.nim`): 类似 Cypher 的图查询

### 全文搜索 (`fts/`)
- **倒排索引** (`fts/engine.nim`): 词-文档索引
- **排名** (`fts/engine.nim`): BM25 和 TF-IDF 评分
- **模糊搜索** (`fts/engine.nim`): 基于 Levenshtein 距离的匹配
- **多语言** (`fts/multilang.nim`): EN、BG、DE、FR、RU 的分词器

### 列式引擎 (`core/columnar.nim`)
- 用于分析查询的按列存储
- RLE 和字典编码
- SIMD 加速的聚合操作

## 第4层: 存储

- **LSM-Tree** (`storage/lsm.nim`): MemTable、WAL、SSTable、Bloom Filter、压缩
- **页面缓存** (`storage/compaction.nim`): LRU 缓存，支持命中率追踪
- **内存映射 I/O** (`storage/mmap.nim`): 基于 mmap 的文件访问
- **恢复** (`storage/recovery.nim`): WAL 重放和崩溃恢复

### 写路径

```
客户端 → 协议 → 认证 → 解析 → AST → IR → 代码生成
  → StorageOp → MVCC Txn → WAL 写入 → MemTable → 提交
```

### 读路径

```
客户端 → 协议 → 认证 → 解析 → AST → IR → 代码生成
  → StorageOp → MVCC 快照 → MemTable → SSTable → 结果
```

## 第5层: 分布式

- **Raft 共识** (`core/raft.nim`): 领导者选举、日志复制
- **分片** (`core/sharding.nim`): 哈希、范围和一致性哈希
- **复制** (`core/replication.nim`): 同步、异步、半同步模式
- **Gossip 协议** (`core/gossip.nim`): SWIM 风格的成员管理
- **分布式事务** (`core/disttxn.nim`): 两阶段提交

## 关键设计决策

1. **纯 Nim**: 无 Cython、Python 或 Rust 依赖
2. **统一存储**: 一个引擎处理 KV、图、向量、FTS 和列式存储
3. **嵌入式模式**: 可作为库或服务器运行
4. **二进制协议**: 自定义高效有线协议
5. **MVCC**: 多版本并发控制
6. **模式优先**: 带继承的强类型模式系统
7. **跨模态**: 跨所有数据模型的单一查询语言
8. **形式化验证**: 核心分布式算法使用 TLA+ 规范并用 TLC 模型检查

## 模块统计

| 类别 | 模块数 | 代码行数 | 用途 |
|------|--------|----------|------|
| Core | 16 | ~4,200 | 服务器、协议、事务、分布式 |
| Storage | 7 | ~3,100 | LSM、B-Tree、WAL、bloom、压缩、mmap |
| Query | 7 | ~2,800 | 词法分析、解析、AST、IR、优化器、代码生成、执行器 |
| Vector | 3 | ~1,200 | HNSW、IVF-PQ、量化、SIMD |
| Graph | 3 | ~1,000 | 邻接表、算法、社区检测 |
| FTS | 2 | ~900 | 倒排索引、BM25、模糊搜索、多语言 |
| Protocol | 7 | ~2,400 | Wire、HTTP、WebSocket、连接池、认证、限流、SSL |
| Schema | 1 | ~600 | 类型、链接、继承、迁移 |
| Client | 2 | ~800 | Nim 二进制客户端、文件助手 |
| CLI | 1 | ~400 | 交互式 BaraQL shell |
| **总计** | **49** | **~14,100** | |

## 数据流图

### 简单查询

```
┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐
│ Client │───→│ Lexer  │───→│ Parser │───→│  IR    │───→│ Codegen│
└────────┘    └────────┘    └────────┘    └────────┘    └───┬────┘
                                                             │
┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐       │
│ Result │←───│ Format │←───│ Execute│←───│ Storage│←──────┘
└────────┘    └────────┘    └────────┘    └────────┘
```

### 跨模态查询

```
                     ┌─────────────┐
                     │   Parser    │
                     └──────┬──────┘
                            │
                     ┌──────▼──────┐
                     │   Adaptive  │
                     │   Optimizer │
                     └──────┬──────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
     ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
     │    Vector   │ │    Graph    │ │     FTS     │
     │    Engine   │ │    Engine   │ │   Engine    │
     └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
            │               │               │
            └───────────────┼───────────────┘
                            │
                     ┌──────▼──────┐
                     │    Join     │
                     │   & Sort    │
                     └──────┬──────┘
                            │
                     ┌──────▼──────┐
                     │    Result   │
                     └─────────────┘
```