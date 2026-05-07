-------------------------------- MODULE deadlock --------------------------------
(*
  TLA+ specification of the wait-for graph deadlock detection algorithm
  as implemented in BaraDB (core/deadlock.nim).

  Key properties verified:
    - GraphIntegrity : edges are always between known transactions.
    - NoSelfLoops    : no transaction waits on itself.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS TxnIds,        \* set of transaction IDs
          MaxEdges,      \* bound number of edges for model checking
          Nil            \* distinguished nil value (model value)

ASSUME IsFiniteSet(TxnIds)

VARIABLES
  edges           \* set of <<waiter, holder>> pairs

vars == <<edges>>

-----------------------------------------------------------------------------

Init ==
  /\ edges = {}

-----------------------------------------------------------------------------
\* State transitions

AddEdge(waiter, holder) ==
  /\ waiter /= holder
  /\ <<waiter, holder>> \notin edges
  /\ Cardinality(edges) < MaxEdges
  /\ edges' = edges \cup {<<waiter, holder>>}

RemoveEdge(waiter, holder) ==
  /\ <<waiter, holder>> \in edges
  /\ edges' = edges \ {<<waiter, holder>>}

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E w, h \in TxnIds : AddEdge(w, h)
  \/ \E w, h \in TxnIds : RemoveEdge(w, h)

-----------------------------------------------------------------------------
\* Safety properties

\* All edges reference known transactions.
GraphIntegrity ==
  \A e \in edges : e[1] \in TxnIds /\ e[2] \in TxnIds

\* No self-loops.
NoSelfLoops ==
  \A tx \in TxnIds : <<tx, tx>> \notin edges

\* Type invariant
TypeOk ==
  /\ edges \subseteq (TxnIds \X TxnIds)
  /\ Cardinality(edges) <= MaxEdges

=============================================================================
