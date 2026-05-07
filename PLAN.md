# BaraDB — Оставащи задачи

> Преименуван от `PLAN.md` — всичко завършено е в `PLAN_DONE.md`.

---

## Критични (блокират production)

*Всички критични задачи са завършени. Виж `PLAN_DONE.md`.*

---

## Средни (важни, но не блокират)

### 1. JSON/JSONB Types
- **Статус:** ✅ Валидация при INSERT/UPDATE + wire тип `fkJson`
- **Решение:** `validateType` валидира JSON чрез `std/json`. `valueToWire` връща `fkJson`. Клиентите поддържат JSON сериализация.
- **Липсва:** JSON path operators (`->`, `->>`)

### 2. CTE Execution (WITH RECURSIVE)
- **Статус:** ✅ Non-recursive CTE работи; RECURSIVE се парсва
- **Non-recursive CTE:** Изпълнява чрез materialization в `ctx.cteTables`. `execScan` проверява CTE store преди LSM.
- **Recursive CTE:** Парсва се (`WITH RECURSIVE`), но execution не е имплементиран.

### 3. Multi-Column Indexes
- **Статус:** ✅ Имплементиран
- **Промени:** Parser чете `col1, col2, ...`. AST има `ciColumns`. Executor създава ключ `table.col1.col2` и индексира `val1|val2`. SELECT поддържа exact match за AND chain.
- **Липсва:** Range scan за втора/трета колона; `DROP INDEX`.

### 4. Column Type Metadata в Wire Protocol
- **Статус:** ✅ Сервира реална metadata
- **Промени:** `QueryResult.columnTypes` се попълва от schema. `serializeResult` изпраща `uint8` на колона. Всички 4 клиента (Nim, Python, JS, Rust) са обновени да четат типовете.

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

**9.95/10** — всички production blockers са оправени. Остават само nice-to-have и advanced SQL features.
