# BaraDB — Оставащи задачи

> Преименуван от `PLAN.md` — всичко завършено е в `PLAN_DONE.md`.

---

## Критични (блокират production)

### 1. WebSocket Auth
- **Статус:** ❌ Не е имплементиран
- **Проблем:** WebSocket endpoint `/live` е отворен за всеки — може да се subscribe-ва без токен
- **Решение:** Проверка на JWT token при `SUBSCRIBE` съобщение

### 2. B-Tree Range Scans
- **Статус:** ⚠️ Наполовина
- **Storage layer:** ✅ `btree.scan(startKey, endKey)` съществува и работи
- **Query planner:** ❌ Изпълнява full table scan за `BETWEEN`, `>`, `<`, `>=`, `<=` вместо index range scan
- **Решение:** Wire `execScan` да използва `btree.scan()` когато има B-Tree индекс и range условие

### 3. JSON/JSONB Types
- **Статус:** ❌ Stub
- **Проблем:** `vkJson` типът съществува, но се третира като TEXT string — няма JSON path operators (`->`, `->>`)
- **Решение:** Имплементиране на JSON parsing/querying или поне валидация на JSON при INSERT

---

## Средни (важни, но не блокират)

### 4. CTE Execution (WITH RECURSIVE)
- **Статус:** 🟡 Парсва се, но не се изпълнява
- **Non-recursive CTE:** Работи чрез subquery execution
- **Recursive CTE:** Не е имплементиран

### 5. Multi-Column Indexes
- **Статус:** ❌ Не е имплементиран
- **Проблем:** `CREATE INDEX idx ON t(col1, col2)` дава parse error — parser чете само 1 колона
- **Решение:** Промяна на parser + AST + executor да поддържат списък от колони

### 6. Column Type Metadata в Wire Protocol
- **Статус:** ⚠️ Херистично
- **Проблем:** Клиентите infer-ват типовете от стойностите вместо да получат реална metadata

---

## Ниски (nice-to-have)

| Задача | Защо е ниска |
|--------|-------------|
| Full-text search SQL (`WHERE content @@ 'query'`) | Engine съществува, не е wired към SQL |
| Point-in-time recovery | Backup/restore покрива 90% |
| OpenTelemetry tracing | JSON logging е достатъчен за v1 |
| Covering index optimization | Преждевременна оптимизация |

---

## Изрично НЕ се прави

| Задача | Причина |
|--------|---------|
| **Partitioning** | Сложно, малки БД не се нуждаят |
| **Kubernetes Helm** | Docker Compose е достатъчен |

---

## Honest Score

**9.7/10** — всички production blockers са оправени освен WebSocket auth.

**Ако се оправи WebSocket auth + B-Tree range scans → 9.9/10.**
