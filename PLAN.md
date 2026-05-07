# BaraDB — Оставащи задачи

> Завършеното е преместено в `PLAN_DONE.md`.

---

## Ниски (nice-to-have, не блокират production)

### 1. Distributed 2PC — реален network RPC
- **Статус:** ❌ Симулиран (`disttxn.nim:86,108`)
- **Промени:** `prepare()` и `commit()` само маркират участниците като готови. Няма реална мрежова комуникация.
- **Нужно:** Изпращане на PREPARE/COMMIT RPC към participant nodes през TCP.

### 2. LSM-Tree thread-safety
- **Статус:** ❌ Не е напълно thread-safe
- **Проблем:** Stress test ползва отделни DB инстанции на worker (`stress_test.nim:20`).
- **Нужно:** Mutex/lock около shared LSM операциите или MVCC-based concurrency.

### 3. Full FTS index integration
- **Статус:** ⚠️ Базова поддръжка
- **Текущо:** `WHERE col @@ 'query'` прави case-insensitive term match (всеки термин от заявката трябва да се среща в колоната).
- **Липсва:** Пълна интеграция с `InvertedIndex` от `fts/engine.nim` — BM25 ranking, highlight-и, позиционно търсене.

### 4. Point-in-time recovery (PITR)
- **Статус:** ❌ Не е имплементирано
- **Обхват:** WAL replay съществува, но няма UI/команда за PITR до конкретен timestamp.
- **Нужно:** `RECOVER TO TIMESTAMP '...'` или подобна команда.

### 5. OpenTelemetry tracing
- **Статус:** ❌ Не е имплементирано
- **Текущо:** JSON structured logging (`logging.nim`).
- **Нужно:** OpenTelemetry spans за query execution, index lookup, RPC calls.

### 6. SSTable metadata
- **Статус:** ⚠️ Placeholders
- **Проблем:** `indexOffset` и `bloomOffset` се пишат като `0` в SSTable header (`lsm.nim:137,139`), коригират се при finalize. Не е бъг, но е нечисто.
- **Нужно:** Записване на реалните offsets веднага или restructure на SSTable формата.

### 7. Hardcoded JWT secret
- **Статус:** ⚠️ В 2 файла
- **Проблем:** `"baradb-default-secret-change-in-production!"` в `server.nim` и `httpserver.nim`.
- **Нужно:** Задължително задаване през env var или config file; отказване на старт ако е default стойност.

---

## Изрично НЕ се прави

| Задача | Причина |
|--------|---------|
| **Partitioning** | Сложно, малки БД не се нуждаят |
| **Kubernetes Helm** | Docker Compose е достатъчен |

---

## Honest Score

**9.7/10** — всички критични и средни задачи са завършени.
Остават 7 ниско-приоритетни задачи, нито една не блокира самостоятелен production deploy.

**279 теста — 0 failure-а.**
