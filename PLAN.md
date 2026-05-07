# BaraDB — Оставащи задачи

> Завършеното е преместено в `PLAN_DONE.md`.

---

## Ниски (nice-to-have, не блокират production)

### 1. Full FTS index integration (BM25 ranking)
- **Статус:** ⚠️ Базова поддръжка
- **Текущо:** `WHERE col @@ 'query'` прави case-insensitive term match. FTS engine (`fts/engine.nim`) съществува с BM25, inverted index, tokenization.
- **Липсва:** Пълна интеграция — `CREATE INDEX ... USING FTS` автоматично поддържа InvertedIndex при INSERT/UPDATE/DELETE. `@@` използва BM25 вместо substring.

### 2. Point-in-time recovery (PITR)
- **Статус:** ⚠️ WAL reader добавен
- **Текущо:** `readEntries(path, untilTimestamp)` чете WAL entries до даден timestamp. Backup/restore чрез tar.gz snapshot работи.
- **Липсва:** `RECOVER TO TIMESTAMP '...'` команда, която прилага WAL entries до timestamp.

### 3. OpenTelemetry tracing
- **Статус:** ⚠️ Базов tracer
- **Текущо:** `core/tracing.nim` — span recording, enable/disable, JSON export. `executeQuery` създава span за всяка заявка.
- **Липсва:** OTLP/gRPC export, integration с external collector.

---

## Завършено в последните 2 сесии (2026-05-07)

### Session 1: SQL Features
- Recursive CTE (WITH RECURSIVE + UNION ALL)
- UNION / INTERSECT / EXCEPT
- DROP INDEX
- VIEW DDL persistence
- JSON path operators (`->`, `->>`)
- FTS SQL wiring (`WHERE col @@ 'query'`)
- Multi-column index range scans
- Covering index optimization
- SCRAM-SHA-256 authentication

### Session 2: Production Hardening
- JWT secret — `getEffectiveJwtSecret()` helper + warning log при липса на конфигурация
- SSTable metadata — коментари изяснени (offsets се patch-ват коректно)
- LSM thread-safety — locks вече съществуват, stress test обновен
- WAL reader — `readEntries(path, untilTimestamp)` за PITR
- OpenTelemetry — `core/tracing.nim` с span recording, `executeQuery` tracing
- Distributed 2PC — реален TCP RPC вместо simulated (host="" → local fallback)
- `addParticipant` има default параметри (host="", port=0)

---

## Изрично НЕ се прави

| Задача | Причина |
|--------|---------|
| **Partitioning** | Сложно, малки БД не се нуждаят |
| **Kubernetes Helm** | Docker Compose е достатъчен |

---

**279 теста — 0 failure-а.**
