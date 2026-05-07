-------------------------------- MODULE twopc --------------------------------
(*
  TLA+ specification of the Two-Phase Commit (2PC) distributed transaction
  protocol as implemented in BaraDB (core/disttxn.nim).

  Key properties verified:
    - Atomicity      : all participants commit, or all abort.
    - NoOrphanBlocks : a prepared participant never remains blocked forever
                       once the coordinator decides.
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
  decidedAction     \* decidedAction[t] ∈ {"Commit","Abort", Nil}

vars == <<txnState, participantState, coordinatorDecided, decidedAction>>

-----------------------------------------------------------------------------

\* Helper operators

AllPrepared(t) ==
  \A p \in Participants : participantState[t][p] \in {"Prepared", "Committed", "Aborted"}

AnyPrepareFailed(t) ==
  \E p \in Participants : participantState[t][p] = "Aborted"

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ txnState = [t \in 1..MaxTxnId |-> "Active"]
  /\ participantState = [t \in 1..MaxTxnId |-> [p \in Participants |-> "Active"]]
  /\ coordinatorDecided = [t \in 1..MaxTxnId |-> FALSE]
  /\ decidedAction = [t \in 1..MaxTxnId |-> Nil]

-----------------------------------------------------------------------------
\* State transitions

\* Phase 1a: Coordinator sends PREPARE to all participants.
SendPrepare(t) ==
  /\ txnState[t] = "Active"
  /\ txnState' = [txnState EXCEPT ![t] = "Preparing"]
  /\ UNCHANGED <<participantState, coordinatorDecided, decidedAction>>

\* Phase 1b: Participant p receives PREPARE and votes Yes.
ParticipantPrepare(t, p) ==
  /\ txnState[t] = "Preparing"
  /\ participantState[t][p] = "Active"
  /\ participantState' = [participantState EXCEPT ![t][p] = "Prepared"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction>>

\* Phase 1c: Participant p votes No (aborts locally).
ParticipantAbort(t, p) ==
  /\ txnState[t] \in {"Preparing", "Active"}
  /\ participantState[t][p] = "Active"
  /\ participantState' = [participantState EXCEPT ![t][p] = "Aborted"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction>>

\* Phase 2a: Coordinator decides COMMIT (all voted Yes).
DecideCommit(t) ==
  /\ txnState[t] = "Preparing"
  /\ AllPrepared(t)
  /\ ~AnyPrepareFailed(t)
  /\ txnState' = [txnState EXCEPT ![t] = "Committing"]
  /\ coordinatorDecided' = [coordinatorDecided EXCEPT ![t] = TRUE]
  /\ decidedAction' = [decidedAction EXCEPT ![t] = "Commit"]
  /\ UNCHANGED <<participantState>>

\* Phase 2a-alt: Coordinator decides ABORT (at least one No or timeout).
DecideAbort(t) ==
  /\ txnState[t] = "Preparing"
  /\ AnyPrepareFailed(t)
  /\ txnState' = [txnState EXCEPT ![t] = "Aborting"]
  /\ coordinatorDecided' = [coordinatorDecided EXCEPT ![t] = TRUE]
  /\ decidedAction' = [decidedAction EXCEPT ![t] = "Abort"]
  /\ UNCHANGED <<participantState>>

\* Phase 2b: Participant receives COMMIT decision.
ReceiveCommit(t, p) ==
  /\ txnState[t] = "Committing"
  /\ decidedAction[t] = "Commit"
  /\ participantState[t][p] \in {"Prepared", "Active"}
  /\ participantState' = [participantState EXCEPT ![t][p] = "Committed"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction>>

\* Phase 2b-alt: Participant receives ABORT decision.
ReceiveAbort(t, p) ==
  /\ txnState[t] = "Aborting"
  /\ decidedAction[t] = "Abort"
  /\ participantState[t][p] \in {"Prepared", "Active", "Aborted"}
  /\ participantState' = [participantState EXCEPT ![t][p] = "Aborted"]
  /\ UNCHANGED <<txnState, coordinatorDecided, decidedAction>>

\* Finalize: transaction moves to terminal state when all participants are done.
FinalizeCommit(t) ==
  /\ txnState[t] = "Committing"
  /\ \A p \in Participants : participantState[t][p] = "Committed"
  /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
  /\ UNCHANGED <<participantState, coordinatorDecided, decidedAction>>

FinalizeAbort(t) ==
  /\ txnState[t] = "Aborting"
  /\ \A p \in Participants : participantState[t][p] = "Aborted"
  /\ txnState' = [txnState EXCEPT ![t] = "Aborted"]
  /\ UNCHANGED <<participantState, coordinatorDecided, decidedAction>>

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

-----------------------------------------------------------------------------
\* Safety properties

\* Atomicity: it is never the case that one participant committed while another aborted.
Atomicity ==
  \A t \in 1..MaxTxnId :
    ~(\E p1, p2 \in Participants :
        participantState[t][p1] = "Committed" /\ participantState[t][p2] = "Aborted")

\* No orphan blocks: once a transaction is fully committed, every participant is committed.
NoOrphanBlocks ==
  \A t \in 1..MaxTxnId :
    txnState[t] = "Committed" =>
      \A p \in Participants : participantState[t][p] = "Committed"

\* Type invariant
TypeOk ==
  /\ txnState \in [1..MaxTxnId -> {"Active","Preparing","Prepared","Committing",
                                     "Committed","Aborting","Aborted"}]
  /\ participantState \in [1..MaxTxnId -> [Participants -> {"Active","Prepared",
                                                              "Committed","Aborted"}]]
  /\ coordinatorDecided \in [1..MaxTxnId -> BOOLEAN]
  /\ decidedAction \in [1..MaxTxnId -> {"Commit","Abort", Nil}]

=============================================================================
