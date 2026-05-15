# Plan: ID Generators & Sequence System

## Goal
Add auto-generated ID support to BaraDB so users don't need to manually supply IDs on INSERT.

## Phase 1: ID Generators

### 1.1 AUTO_INCREMENT on INTEGER columns
- Add `AUTO_INCREMENT` keyword to lexer
- Parse in CREATE TABLE: `id INTEGER PRIMARY KEY AUTO_INCREMENT`
- Store auto-increment state per table in ExecutionContext (counter)
- On INSERT without explicit ID → auto-populate with next value
- Thread-safe counter (atomic increment)

### 1.2 SERIAL / BIGSERIAL as syntactic sugar
- `SERIAL` = `INTEGER AUTO_INCREMENT`
- `BIGSERIAL` = `BIGINT AUTO_INCREMENT`
- Already partially parsed — wire to auto-increment logic

### 1.3 UUID generation
- Add `gen_random_uuid()` or `uuid()` as built-in function
- Can be used in INSERT: `INSERT INTO t (id) VALUES (uuid())`
- Also usable as DEFAULT: `id UUID DEFAULT uuid()`
- Use Nim's std/oids or crypto random

### 1.4 RETURNING clause
- After INSERT, return generated values
- `INSERT INTO t (name) VALUES ('x') RETURNING id`
- Already partially parsed — wire to execution

### 1.5 CREATE SEQUENCE / nextval / currval
- `CREATE SEQUENCE seq_name START 1 INCREMENT 1`
- `nextval('seq_name')` → returns next value
- `currval('seq_name')` → returns current value
- Store sequences in ExecutionContext

### 1.6 Snowflake ID (distributed)
- 64-bit ID = timestamp(41) + node_id(10) + sequence(12)
- `snowflake_id(node_id)` function
- For future distributed use

## Phase 2: JOIN Optimizations (future)

### 2.1 Hash Join
- For equi-join ON a.col = b.col
- Build hash table on smaller side, probe with larger
- O(N+M) instead of O(N*M)

### 2.2 Index Nested Loop Join
- If index exists on join column → probe index per left row
- O(N * log M) instead of O(N*M)

### 2.3 Merge Join
- For sorted inputs
- Two-pointer sweep O(N+M)

## Phase 3: Foreign Key Enforcement (future)

### 3.1 CASCADE DELETE
### 3.2 SET NULL on delete
### 3.3 RESTRICT on delete
### 3.4 ON UPDATE CASCADE
### 3.5 FK check on UPDATE (not just INSERT)

## Implementation Order
1. AUTO_INCREMENT (lexer + parser + executor)
2. SERIAL/BIGSERIAL sugar
3. UUID function
4. RETURNING clause
5. Sequences (CREATE SEQUENCE / nextval / currval)
6. Snowflake ID function
