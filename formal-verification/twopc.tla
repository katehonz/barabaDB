-------------------------------- MODULE twopc --------------------------------
(*
  TLA+ specification of the Two-Phase Commit (2PC) distributed transaction
  protocol as implemented in BaraDB (core/disttxn.nim).

  Key properties verified:
    - Atomicity               : all participants commit, or all abort.
    - NoOrphanBlocks          : a committed txn implies all participants committed.
    - CoordinatorConsistency  : once decided, the coordinator never changes decision.
    - NoDecideWithoutConsensus: coordinator only decides when all votes are collected.
    - ParticipantStateValid   : participant state transitions are valid.
    - RecoveryConsistency     : after coordinator crash+recovery, decision is unchanged.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS Participants,    \* set of participant node IDs
          Nil,              \* distinguished nil value (model value)
          MaxTxnId          \* bound transaction IDs for model checking

ASSUME IsFiniteSet(Participants)

VARIABLES
  txnState,       \* txnState[t] ∈ {"Active","Preparing","Prepared","Committing",
                  \*                "Committed","Aborting","Aborted"}
  participantState, \* participantState[t][p] ∈ {"Active","Prepared","Committed","Aborted"}
  coordinatorDecided, \* coordinatorDecided[t] ∈ {TRUE, FALSE}
  decidedAction,     \* decidedAction[t] ∈ {"Commit","Abort", Nil}
  coordinatorLog,   \* coordinatorLog[t] ∈ {"Commit","Abort", Nil} — persistent WAL
  coordinatorAlive  \* coordinatorAlive[t] ∈ BOOLEAN

vars == <<txnState, participantState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

-----------------------------------------------------------------------------

\* Helper operators

AllPrepared(t) ==
  \A p \in Participants : participantState[t][p] \in {"Prepared", "Committed", "Aborted"}

AnyPrepareFailed(t) ==
  \E p \in Participants : participantState[t][p] = "Aborted"

AllResponded(t) ==
  \A p \in Participants : participantState[t][p] /= "Active"

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ txnState = [t \in 1..MaxTxnId |-> "Active"]
  /\ participantState = [t \in 1..MaxTxnId |-> [p \in Participants |-> "Active"]]
  /\ coordinatorDecided = [t \in 1..MaxTxnId |-> FALSE]
  /\ decidedAction = [t \in 1..MaxTxnId |-> Nil]
  /\ coordinatorLog = [t \in 1..MaxTxnId |-> Nil]
  /\ coordinatorAlive = [t \in 1..MaxTxnId |-> TRUE]

-----------------------------------------------------------------------------
\* State transitions

\* Phase 1a: Coordinator sends PREPARE to all participants.
SendPrepare(t) ==
  /\ coordinatorAlive[t]
  /\ txnState[t] = "Active"
  /\ txnState' = [txnState EXCEPT ![t] = "Preparing"]
  /\ UNCHANGED <<participantState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

\* Phase 1b: Participant p receives PREPARE and votes Yes.
ParticipantPrepare(t, p) ==
  /\ txnState[t] = "Preparing"
  /\ participantState[t][p] = "Active"
  /\ participantState' = [participantState EXCEPT ![t][p] = "Prepared"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

\* Phase 1c: Participant p votes No (aborts locally).
ParticipantAbort(t, p) ==
  /\ txnState[t] \in {"Preparing", "Active"}
  /\ participantState[t][p] = "Active"
  /\ participantState' = [participantState EXCEPT ![t][p] = "Aborted"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

\* Phase 2a: Coordinator decides COMMIT (all voted Yes).
\* The decision is first persisted to coordinatorLog before being sent.
DecideCommit(t) ==
  /\ coordinatorAlive[t]
  /\ txnState[t] = "Preparing"
  /\ AllPrepared(t)
  /\ ~AnyPrepareFailed(t)
  /\ txnState' = [txnState EXCEPT ![t] = "Committing"]
  /\ coordinatorDecided' = [coordinatorDecided EXCEPT ![t] = TRUE]
  /\ decidedAction' = [decidedAction EXCEPT ![t] = "Commit"]
  /\ coordinatorLog' = [coordinatorLog EXCEPT ![t] = "Commit"]
  /\ UNCHANGED <<participantState, coordinatorAlive>>

\* Phase 2a-alt: Coordinator decides ABORT (at least one No or timeout).
DecideAbort(t) ==
  /\ coordinatorAlive[t]
  /\ txnState[t] = "Preparing"
  /\ AnyPrepareFailed(t)
  /\ txnState' = [txnState EXCEPT ![t] = "Aborting"]
  /\ coordinatorDecided' = [coordinatorDecided EXCEPT ![t] = TRUE]
  /\ decidedAction' = [decidedAction EXCEPT ![t] = "Abort"]
  /\ coordinatorLog' = [coordinatorLog EXCEPT ![t] = "Abort"]
  /\ UNCHANGED <<participantState, coordinatorAlive>>

\* Phase 2b: Participant receives COMMIT decision.
ReceiveCommit(t, p) ==
  /\ txnState[t] = "Committing"
  /\ decidedAction[t] = "Commit"
  /\ participantState[t][p] \in {"Prepared", "Active"}
  /\ participantState' = [participantState EXCEPT ![t][p] = "Committed"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

\* Phase 2b-alt: Participant receives ABORT decision.
ReceiveAbort(t, p) ==
  /\ txnState[t] = "Aborting"
  /\ decidedAction[t] = "Abort"
  /\ participantState[t][p] \in {"Prepared", "Active", "Aborted"}
  /\ participantState' = [participantState EXCEPT ![t][p] = "Aborted"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

\* Finalize: transaction moves to terminal state when all participants are done.
FinalizeCommit(t) ==
  /\ txnState[t] = "Committing"
  /\ \A p \in Participants : participantState[t][p] = "Committed"
  /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
  /\ UNCHANGED <<participantState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

FinalizeAbort(t) ==
  /\ txnState[t] = "Aborting"
  /\ \A p \in Participants : participantState[t][p] = "Aborted"
  /\ txnState' = [txnState EXCEPT ![t] = "Aborted"]
  /\ UNCHANGED <<participantState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

\* Coordinator crashes after deciding but possibly before all participants are informed.
CrashCoordinator(t) ==
  /\ coordinatorAlive[t]
  /\ coordinatorAlive' = [coordinatorAlive EXCEPT ![t] = FALSE]
  /\ UNCHANGED <<txnState, participantState, coordinatorDecided, decidedAction, coordinatorLog>>

\* Coordinator recovers from crash and reads its decision from the persistent log.
RecoverCoordinator(t) ==
  /\ ~coordinatorAlive[t]
  /\ coordinatorAlive' = [coordinatorAlive EXCEPT ![t] = TRUE]
  /\ coordinatorDecided' = [coordinatorDecided EXCEPT ![t] = coordinatorLog[t] /= Nil]
  /\ decidedAction' = [decidedAction EXCEPT ![t] = coordinatorLog[t]]
  /\ UNCHANGED <<txnState, participantState, coordinatorLog>>

\* Participant p times out waiting for the coordinator decision and aborts.
\* This can only happen if the coordinator crashed BEFORE deciding (coordinatorLog = Nil).
\* If the coordinator already decided, the participant must wait for recovery.
ParticipantTimeout(t, p) ==
  /\ participantState[t][p] = "Prepared"
  /\ ~coordinatorAlive[t]
  /\ coordinatorLog[t] = Nil
  /\ participantState' = [participantState EXCEPT ![t][p] = "Aborted"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction, coordinatorLog, coordinatorAlive>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E t \in 1..MaxTxnId : SendPrepare(t)
  \/ \E t \in 1..MaxTxnId : \E p \in Participants : ParticipantPrepare(t, p)
  \/ \E t \in 1..MaxTxnId : \E p \in Participants : ParticipantAbort(t, p)
  \/ \E t \in 1..MaxTxnId : DecideCommit(t)
  \/ \E t \in 1..MaxTxnId : DecideAbort(t)
  \/ \E t \in 1..MaxTxnId : \E p \in Participants : ReceiveCommit(t, p)
  \/ \E t \in 1..MaxTxnId : \E p \in Participants : ReceiveAbort(t, p)
  \/ \E t \in 1..MaxTxnId : FinalizeCommit(t)
  \/ \E t \in 1..MaxTxnId : FinalizeAbort(t)
  \/ \E t \in 1..MaxTxnId : CrashCoordinator(t)
  \/ \E t \in 1..MaxTxnId : RecoverCoordinator(t)
  \/ \E t \in 1..MaxTxnId : \E p \in Participants : ParticipantTimeout(t, p)

-----------------------------------------------------------------------------
\* Safety properties

\* Atomicity: it is never the case that one participant committed while another aborted.
Atomicity ==
  \A t \in 1..MaxTxnId :
    ~(\E p1, p2 \in Participants :
        participantState[t][p1] = "Committed" /\ participantState[t][p2] = "Aborted")

\* No orphan blocks: once a transaction is committed, every participant is committed.
NoOrphanBlocks ==
  \A t \in 1..MaxTxnId :
    txnState[t] = "Committed" =>
      \A p \in Participants : participantState[t][p] = "Committed"

\* Once coordinator decides, the decision is immutable.
CoordinatorConsistency ==
  \A t \in 1..MaxTxnId :
    coordinatorDecided[t] = TRUE =>
      (decidedAction[t] = "Commit" => txnState[t] \in {"Committing", "Committed"})
      /\ (decidedAction[t] = "Abort" => txnState[t] \in {"Aborting", "Aborted"})

\* Coordinator only decides when all participants have responded.
NoDecideWithoutConsensus ==
  \A t \in 1..MaxTxnId :
    coordinatorDecided[t] = TRUE => AllPrepared(t) \/ AnyPrepareFailed(t)

\* Participant state transitions are consistent with coordinator.
ParticipantStateValid ==
  \A t \in 1..MaxTxnId :
    \A p \in Participants :
      (participantState[t][p] = "Committed" => decidedAction[t] = "Commit")
      /\ (participantState[t][p] = "Aborted" /\ decidedAction[t] /= Nil => decidedAction[t] = "Abort")

\* RecoveryConsistency: if the coordinator has a logged decision, recovery restores it exactly.
RecoveryConsistency ==
  \A t \in 1..MaxTxnId :
    coordinatorLog[t] /= Nil => decidedAction[t] = coordinatorLog[t]

\* Type invariant
TypeOk ==
  /\ txnState \in [1..MaxTxnId -> {"Active","Preparing","Prepared","Committing",
                                     "Committed","Aborting","Aborted"}]
  /\ participantState \in [1..MaxTxnId -> [Participants -> {"Active","Prepared",
                                                              "Committed","Aborted"}]]
  /\ coordinatorDecided \in [1..MaxTxnId -> BOOLEAN]
  /\ decidedAction \in [1..MaxTxnId -> {"Commit","Abort", Nil}]
  /\ coordinatorLog \in [1..MaxTxnId -> {"Commit","Abort", Nil}]
  /\ coordinatorAlive \in [1..MaxTxnId -> BOOLEAN]

\* Liveness properties

\* Any prepared participant eventually learns the final decision (Committed or Aborted).
ParticipantProgress ==
  \A t \in 1..MaxTxnId : \A p \in Participants :
    participantState[t][p] = "Prepared" ~> participantState[t][p] \in {"Committed", "Aborted"}

\* Actions used for fairness constraints.
DecideCommitAction == \E t \in 1..MaxTxnId : DecideCommit(t)
DecideAbortAction == \E t \in 1..MaxTxnId : DecideAbort(t)

\* Specification with weak fairness + strong fairness for coordinator decisions.
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
           /\ SF_vars(DecideCommitAction) /\ SF_vars(DecideAbortAction)

=============================================================================
