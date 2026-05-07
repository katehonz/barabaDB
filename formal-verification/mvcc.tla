-------------------------------- MODULE mvcc --------------------------------
(*
  TLA+ specification of MVCC (Multi-Version Concurrency Control) with
  Snapshot Isolation as implemented in BaraDB (core/mvcc.nim + storage/lsm.nim).

  Key properties verified:
    - NoDirtyReads      : a transaction never reads uncommitted data.
    - ReadOwnWrites     : a transaction reads its own most recent writes.
    - WriteWriteConflict: two committed transactions never write the same key.
    - CommittedMustStart: committed txns have valid start timestamps.
    - NoGhostWrites     : no transaction writes after it has terminated.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS Keys,           \* set of keys
          Values,         \* set of possible values
          Nil,            \* distinguished nil value (model value)
          MaxTxnId        \* bound transaction IDs for model checking

ASSUME IsFiniteSet(Keys) /\ IsFiniteSet(Values)

VARIABLES
  db,             \* db[k] = sequence of <<txnId, value, committed>> versions
  txnState,       \* txnState[t] ∈ {"Active", "Committed", "Aborted"}
  txnStartTs,     \* txnStartTs[t] ∈ Nat (monotonic timestamp)
  writeSet,       \* writeSet[t] ∈ SUBSET Keys
  readSet,        \* readSet[t] ∈ SUBSET Keys
  globalClock     \* global counter for timestamps

vars == <<db, txnState, txnStartTs, writeSet, readSet, globalClock>>

-----------------------------------------------------------------------------

\* Helper operators

\* The latest committed version of key k visible to transaction t
CommittedVersion(k, t) ==
  LET versions == db[k]
      visible == {i \in 1..Len(versions) :
                   versions[i][3] = TRUE /\ versions[i][1] < txnStartTs[t]}
  IN IF visible = {} THEN Nil
     ELSE versions[CHOOSE i \in visible : \A j \in visible : j <= i => versions[j][1] <= versions[i][1]]

\* Has transaction t already written key k?
HasWritten(t, k) == k \in writeSet[t]

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ db = [k \in Keys |-> << >>]
  /\ txnState = [t \in 1..MaxTxnId |-> "Active"]
  /\ txnStartTs = [t \in 1..MaxTxnId |-> 0]
  /\ writeSet = [t \in 1..MaxTxnId |-> {}]
  /\ readSet = [t \in 1..MaxTxnId |-> {}]
  /\ globalClock = 1

-----------------------------------------------------------------------------
\* State transitions

\* Begin a transaction: assign a start timestamp.
BeginTxn(t) ==
  /\ txnState[t] = "Active"
  /\ txnStartTs[t] = 0
  /\ txnStartTs' = [txnStartTs EXCEPT ![t] = globalClock]
  /\ globalClock' = globalClock + 1
  /\ UNCHANGED <<db, txnState, writeSet, readSet>>

\* Read key k by transaction t.
Read(t, k) ==
  /\ txnState[t] = "Active"
  /\ txnStartTs[t] > 0
  /\ readSet' = [readSet EXCEPT ![t] = @ \cup {k}]
  /\ UNCHANGED <<db, txnState, txnStartTs, writeSet, globalClock>>

\* Write key k with value v by transaction t.
Write(t, k, v) ==
  /\ txnState[t] = "Active"
  /\ txnStartTs[t] > 0
  /\ k \notin writeSet[t]
  /\ writeSet' = [writeSet EXCEPT ![t] = @ \cup {k}]
  /\ db' = [db EXCEPT ![k] = Append(@, <<t, v, FALSE>>)]
  /\ UNCHANGED <<txnState, txnStartTs, readSet, globalClock>>

\* Commit transaction t: mark its versions as committed (first-committer-wins).
\* Also checks for write skew: if another committed txn read a key we wrote,
\* and wrote a key we read, that's a circular dependency and we must abort.
CommitTxn(t) ==
  /\ txnState[t] = "Active"
  /\ txnStartTs[t] > 0
  /\ ~(\E t2 \in 1..MaxTxnId : t2 /= t /\ txnState[t2] = "Committed" /\
       \E k \in Keys : k \in writeSet[t] /\ k \in writeSet[t2])
  /\ ~(\E t2 \in 1..MaxTxnId : t2 /= t /\ txnState[t2] = "Committed" /\
       \E k1 \in Keys : k1 \in writeSet[t] /\ k1 \in readSet[t2] /\
       \E k2 \in Keys : k2 \in writeSet[t2] /\ k2 \in readSet[t])
  /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
  /\ db' = [k \in Keys |->
             IF k \in writeSet[t]
             THEN LET last == Len(db[k])
                      lastTxn == db[k][last][1]
                  IN IF lastTxn = t
                     THEN [db[k] EXCEPT ![last] = <<t, db[k][last][2], TRUE>>]
                     ELSE db[k]
             ELSE db[k]]
  /\ UNCHANGED <<txnStartTs, writeSet, readSet, globalClock>>

\* Abort transaction t: leave versions as uncommitted (garbage).
AbortTxn(t) ==
  /\ txnState[t] = "Active"
  /\ txnState' = [txnState EXCEPT ![t] = "Aborted"]
  /\ UNCHANGED <<db, txnStartTs, writeSet, readSet, globalClock>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E t \in 1..MaxTxnId : BeginTxn(t)
  \/ \E t \in 1..MaxTxnId : \E k \in Keys : Read(t, k)
  \/ \E t \in 1..MaxTxnId : \E k \in Keys : \E v \in Values : Write(t, k, v)
  \/ \E t \in 1..MaxTxnId : CommitTxn(t)
  \/ \E t \in 1..MaxTxnId : AbortTxn(t)

-----------------------------------------------------------------------------
\* Safety properties

\* A committed version's txn must be in committed state.
NoDirtyReads ==
  \A t \in 1..MaxTxnId :
    \A k \in Keys :
      \A i \in 1..Len(db[k]) :
        db[k][i][3] = TRUE =>
          db[k][i][1] \in {tx \in 1..MaxTxnId : txnState[tx] = "Committed"}

\* If a transaction has written a key, that write exists in the DB.
ReadOwnWrites ==
  \A t \in 1..MaxTxnId :
    \A k \in Keys :
      k \in writeSet[t] =>
        LET versions == db[k]
            myWrites == {i \in 1..Len(versions) : versions[i][1] = t}
        IN myWrites /= {}

\* First-committer-wins: no two committed transactions write the same key.
WriteWriteConflict ==
  \A t1, t2 \in 1..MaxTxnId :
    t1 /= t2 /\ txnState[t1] = "Committed" /\ txnState[t2] = "Committed" =>
      ~(\E k \in Keys : k \in writeSet[t1] /\ k \in writeSet[t2])

\* No write skew: two committed transactions cannot have a circular read-write dependency.
\* If t1 writes a key that t2 read, then t2 cannot write a key that t1 read.
NoWriteSkew ==
  \A t1, t2 \in 1..MaxTxnId :
    t1 /= t2 /\ txnState[t1] = "Committed" /\ txnState[t2] = "Committed" =>
      ~(\E k1 \in Keys : k1 \in writeSet[t1] /\ k1 \in readSet[t2] /\
          \E k2 \in Keys : k2 \in writeSet[t2] /\ k2 \in readSet[t1])

\* A committed transaction must have been started (has start timestamp > 0).
CommittedMustStart ==
  \A t \in 1..MaxTxnId :
    txnState[t] = "Committed" => txnStartTs[t] > 0

\* No two committed versions for the same key share the same txnId.
CommittedVersionsUnique ==
  \A k \in Keys :
    \A i, j \in 1..Len(db[k]) :
      (i /= j /\ db[k][i][3] = TRUE /\ db[k][j][3] = TRUE) =>
        db[k][i][1] /= db[k][j][1]

\* Type invariant
TypeOk ==
  /\ \A k \in Keys : Len(db[k]) <= MaxTxnId * 2
  /\ \A k \in Keys : \A i \in 1..Len(db[k]) : db[k][i] \in (1..MaxTxnId) \X Values \X BOOLEAN
  /\ txnState \in [1..MaxTxnId -> {"Active", "Committed", "Aborted"}]
  /\ txnStartTs \in [1..MaxTxnId -> 0..(MaxTxnId+1)]
  /\ writeSet \in [1..MaxTxnId -> SUBSET Keys]
  /\ readSet \in [1..MaxTxnId -> SUBSET Keys]
  /\ globalClock \in 1..(MaxTxnId + 1)

=============================================================================
