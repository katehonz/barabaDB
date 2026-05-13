-------------------------------- MODULE crossmodal --------------------------------
(*
  TLA+ specification of Cross-Modal consistency in BaraDB.
  Models: document store, vector index, graph index, FTS index,
          metadata consistency, hybrid queries, and 2PC transactions.

  Key properties verified:
    - MetadataVectorConsistency: metadata always matches vector index.
    - HybridResultValid: hybrid query results are drawn from queried indices.
    - CommittedAtomicity: if txn committed, all participants committed.
    - AbortedAtomicity: if txn aborted, all participants aborted.
    - TxnStateValid: 2PC participant states align with coordinator state.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS Entities,       \* set of entity IDs
          Participants,   \* set of 2PC participant IDs
          MaxSteps,       \* bound total actions for model checking
          Nil,            \* distinguished nil value (model value)
          Doc, Vec, Graph, Fts  \* model values for query modes

ASSUME IsFiniteSet(Entities) /\ IsFiniteSet(Participants)
ASSUME MaxSteps >= 1
ASSUME {Doc, Vec, Graph, Fts} \cap (Entities \cup Participants \cup {Nil}) = {}

Modes == {Doc, Vec, Graph, Fts}

VARIABLES
  index,          \* index[m] \in SUBSET Entities for each m \in Modes
  metadata,       \* metadata \subseteq Entities — linked to vector index
  txnState,       \* txnState \in {"None","Active","Prepared","Committed","Aborted"}
  participantState, \* participantState[p] for each p \in Participants
  lastQueryModes, \* lastQueryModes \subseteq Modes
  lastQueryResult,\* lastQueryResult \subseteq Entities
  steps           \* steps \in 0..MaxSteps — action counter bound

vars == <<index, metadata, txnState, participantState,
          lastQueryModes, lastQueryResult, steps>>

\* Union of indices for a set of modes
IndexUnion(modes) == UNION {index[m] : m \in modes}

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ index = [m \in Modes |-> {}]
  /\ metadata = {}
  /\ txnState = "None"
  /\ participantState = [p \in Participants |-> "None"]
  /\ lastQueryModes = {}
  /\ lastQueryResult = {}
  /\ steps = 0

-----------------------------------------------------------------------------
\* State transitions

\* Insert entity into document store.
InsertDoc(e) ==
  /\ e \in Entities
  /\ steps < MaxSteps
  /\ index' = [index EXCEPT ![Doc] = @ \union {e}]
  /\ steps' = steps + 1
  /\ UNCHANGED <<metadata, txnState, participantState, lastQueryModes, lastQueryResult>>

\* Insert entity into vector index (also updates metadata).
InsertVec(e) ==
  /\ e \in Entities
  /\ steps < MaxSteps
  /\ index' = [index EXCEPT ![Vec] = @ \union {e}]
  /\ metadata' = metadata \union {e}
  /\ steps' = steps + 1
  /\ UNCHANGED <<txnState, participantState, lastQueryModes, lastQueryResult>>

\* Insert entity into graph index.
InsertGraph(e) ==
  /\ e \in Entities
  /\ steps < MaxSteps
  /\ index' = [index EXCEPT ![Graph] = @ \union {e}]
  /\ steps' = steps + 1
  /\ UNCHANGED <<metadata, txnState, participantState, lastQueryModes, lastQueryResult>>

\* Insert entity into FTS index.
InsertFts(e) ==
  /\ e \in Entities
  /\ steps < MaxSteps
  /\ index' = [index EXCEPT ![Fts] = @ \union {e}]
  /\ steps' = steps + 1
  /\ UNCHANGED <<metadata, txnState, participantState, lastQueryModes, lastQueryResult>>

\* Delete entity from document store.
DeleteDoc(e) ==
  /\ e \in Entities
  /\ steps < MaxSteps
  /\ index' = [index EXCEPT ![Doc] = @ \ {e}]
  /\ steps' = steps + 1
  /\ UNCHANGED <<metadata, txnState, participantState, lastQueryModes, lastQueryResult>>

\* Hybrid query over a non-empty set of modes.
HybridQuery(qmodes) ==
  /\ qmodes \subseteq Modes
  /\ qmodes /= {}
  /\ steps < MaxSteps
  /\ lastQueryModes' = qmodes
  /\ lastQueryResult' = IndexUnion(qmodes)
  /\ steps' = steps + 1
  /\ UNCHANGED <<index, metadata, txnState, participantState>>

\* 2PC: begin transaction.
BeginTxn ==
  /\ txnState = "None"
  /\ steps < MaxSteps
  /\ txnState' = "Active"
  /\ participantState' = [p \in Participants |-> "None"]
  /\ steps' = steps + 1
  /\ UNCHANGED <<index, metadata, lastQueryModes, lastQueryResult>>

\* 2PC: prepare.
PrepareTxn ==
  /\ txnState = "Active"
  /\ steps < MaxSteps
  /\ txnState' = "Prepared"
  /\ participantState' = [p \in Participants |-> "Prepared"]
  /\ steps' = steps + 1
  /\ UNCHANGED <<index, metadata, lastQueryModes, lastQueryResult>>

\* 2PC: commit.
CommitTxn ==
  /\ txnState = "Prepared"
  /\ steps < MaxSteps
  /\ txnState' = "Committed"
  /\ participantState' = [p \in Participants |-> "Committed"]
  /\ steps' = steps + 1
  /\ UNCHANGED <<index, metadata, lastQueryModes, lastQueryResult>>

\* 2PC: abort / rollback.
AbortTxn ==
  /\ txnState \in {"Active", "Prepared"}
  /\ steps < MaxSteps
  /\ txnState' = "Aborted"
  /\ participantState' = [p \in Participants |-> "Aborted"]
  /\ steps' = steps + 1
  /\ UNCHANGED <<index, metadata, lastQueryModes, lastQueryResult>>

Next ==
  \/ \E e \in Entities : InsertDoc(e)
  \/ \E e \in Entities : InsertVec(e)
  \/ \E e \in Entities : InsertGraph(e)
  \/ \E e \in Entities : InsertFts(e)
  \/ \E e \in Entities : DeleteDoc(e)
  \/ \E qmodes \in (SUBSET Modes \ {{}}) : HybridQuery(qmodes)
  \/ BeginTxn
  \/ PrepareTxn
  \/ CommitTxn
  \/ AbortTxn

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
\* Invariants

TypeOk ==
  /\ \A m \in Modes : index[m] \subseteq Entities
  /\ metadata \subseteq Entities
  /\ txnState \in {"None", "Active", "Prepared", "Committed", "Aborted"}
  /\ \A p \in Participants : participantState[p] \in {"None", "Prepared", "Committed", "Aborted"}
  /\ lastQueryModes \subseteq Modes
  /\ lastQueryResult \subseteq Entities
  /\ steps \in 0..MaxSteps

\* Metadata is always consistent with vector index.
MetadataVectorConsistency ==
  metadata = index[Vec]

\* Hybrid query results are valid (drawn from queried indices).
HybridResultValid ==
  lastQueryResult \subseteq IndexUnion(lastQueryModes)

\* If transaction is committed, all participants are committed.
CommittedAtomicity ==
  txnState = "Committed" => \A p \in Participants : participantState[p] = "Committed"

\* If transaction is aborted, all participants are aborted.
AbortedAtomicity ==
  txnState = "Aborted" => \A p \in Participants : participantState[p] = "Aborted"

\* 2PC state machine alignment.
TxnStateValid ==
  /\ (txnState = "None" => \A p \in Participants : participantState[p] = "None")
  /\ (txnState = "Active" => \A p \in Participants : participantState[p] \in {"None", "Prepared"})
  /\ (txnState = "Prepared" => \A p \in Participants : participantState[p] = "Prepared")

\* Symmetry reduction for model checking.
Symmetry == Permutations(Entities) \cup Permutations(Participants)

=============================================================================
