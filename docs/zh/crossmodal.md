# 跨模态查询

BaraDB 的独特能力是执行跨越多个存储引擎的查询，使用单一的 BaraQL 语句。

## 概述

- **文档/KV** (LSM-Tree) — 结构化记录
- **图** (邻接表) — 关系
- **向量** (HNSW/IVF-PQ) — 相似性搜索
- **全文** (倒排索引) — 文本搜索
- **列式** — 分析聚合

## 查询模式

### 向量 + 全文

```sql
SELECT title FROM articles
WHERE MATCH(body) AGAINST('machine learning')
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;
```

### 图 + 向量

```sql
MATCH (u:User)-[:KNOWS]->(friend:User)
WHERE u.name = 'Alice'
ORDER BY cosine_distance(friend.taste_vector, u.taste_vector)
RETURN friend.name;
```

## 优化

### 跨模态查询规划器

1. 最具选择性的过滤器优先
2. 将谓词下推到每个引擎
3. 使用 Bloom 过滤器进行 KV 查找
4. 并行化独立分支

## 性能

| 查询类型 | 延迟（10K 行） |
|----------|-----------------|
| FTS + Vector | 15 ms |
| Graph + Vector | 25 ms |
| FTS + Aggregate | 12 ms |