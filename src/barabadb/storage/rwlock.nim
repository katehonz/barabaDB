## Simple reader-writer lock for LSM concurrent reads.
## Multiple readers OR one writer. Writers are exclusive.
## `acquire` / `release` are write-side (backward compatible with Lock-style usage).
import std/locks

type
  RwLock* = object
    mu: Lock
    readers: int          ## active readers
    writer: bool          ## writer holds exclusive access
    waitingWriters: int   ## prefer writers to avoid reader starvation of compact/flush
    canRead: Cond
    canWrite: Cond

proc initRwLock*(rw: var RwLock) =
  initLock(rw.mu)
  initCond(rw.canRead)
  initCond(rw.canWrite)
  rw.readers = 0
  rw.writer = false
  rw.waitingWriters = 0

proc deinitRwLock*(rw: var RwLock) =
  deinitCond(rw.canRead)
  deinitCond(rw.canWrite)
  deinitLock(rw.mu)

proc acquireRead*(rw: var RwLock) =
  ## Shared read lock. Blocks while a writer is active or waiting (writer preference).
  acquire(rw.mu)
  while rw.writer or rw.waitingWriters > 0:
    wait(rw.canRead, rw.mu)
  inc rw.readers
  release(rw.mu)

proc releaseRead*(rw: var RwLock) =
  acquire(rw.mu)
  dec rw.readers
  if rw.readers == 0:
    # Wake one waiting writer
    signal(rw.canWrite)
  release(rw.mu)

proc acquireWrite*(rw: var RwLock) =
  ## Exclusive write lock.
  acquire(rw.mu)
  inc rw.waitingWriters
  while rw.writer or rw.readers > 0:
    wait(rw.canWrite, rw.mu)
  dec rw.waitingWriters
  rw.writer = true
  release(rw.mu)

proc releaseWrite*(rw: var RwLock) =
  acquire(rw.mu)
  rw.writer = false
  # Prefer draining writers, else open the gate for readers
  if rw.waitingWriters > 0:
    signal(rw.canWrite)
  else:
    broadcast(rw.canRead)
  release(rw.mu)

# Lock-compatible names: default exclusive (used by compaction, put, flush)
proc acquire*(rw: var RwLock) {.inline.} = acquireWrite(rw)
proc release*(rw: var RwLock) {.inline.} = releaseWrite(rw)

template withReadLock*(rw: var RwLock, body: untyped) =
  acquireRead(rw)
  try:
    body
  finally:
    releaseRead(rw)

template withWriteLock*(rw: var RwLock, body: untyped) =
  acquireWrite(rw)
  try:
    body
  finally:
    releaseWrite(rw)
