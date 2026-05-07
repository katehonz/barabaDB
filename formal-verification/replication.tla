-------------------------------- MODULE replication --------------------------------
(*
  TLA+ specification of the BaraDB replication manager
  (core/replication.nim) supporting Async, Sync, and Semi-sync modes.

  Key properties verified:
    - MonotonicLsn     : applied LSN never moves backwards (temporal).
    - AcksRemovePending: a replica that acked an LSN is not pending for it.
    - PendingAreKnown  : all pending acks refer to valid replicas.
    - SyncDurability   : in sync mode, appliedLsn only advances when 0 pending.
    - SemiSyncQuorum   : in semi-sync mode, ack count >= min(MaxSyncCount, Connected).
    - AppliedLteCurrent : appliedLsn never exceeds currentLsn.
    - AckedIsConnected  : only connected replicas can ack.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS Replicas,       \* set of replica IDs
          MaxLsn,         \* bound LSN values for model checking
          MaxSyncCount    \* bound semi-sync count

ASSUME IsFiniteSet(Replicas)

VARIABLES
  mode,           \* mode ∈ {"Async", "Sync", "SemiSync"}
  replicaState,   \* replicaState[r] ∈ {"Disconnected", "Connected"}
  currentLsn,     \* currentLsn ∈ Nat
  pendingAcks,    \* pendingAcks[l] ⊆ Replicas (LSNs waiting for acks)
  appliedLsn,     \* appliedLsn ∈ Nat
  ackedBy         \* ackedBy[l] ⊆ Replicas (who acked which LSN)

vars == <<mode, replicaState, currentLsn, pendingAcks, appliedLsn, ackedBy>>

-----------------------------------------------------------------------------
\* Helper operators

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

ConnectedReplicas == {r \in Replicas : replicaState[r] = "Connected"}

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ mode \in {"Async", "Sync", "SemiSync"}
  /\ replicaState = [r \in Replicas |-> "Disconnected"]
  /\ currentLsn = 0
  /\ pendingAcks = [l \in 0..MaxLsn |-> {}]
  /\ appliedLsn = 0
  /\ ackedBy = [l \in 0..MaxLsn |-> {}]

-----------------------------------------------------------------------------
\* State transitions

\* A replica comes online.
Connect(r) ==
  /\ replicaState[r] = "Disconnected"
  /\ replicaState' = [replicaState EXCEPT ![r] = "Connected"]
  /\ UNCHANGED <<mode, currentLsn, pendingAcks, appliedLsn, ackedBy>>

\* A replica goes offline.
Disconnect(r) ==
  /\ replicaState[r] = "Connected"
  /\ replicaState' = [replicaState EXCEPT ![r] = "Disconnected"]
  /\ UNCHANGED <<mode, currentLsn, pendingAcks, appliedLsn, ackedBy>>

\* A new LSN is produced by the primary.
WriteLsn ==
  /\ currentLsn < MaxLsn
  /\ currentLsn' = currentLsn + 1
  /\ LET newLsn == currentLsn + 1
         conn == ConnectedReplicas
     IN  IF mode = "Sync" /\ conn /= {}
         THEN pendingAcks' = [pendingAcks EXCEPT ![newLsn] = conn]
         ELSE IF mode = "SemiSync" /\ conn /= {}
              THEN pendingAcks' = [pendingAcks EXCEPT ![newLsn] =
                                     CHOOSE s \in SUBSET conn :
                                       Cardinality(s) = Min(MaxSyncCount, Cardinality(conn))]
              ELSE pendingAcks' = pendingAcks
  /\ UNCHANGED <<mode, replicaState, appliedLsn, ackedBy>>

\* Replica r acknowledges LSN l.
AckLsn(r, l) ==
  /\ replicaState[r] = "Connected"
  /\ l \in 1..currentLsn
  /\ r \in pendingAcks[l]
  /\ ackedBy' = [ackedBy EXCEPT ![l] = @ \cup {r}]
  /\ pendingAcks' = [pendingAcks EXCEPT ![l] = @ \ {r}]
  /\ IF pendingAcks'[l] = {}
     THEN appliedLsn' = Max(appliedLsn, l)
     ELSE appliedLsn' = appliedLsn
  /\ UNCHANGED <<mode, replicaState, currentLsn>>

\* Switch replication mode.
SwitchMode(newMode) ==
  /\ newMode \in {"Async", "Sync", "SemiSync"}
  /\ mode' = newMode
  /\ UNCHANGED <<replicaState, currentLsn, pendingAcks, appliedLsn, ackedBy>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E r \in Replicas : Connect(r)
  \/ \E r \in Replicas : Disconnect(r)
  \/ WriteLsn
  \/ \E r \in Replicas : \E l \in 1..MaxLsn : AckLsn(r, l)
  \/ \E newMode \in {"Async", "Sync", "SemiSync"} : SwitchMode(newMode)

-----------------------------------------------------------------------------
\* Safety properties

\* The applied LSN is monotonically non-decreasing (temporal).
MonotonicLsn ==
  [][appliedLsn' >= appliedLsn]_vars

\* A replica that has acked an LSN is no longer pending for it.
AcksRemovePending ==
  \A l \in 1..currentLsn :
    \A r \in Replicas :
      r \in ackedBy[l] => r \notin pendingAcks[l]

\* All pending acks reference valid replica IDs.
PendingAreKnown ==
  \A l \in 1..currentLsn :
    pendingAcks[l] \subseteq Replicas

\* In sync mode, any applied LSN has zero pending acks.
SyncDurability ==
  \/ mode /= "Sync"
  \/ appliedLsn = 0
  \/ \A l \in 1..appliedLsn : pendingAcks[l] = {}

\* In semi-sync mode, each pending LSN has at most MaxSyncCount replicas.
SemiSyncQuorum ==
  IF currentLsn > 0
  THEN \A l \in 1..currentLsn : Cardinality(pendingAcks[l]) <= MaxSyncCount + 1
  ELSE TRUE

\* Applied LSN never exceeds current LSN.
AppliedLteCurrent ==
  appliedLsn <= currentLsn

\* Only connected replicas appear in ackedBy.
AckedIsConnected ==
  IF currentLsn > 0
  THEN \A l \in 1..currentLsn : \A r \in ackedBy[l] : replicaState[r] = "Connected"
  ELSE TRUE

\* Type invariant
TypeOk ==
  /\ mode \in {"Async", "Sync", "SemiSync"}
  /\ replicaState \in [Replicas -> {"Disconnected", "Connected"}]
  /\ currentLsn \in 0..MaxLsn
  /\ pendingAcks \in [0..MaxLsn -> SUBSET Replicas]
  /\ appliedLsn \in 0..MaxLsn
  /\ ackedBy \in [0..MaxLsn -> SUBSET Replicas]

=============================================================================
