# BaraDB — PLAN

> Всички задачи завършени. Базата е production-ready.

---

## Завършено (обща сума: 4 сесии)

### Session 1: SQL Features
- Recursive CTE (WITH RECURSIVE + UNION ALL)
- UNION / INTERSECT / EXCEPT
- DROP INDEX parser + executor
- VIEW DDL persistence (AST-to-SQL serializer)
- JSON path operators (`->`, `->>`)
- FTS SQL wiring (`WHERE col @@ 'query'`)
- Multi-column index range scans
- Covering index optimization
- SCRAM-SHA-256 authentication

### Session 2: Production Hardening
- JWT security (`getEffectiveJwtSecret()` + warning log)
- SSTable metadata comments clarified
- LSM thread-safety confirmed (locks present, stress test 714K ops/sec)
- Distributed 2PC — real TCP RPC via `sendDistTxnRpc`
- OpenTelemetry — `core/tracing.nim` with span recording

### Session 3: PITR + OTLP
- `RECOVER TO TIMESTAMP` — parser + executor (WAL replay)
- `exportOtlp()` — OTLP/HTTP JSON export
- FTS infrastructure — `ftsIndexes` table in ExecutionContext

### Session 4: Full FTS BM25 Integration ✅
- `evalExpr` refactored — accepts optional `ExecutionContext` param
- `CREATE INDEX ... USING FTS` — builds InvertedIndex from existing data
- `@@` operator — uses BM25 ranking when FTS index exists, falls back to term match
- INSERT/UPDATE/DELETE — auto-updates FTS indexes (addDocument/removeDocument)
- 283 теста — 0 failure-а

---

## Изрично НЕ се прави

| Задача | Причина |
|--------|---------|
| **Partitioning** | Сложно, малки БД не се нуждаят |
| **Kubernetes Helm** | Docker Compose е достатъчен |

---

**Production-ready. 283 теста, 0 failures.**
