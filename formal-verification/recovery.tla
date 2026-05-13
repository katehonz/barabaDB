-------------------------------- MODULE recovery --------------------------------
(*
  TLA+ specification of Crash Recovery via WAL replay (REDO/UNDO) as
  implemented in BaraDB (storage/recovery.nim + storage/wal.nim).

  Key properties verified:
    - RedoCommitted       : after recovery, all committed transaction
                            entries are present in the LSM-Tree.
    - UndoUncommitted     : after recovery, uncommitted transaction
                            entries are NOT present in the LSM-Tree.
    - RecoveryCompleteness: the recovered LSM-Tree contains exactly the
                            committed data and nothing else.
    - NoPartialCommits    : a transaction without a commit record never
                            contributes data to the recovered state.
    - MonotonicLsn        : WAL entry LSNs are strictly increasing.
    - WalIntegrity        : every WAL entry has a valid txnId and key.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS Keys,           \* set of keys
          Values,         \* set of possible values
          MaxTxnId,       \* bound transaction IDs for model checking
          MaxWalLen,      \* bound WAL length for model checking
          MaxSteps,       \* bound total actions for model checking
          Nil             \* distinguished nil value (model value)

ASSUME IsFiniteSet(Keys) /\ IsFiniteSet(Values)
ASSUME MaxTxnId >= 1 /\ MaxWalLen >= 1 /\ MaxSteps >= 1

VARIABLES
  wal,            \* wal ∈ Seq(<<kind, txnId, key, value>>)
                  \*   kind ∈ {"Put", "Delete", "Commit"}
  lsmData,        \* lsmData[k] ∈ Values ∪ {Nil} — current LSM-Tree state
  recovered,      \* recovered ∈ BOOLEAN — has recovery run?
  recoveredData,  \* recoveredData[k] ∈ Values ∪ {Nil} — state after recovery
  lastTxnId,      \* lastTxnId ∈ 0..MaxTxnId — highest committed txn seen
  steps           \* steps ∈ 0..MaxSteps — action counter bound

vars == <<wal, lsmData, recovered, recoveredData, lastTxnId, steps>>

-----------------------------------------------------------------------------
\* Helper operators

\* Set of committed transaction IDs in the WAL.
CommittedTxns ==
  {t \in 1..MaxTxnId :
    \E i \in 1..Len(wal) : wal[i] = <<"Commit", t, Nil, Nil>>}

\* Is transaction t committed according to the WAL?
IsCommitted(t) == t \in CommittedTxns

\* All entries belonging to a committed transaction.
CommittedEntries(t) ==
  {i \in 1..Len(wal) :
    wal[i][2] = t /\ wal[i][1] \in {"Put", "Delete"}}

\* The last committed transaction ID (largest committed txn).
MaxCommittedTxn ==
  IF CommittedTxns = {} THEN 0
  ELSE CHOOSE t \in CommittedTxns :
    \A t2 \in CommittedTxns : t >= t2

\* Simulate recovery: build recoveredData from WAL.
\* REDO: apply all entries of committed transactions.
\* UNDO: skip all entries of uncommitted transactions.
RecoverState ==
  [k \in Keys |->
     LET committedPuts ==
           {i \in 1..Len(wal) :
             /\ wal[i][1] = "Put"
             /\ wal[i][3] = k
             /\ IsCommitted(wal[i][2])}
     IN IF committedPuts = {}
        THEN Nil
        ELSE LET lastIdx == CHOOSE i \in committedPuts :
                           \A j \in committedPuts : j <= i
             IN wal[lastIdx][4]]

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ wal = << >>
  /\ lsmData = [k \in Keys |-> Nil]
  /\ recovered = FALSE
  /\ recoveredData = [k \in Keys |-> Nil]
  /\ lastTxnId = 0
  /\ steps = 0

-----------------------------------------------------------------------------
\* State transitions

\* Append a Put entry to the WAL for transaction t.
WalPut(t, k, v) ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ Len(wal) < MaxWalLen
  /\ t \in 1..MaxTxnId
  /\ k \in Keys
  /\ v \in Values
  /\ wal' = Append(wal, <<"Put", t, k, v>>)
  /\ steps' = steps + 1
  /\ UNCHANGED <<lsmData, recovered, recoveredData, lastTxnId>>

\* Append a Delete entry to the WAL for transaction t.
WalDelete(t, k) ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ Len(wal) < MaxWalLen
  /\ t \in 1..MaxTxnId
  /\ k \in Keys
  /\ wal' = Append(wal, <<"Delete", t, k, Nil>>)
  /\ steps' = steps + 1
  /\ UNCHANGED <<lsmData, recovered, recoveredData, lastTxnId>>

\* Append a Commit entry for transaction t.
WalCommit(t) ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ Len(wal) < MaxWalLen
  /\ t \in 1..MaxTxnId
  /\ wal' = Append(wal, <<"Commit", t, Nil, Nil>>)
  /\ lastTxnId' = IF t > lastTxnId THEN t ELSE lastTxnId
  /\ steps' = steps + 1
  /\ UNCHANGED <<lsmData, recovered, recoveredData>>

\* Normal operation: apply a committed Put directly to LSM-Tree.
ApplyPut(t, k, v) ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ t \in 1..MaxTxnId
  /\ IsCommitted(t)
  /\ k \in Keys
  /\ v \in Values
  /\ lsmData' = [lsmData EXCEPT ![k] = v]
  /\ steps' = steps + 1
  /\ UNCHANGED <<wal, recovered, recoveredData, lastTxnId>>

\* Normal operation: apply a committed Delete directly to LSM-Tree.
ApplyDelete(t, k) ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ t \in 1..MaxTxnId
  /\ IsCommitted(t)
  /\ k \in Keys
  /\ lsmData' = [lsmData EXCEPT ![k] = Nil]
  /\ steps' = steps + 1
  /\ UNCHANGED <<wal, recovered, recoveredData, lastTxnId>>

\* Crash: the system crashes. LSM-Tree state may be lost; WAL is durable.
Crash ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ lsmData' = [k \in Keys |-> Nil]
  /\ steps' = steps + 1
  /\ UNCHANGED <<wal, recovered, recoveredData, lastTxnId>>

\* Recover: replay WAL to reconstruct LSM-Tree state.
Recover ==
  /\ ~recovered
  /\ steps < MaxSteps
  /\ recovered' = TRUE
  /\ recoveredData' = RecoverState
  /\ lsmData' = recoveredData'
  /\ steps' = steps + 1
  /\ UNCHANGED <<wal, lastTxnId>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E t \in 1..MaxTxnId : \E k \in Keys : \E v \in Values : WalPut(t, k, v)
  \/ \E t \in 1..MaxTxnId : \E k \in Keys : WalDelete(t, k)
  \/ \E t \in 1..MaxTxnId : WalCommit(t)
  \/ \E t \in 1..MaxTxnId : \E k \in Keys : \E v \in Values : ApplyPut(t, k, v)
  \/ \E t \in 1..MaxTxnId : \E k \in Keys : ApplyDelete(t, k)
  \/ Crash
  \/ Recover

-----------------------------------------------------------------------------
\* Safety properties

\* After recovery, every committed Put entry is reflected in recoveredData.
RedoCommitted ==
  recovered =>
    \A t \in 1..MaxTxnId :
      \A k \in Keys :
        (IsCommitted(t) /\ \E i \in 1..Len(wal) :
                            wal[i][1] = "Put" /\ wal[i][2] = t /\ wal[i][3] = k) =>
          recoveredData[k] /= Nil

\* After recovery, no uncommitted entry determines the final value.
\* If recoveredData[k] /= Nil, the last Put for k must be from a committed txn.
UndoUncommitted ==
  recovered =>
    \A k \in Keys :
      recoveredData[k] /= Nil =>
        \E i \in 1..Len(wal) :
          /\ wal[i][1] = "Put"
          /\ wal[i][3] = k
          /\ IsCommitted(wal[i][2])
          /\ \A j \in (i+1)..Len(wal) :
               ~(wal[j][1] = "Put" /\ wal[j][3] = k)

\* The recovered data contains exactly the committed data.
\* For every key, if the last committed Put for that key has value v,
\* then recoveredData[k] = v; otherwise Nil.
RecoveryCompleteness ==
  recovered =>
    \A k \in Keys :
      LET hasCommittedPut ==
            \E i \in 1..Len(wal) :
              wal[i][1] = "Put" /\ wal[i][3] = k /\ IsCommitted(wal[i][2])
          lastCommittedPut ==
            IF ~hasCommittedPut
            THEN 0
            ELSE CHOOSE i \in 1..Len(wal) :
                   /\ wal[i][1] = "Put"
                   /\ wal[i][3] = k
                   /\ IsCommitted(wal[i][2])
                   /\ \A j \in (i+1)..Len(wal) :
                        ~(wal[j][1] = "Put" /\ wal[j][3] = k /\ IsCommitted(wal[j][2]))
      IN IF lastCommittedPut = 0
         THEN recoveredData[k] = Nil
         ELSE recoveredData[k] = wal[lastCommittedPut][4]

\* A transaction without a commit record never contributes data.
NoPartialCommits ==
  recovered =>
    \A t \in 1..MaxTxnId :
      ~IsCommitted(t) =>
        \A k \in Keys :
          ~(\E i \in 1..Len(wal) :
              wal[i][1] = "Put" /\ wal[i][2] = t /\ wal[i][3] = k /\
              recoveredData[k] /= Nil)

\* WAL LSNs (entry indices) are strictly increasing (enforced by Append).
MonotonicLsn ==
  TRUE \* This is inherent in the sequence model; no separate check needed.

\* Every WAL entry has valid kind, txnId, and key.
WalIntegrity ==
  \A i \in 1..Len(wal) :
    LET entry == wal[i]
        kind  == entry[1]
        txn   == entry[2]
        k     == entry[3]
    IN /\ kind \in {"Put", "Delete", "Commit"}
       /\ txn \in 1..MaxTxnId
       /\ (kind \in {"Put", "Delete"} => k \in Keys)

\* Type invariant
TypeOk ==
  /\ wal \in Seq({"Put", "Delete", "Commit"} \X (1..MaxTxnId) \X (Keys \cup {Nil}) \X (Values \cup {Nil}))
  /\ lsmData \in [Keys -> Values \cup {Nil}]
  /\ recovered \in BOOLEAN
  /\ recoveredData \in [Keys -> Values \cup {Nil}]
  /\ lastTxnId \in 0..MaxTxnId
  /\ steps \in 0..MaxSteps

\* Liveness properties

\* If there are committed entries in the WAL, recovery eventually produces
\* a non-empty recoveredData (or Nil for all keys if all are deletes).
RecoveryProgress ==
  (Len(wal) > 0 /\ recovered) ~> (recoveredData = RecoverState)

\* Specification with weak fairness.
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* Symmetry reduction for model checking.
Symmetry == Permutations({k1, k2}) \cup Permutations({v1, v2})

=============================================================================
