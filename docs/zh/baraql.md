# BaraQL - 查询语言参考

BaraQL 是一个与 SQL 兼容的查询语言，包含图、向量和文档操作的扩展。

## 数据类型

| 类型 | 描述 | 示例 |
|------|------|------|
| `null` | 空值 | `null` |
| `bool` | 布尔值 | `true`, `false` |
| `int8` | 8 位有符号整数 | `127` |
| `int16` | 16 位有符号整数 | `32767` |
| `int32` | 32 位有符号整数 | `2147483647` |
| `int64` | 64 位有符号整数 | `9223372036854775807` |
| `float32` | 32 位浮点数 | `3.14` |
| `float64` | 64 位浮点数 | `3.14159265359` |
| `str` | UTF-8 字符串 | `'hello'` |
| `bytes` | 原始字节 | `0xDEADBEEF` |
| `array<T>` | 同构数组 | `[1, 2, 3]` |
| `vector` | Float32 向量 | `[0.1, 0.2, 0.3]` |
| `object` | 键值对象 | `{"a": 1}` |
| `datetime` | ISO 8601 时间戳 | `'2025-01-15T10:30:00Z'` |
| `uuid` | UUID v4 | `'550e8400-e29b-41d4-a716-446655440000'` |
| `json` | JSON 文档 | `{"key": "value"}` |
| `jsonb` | 二进制 JSON（已验证） | `{"key": "value"}` |

## 基本查询

### SELECT

```sql
-- 所有列
SELECT * FROM users;

-- 特定列
SELECT name, age FROM users;

-- 别名
SELECT name AS full_name, age AS years FROM users;

-- DISTINCT
SELECT DISTINCT department FROM employees;

-- LIMIT 和 OFFSET
SELECT * FROM users LIMIT 10 OFFSET 20;
```

### WHERE

```sql
-- 比较运算符
SELECT * FROM users WHERE age > 18;
SELECT * FROM users WHERE age >= 18 AND age <= 65;
SELECT * FROM users WHERE name = 'Alice';
SELECT * FROM users WHERE name != 'Bob';

-- 范围
SELECT * FROM users WHERE age BETWEEN 18 AND 65;

-- 集合成员
SELECT * FROM users WHERE department IN ('Engineering', 'Sales');

-- 模式匹配
SELECT * FROM users WHERE name LIKE 'A%';
SELECT * FROM users WHERE name ILIKE 'alice';  -- 不区分大小写

-- NULL 检查
SELECT * FROM users WHERE email IS NOT NULL;

-- 逻辑运算符
SELECT * FROM users WHERE age > 18 AND (department = 'Engineering' OR department = 'Sales');
```

### ORDER BY

```sql
-- 升序（默认）
SELECT * FROM users ORDER BY age;

-- 降序
SELECT * FROM users ORDER BY age DESC;

-- 多列
SELECT * FROM users ORDER BY department ASC, age DESC;
```

### INSERT

```sql
-- 单行
INSERT users { name := 'Alice', age := 30 };

-- 显式类型
INSERT User { name := 'Alice', age := 30 };

-- 多行
INSERT users {
  { name := 'Alice', age := 30 },
  { name := 'Bob', age := 25 }
};
```

### UPDATE

```sql
-- 更新所有行
UPDATE users SET status = 'active';

-- 条件更新
UPDATE users SET age = 31 WHERE name = 'Alice';

-- 更新多列
UPDATE users SET age = 32, status = 'premium' WHERE name = 'Alice';
```

### DELETE

```sql
-- 删除所有行
DELETE FROM users;

-- 条件删除
DELETE FROM users WHERE age < 18;
```

## 聚合和分组

### 聚合函数

| 函数 | 描述 |
|------|------|
| `count(*)` | 计算所有行 |
| `count(column)` | 计算非 NULL 值 |
| `sum(column)` | 值之和 |
| `avg(column)` | 平均值 |
| `min(column)` | 最小值 |
| `max(column)` | 最大值 |
| `stddev(column)` | 标准差 |
| `variance(column)` | 方差 |

### GROUP BY

```sql
SELECT department, count(*) as emp_count, avg(salary) as avg_salary
FROM employees
GROUP BY department;

-- 带 HAVING
SELECT department, count(*) as emp_count
FROM employees
GROUP BY department
HAVING count(*) > 5;

-- 多重分组
SELECT department, role, count(*), avg(salary)
FROM employees
GROUP BY department, role;
```

## JOIN

```sql
-- INNER JOIN
SELECT u.name, o.total
FROM users u
INNER JOIN orders o ON u.id = o.user_id;

-- LEFT JOIN
SELECT u.name, o.total
FROM users u
LEFT JOIN orders o ON u.id = o.user_id;

-- RIGHT JOIN
SELECT u.name, o.total
FROM users u
RIGHT JOIN orders o ON u.id = o.user_id;

-- FULL JOIN
SELECT u.name, o.total
FROM users u
FULL JOIN orders o ON u.id = o.user_id;

-- CROSS JOIN
SELECT u.name, p.name
FROM users u
CROSS JOIN products p;

-- 多重 JOIN
SELECT u.name, o.id, p.name
FROM orders o
JOIN users u ON o.user_id = u.id
JOIN products p ON o.product_id = p.id;

-- Self JOIN
SELECT e.name, m.name as manager
FROM employees e
JOIN employees m ON e.manager_id = m.id;
```

## CTE（公用表表达式）

```sql
-- 单个 CTE
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users;

-- 多个 CTE
WITH
  recent AS (
    SELECT * FROM orders WHERE date > '2025-01-01'
  ),
  totals AS (
    SELECT user_id, sum(amount) as total FROM recent GROUP BY user_id
  )
SELECT u.name, t.total
FROM users u
JOIN totals t ON u.id = t.user_id;

-- 递归 CTE
WITH RECURSIVE subordinates AS (
  SELECT id, name, manager_id FROM employees WHERE name = 'CEO'
  UNION ALL
  SELECT e.id, e.name, e.manager_id
  FROM employees e
  JOIN subordinates s ON e.manager_id = s.id
)
SELECT * FROM subordinates;
```

## 子查询

```sql
-- SELECT 中的子查询
SELECT name, (SELECT count(*) FROM orders WHERE user_id = u.id) as order_count
FROM users u;

-- FROM 中的子查询
SELECT * FROM (SELECT id, name FROM users WHERE active = true) AS active;

-- WHERE 中的子查询 (IN)
SELECT name FROM users WHERE id IN (SELECT user_id FROM orders);

-- WHERE 中的子查询 (EXISTS)
SELECT name FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id);

-- 相关子查询
SELECT name FROM users u
WHERE age > (SELECT avg(age) FROM users WHERE department = u.department);
```

## CASE 表达式

```sql
SELECT name,
  CASE
    WHEN age < 13 THEN 'child'
    WHEN age < 20 THEN 'teenager'
    WHEN age < 65 THEN 'adult'
    ELSE 'senior'
  END AS category
FROM users;

-- 简单 CASE
SELECT name,
  CASE department
    WHEN 'Engineering' THEN 'Tech'
    WHEN 'Sales' THEN 'Revenue'
    ELSE 'Other'
  END AS division
FROM employees;
```

## 集合运算

```sql
-- UNION（去重）
SELECT name FROM customers
UNION
SELECT name FROM suppliers;

-- UNION ALL（保留重复）
SELECT name FROM customers
UNION ALL
SELECT name FROM suppliers;

-- INTERSECT
SELECT name FROM customers
INTERSECT
SELECT name FROM suppliers;

-- EXCEPT
SELECT name FROM customers
EXCEPT
SELECT name FROM suppliers;
```

## 模式定义

### CREATE TYPE

```sql
CREATE TYPE Person {
  name: str,
  age: int32
};

-- 带必填字段
CREATE TYPE User {
  email: str REQUIRED,
  name: str,
  age: int32,
  created_at: datetime DEFAULT now()
};

-- 带链接
CREATE TYPE Movie {
  title: str,
  year: int32,
  director: Person
};

-- 带计算属性
CREATE TYPE Employee {
  name: str,
  base_salary: float64,
  bonus: float64,
  total_compensation: float64 COMPUTED (base_salary + bonus)
};
```

### 继承

```sql
CREATE TYPE Animal {
  name: str
};

CREATE TYPE Dog EXTENDING Animal {
  breed: str
};

CREATE TYPE Cat EXTENDING Animal {
  indoor: bool
};
```

### 索引

```sql
CREATE INDEX idx_users_name ON users(name);
CREATE UNIQUE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_age ON users(age) USING btree;
```

### DROP

```sql
DROP TYPE User;
DROP INDEX idx_users_name;
```

## 向量搜索

```sql
-- 插入向量
INSERT articles {
  title := 'Nim Programming',
  embedding := [0.1, 0.2, 0.3, 0.4]
};

-- 相似性搜索（余弦距离）
SELECT title FROM articles
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- 欧几里得距离
SELECT title FROM articles
ORDER BY l2_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;

-- 点积
SELECT title FROM articles
ORDER BY dot_product(embedding, [0.1, 0.2, 0.3, 0.4]) DESC
LIMIT 5;

-- 带元数据过滤
SELECT title FROM articles
WHERE category = 'tech'
ORDER BY cosine_distance(embedding, [0.1, 0.2, 0.3, 0.4])
LIMIT 5;
```

## 图模式

```sql
-- 查找 Alice 的朋友
MATCH (p:Person)-[:KNOWS]->(friend:Person)
WHERE p.name = 'Alice'
RETURN friend.name;

-- 查找最短路径
MATCH path = shortestPath((a:Person)-[:KNOWS*1..5]->(b:Person))
WHERE a.name = 'Alice' AND b.name = 'Bob'
RETURN path;

-- 查找所有关系
MATCH (p:Person)-[r]->(other)
WHERE p.name = 'Alice'
RETURN type(r), other.name;

-- 多跳
MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)
WHERE a.name = 'Alice'
RETURN c.name;

-- 带聚合
MATCH (p:Person)-[:KNOWS]->(friend)
RETURN p.name, count(friend) as friend_count
ORDER BY friend_count DESC;
```

## 全文搜索

```sql
-- 基本搜索
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('database programming');

-- 带相关性评分
SELECT title, relevance()
FROM articles
WHERE MATCH(title, body) AGAINST('Nim language')
ORDER BY relevance() DESC;

-- 布尔模式
SELECT * FROM articles
WHERE MATCH(title, body) AGAINST('+Nim -Python' IN BOOLEAN MODE);

-- 模糊搜索
SELECT * FROM articles
WHERE MATCH(title) AGAINST('programing' WITH FUZZINESS 2);
```

## 事务

```sql
BEGIN;
INSERT users { name := 'Alice', age := 30 };
INSERT orders { user_id := last_insert_id(), total := 100 };
COMMIT;

-- 带保存点
BEGIN;
INSERT users { name := 'Bob', age := 25 };
SAVEPOINT sp1;
INSERT orders { user_id := last_insert_id(), total := 200 };
-- 哎呀，回滚到保存点
ROLLBACK TO sp1;
COMMIT;
```

## 用户定义函数

```sql
-- 注册 UDF
CREATE FUNCTION greet(name str) -> str {
  RETURN 'Hello, ' || name || '!';
};

-- 使用
SELECT greet(name) FROM users;

-- 内置函数
SELECT abs(-5), sqrt(16), lower('HELLO'), len('test');
```

## 查询提示

```sql
-- 强制使用索引
SELECT /*+ USE_INDEX(idx_users_age) */ * FROM users WHERE age > 18;

-- 强制近似向量搜索
SELECT /*+ APPROXIMATE */ * FROM vectors
ORDER BY cosine_distance(embedding, [...])
LIMIT 10;

-- 并行执行
SELECT /*+ PARALLEL(4) */ * FROM large_table;
```

## 窗口函数

```sql
-- 排名函数
SELECT
  name,
  department,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
  RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS r,
  DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dr
FROM employees;

-- 值函数
SELECT
  name,
  salary,
  LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_salary,
  LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_salary,
  FIRST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS cheapest,
  LAST_VALUE(name) OVER (PARTITION BY department ORDER BY salary) AS most_expensive
FROM employees;

-- 分布函数
SELECT name, NTILE(4) OVER (ORDER BY salary) AS quartile FROM employees;
```

### 帧规格

```sql
-- ROWS 帧
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
)

-- RANGE 帧
SUM(salary) OVER (
  PARTITION BY department
  ORDER BY hire_date
  RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## 多租户 ERP

BaraDB 支持在单个数据库实例中运行多个公司（租户），使用**行级安全性（RLS）**结合**会话变量**。

### 会话变量

```sql
SET app.tenant_id = 'company-123';
SELECT current_setting('app.tenant_id') AS tenant;
```

### 当前用户 / 角色

```sql
SELECT current_user AS me, current_role AS my_role;
```

### RLS 租户隔离

```sql
-- 在表上启用 RLS
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- 创建按租户过滤的策略
CREATE POLICY tenant_isolation ON invoices
  FOR SELECT USING (tenant_id = current_setting('app.tenant_id'));

-- 每个会话只能看到自己的数据
SET app.tenant_id = 'company-a';
SELECT * FROM invoices;  -- 仅限 company-a 的行
```

### 为什么选择多租户？

- **一个实例，多个租户** — 无需运行 100 个独立的数据库
- **JSONB 文档** — 模式灵活的存储，易于为每个租户添加字段
- **RLS 保证隔离** — 数据库强制执行租户边界，而不仅仅是应用程序

## 支持的关键字

| 类别 | 关键字 |
|----------|----------|
| DQL | SELECT, FROM, WHERE, ORDER BY, GROUP BY, HAVING, LIMIT, OFFSET, DISTINCT |
| DML | INSERT, UPDATE, DELETE, SET, VALUES |
| DDL | CREATE TYPE, DROP TYPE, CREATE INDEX, DROP INDEX, ALTER TYPE |
| Join | INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, CROSS JOIN, ON |
| Set | UNION, UNION ALL, INTERSECT, EXCEPT |
| CTEs | WITH, RECURSIVE, AS |
| Case | CASE, WHEN, THEN, ELSE, END |
| Transaction | BEGIN, COMMIT, ROLLBACK, SAVEPOINT |
| Graph | MATCH, RETURN, WHERE, shortestPath, type |
| FTS | MATCH, AGAINST, relevance, IN BOOLEAN MODE, WITH FUZZINESS |
| Vector | cosine_distance, euclidean_distance, inner_product, l1_distance, l2_distance, <-> |
| JSON | ->, ->> |
| FTS | @@ (BM25 match) |
| Recovery | RECOVER TO TIMESTAMP |
| Functions | count, sum, avg, min, max, stddev, variance, abs, sqrt, lower, upper, len, trim, substr, now, last_insert_id, current_setting |
| Session | SET, current_setting, current_user, current_role |
| Window | OVER, PARTITION BY, ROWS, RANGE, UNBOUNDED PRECEDING, CURRENT ROW, FOLLOWING |
| Window Functions | ROW_NUMBER, RANK, DENSE_RANK, LEAD, LAG, FIRST_VALUE, LAST_VALUE, NTILE |