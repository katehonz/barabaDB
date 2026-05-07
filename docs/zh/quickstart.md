# BaraDB - 快速入门指南

## 启动服务器

构建 BaraDB 后，启动服务器:

```bash
./build/baradadb
```

服务器默认在 `localhost:9470` 上启动。

## 通过 CLI 连接

BaraDB 包含一个交互式 shell:

```bash
./build/baradadb --shell
```

## 基本操作

### 创建模式

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};
```

### 插入数据

```sql
INSERT Person { name := 'Alice', age := 30 };
INSERT Person { name := 'Bob', age := 25 };
```

### 查询数据

```sql
SELECT name, age FROM Person WHERE age > 18;
```

### 更新数据

```sql
UPDATE Person SET age = 31 WHERE name = 'Alice';
```

### 删除数据

```sql
DELETE FROM Person WHERE name = 'Bob';
```

## 高级查询

### JOIN

```sql
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;
```

### 聚合

```sql
SELECT department, count(*), avg(salary)
FROM employees
GROUP BY department
HAVING count(*) > 5;
```

### CTE (公共表表达式)

```sql
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;
```

## 向量搜索

```sql
-- 插入向量
INSERT vectors { id := 1, embedding := [0.1, 0.2, 0.3] };

-- 搜索相似
SELECT * FROM vectors ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3]) LIMIT 10;
```

## 图操作

```sql
-- 匹配图模式
MATCH (p:Person)-[:KNOWS]->(other:Person)
WHERE p.name = 'Alice'
RETURN other.name;
```

## 全文搜索

```sql
-- 搜索文档
SELECT * FROM articles WHERE MATCH(title, body) AGAINST('database');
```

## HTTP/REST API

```bash
# GET 请求
curl http://localhost:9470/api/users

# POST 请求
curl -X POST http://localhost:9470/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "age": 30}'
```

## 下一步

- [BaraQL 参考](baraql.md)
- [存储引擎](storage.md)
- [架构概述](architecture.md)
- [协议参考](protocol.md)