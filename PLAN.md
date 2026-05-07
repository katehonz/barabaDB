# BaraDB — Оставащи задачи

> Завършеното е в `PLAN_DONE.md`.

---

## Ниски (nice-to-have, не блокират production)

### 1. Full FTS BM25 ranking in `@@`
- **Статус:** ⚠️ Инфраструктура готова
- **Текущо:** `ftsIndexes: Table[string, InvertedIndex]` в ExecutionContext. FTS engine (`fts/engine.nim`) с BM25, tokenization. `@@` прави term-based substring match.
- **Липсва:** `evalExpr` няма достъп до `ctx` за BM25 lookup. Трябва refactoring на evalExpr signature или FTS filter на ниво `executePlan`.

---

## Изрично НЕ се прави

| Задача | Причина |
|--------|---------|
| **Partitioning** | Сложно, малки БД не се нуждаят |
| **Kubernetes Helm** | Docker Compose е достатъчен |

---

## Завършено (обща сума: 3 сесии)

**281 теста — 0 failure-а.**

### Session 1: SQL Features
- Recursive CTE, UNION/INTERSECT/EXCEPT, DROP INDEX, VIEW persistence
- JSON path (`->`, `->>`), FTS SQL (`@@`), multi-col range scan, covering index, SCRAM auth

### Session 2: Production Hardening
- JWT security, WAL reader, tracing spans, 2PC real RPC, stress test fix

### Session 3: PITR + OpenTelemetry
- `RECOVER TO TIMESTAMP` — parser + executor (WAL replay)
- `core/tracing.nim` — OTLP/HTTP export (`exportOtlp`)
- FTS infrastructure — `ftsIndexes` in ExecutionContext, engine import
