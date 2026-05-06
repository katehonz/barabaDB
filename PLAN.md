# BaraDB — Оставащи задачи

> Преименуван от `PLAN.md` — всичко завършено е в `PLAN_DONE.md`.

---

## Критични (блокират production)

*Всички критични задачи са завършени. Виж `PLAN_DONE.md`.*

---

## Средни (важни, но не блокират)

### 1. JSON/JSONB Types
- **Статус:** ❌ Stub
- **Проблем:** `vkJson` типът съществува, но се третира като TEXT string — няма JSON path operators (`->`, `->>`)
- **Решение:** Имплементиране на JSON parsing/querying или поне валидация на JSON при INSERT

### 2. CTE Execution (WITH RECURSIVE)
- **Статус:** 🟡 Парсва се, но не се изпълнява
- **Non-recursive CTE:** Работи чрез subquery execution
- **Recursive CTE:** Не е имплементиран

### 3. Multi-Column Indexes
- **Статус:** ❌ Не е имплементиран
- **Проблем:** `CREATE INDEX idx ON t(col1, col2)` дава parse error — parser чете само 1 колона
- **Решение:** Промяна на parser + AST + executor да поддържат списък от колони

### 4. Column Type Metadata в Wire Protocol
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

**9.9/10** — всички production blockers са оправени.
