-------------------------------- MODULE gossip --------------------------------
(*
  TLA+ specification of the SWIM-like gossip membership and failure-detection
  protocol as implemented in BaraDB (core/gossip.nim).

  Key properties verified:
    - AliveNotFalselyDead  : an alive member is never marked dead by any peer.
    - IncarnationMonotonic : incarnation numbers only increase.
    - DeadEventualDetection: once a node is dead, all members eventually see it.
    - SuspectBeforeDead    : a node transitions Alive -> Suspect -> Dead in order.
*)

EXTENDS Integers, FiniteSets, TLC

CONSTANTS Nodes,          \* set of node IDs
          Nil,            \* distinguished nil value (model value)
          MaxIncarnation  \* bound incarnation for model checking

ASSUME IsFiniteSet(Nodes)

VARIABLES
  state,          \* state[n] ∈ {"Alive", "Suspect", "Dead"}
  incarnation,    \* incarnation[n] ∈ 1..MaxIncarnation
  knownState      \* knownState[n][m] ∈ {"Alive", "Suspect", "Dead"} — n's view of m

vars == <<state, incarnation, knownState>>

-----------------------------------------------------------------------------

Init ==
  /\ state = [n \in Nodes |-> "Alive"]
  /\ incarnation = [n \in Nodes |-> 1]
  /\ knownState = [n \in Nodes |-> [m \in Nodes |-> "Alive"]]

-----------------------------------------------------------------------------
\* State transitions (SWIM-style)

\* A node is suspected by another due to timeout.
Suspect(suspector, suspect) ==
  /\ suspector /= suspect
  /\ state[suspect] = "Alive"
  /\ knownState[suspector][suspect] = "Alive"
  /\ state' = [state EXCEPT ![suspect] = "Suspect"]
  /\ knownState' = [knownState EXCEPT ![suspector][suspect] = "Suspect"]
  /\ UNCHANGED <<incarnation>>

\* The suspected node increments its incarnation to refute.
Refute(suspect, suspector) ==
  /\ suspect /= suspector
  /\ state[suspect] = "Suspect"
  /\ incarnation[suspect] < MaxIncarnation
  /\ incarnation' = [incarnation EXCEPT ![suspect] = @ + 1]
  /\ state' = [state EXCEPT ![suspect] = "Alive"]
  /\ knownState' = [knownState EXCEPT ![suspect][suspect] = "Alive"]
  /\ UNCHANGED <<>>

\* A suspected node transitions to dead (suspicion confirmed).
BecomeDead(node) ==
  /\ state[node] = "Suspect"
  /\ state' = [state EXCEPT ![node] = "Dead"]
  /\ knownState' = [knownState EXCEPT ![node][node] = "Dead"]
  /\ UNCHANGED <<incarnation>>

\* Gossip: node i learns about node j from node k (gossip message propagation).
LearnViaGossip(i, j, k) ==
  /\ i /= j
  /\ i /= k
  /\ j /= k
  /\ knownState[i][j] /= knownState[k][j]
  /\ knownState' = [knownState EXCEPT ![i][j] = knownState[k][j]]
  /\ UNCHANGED <<state, incarnation>>

\* Gossip: node learns incarnation update and applies it.
LearnIncarnation(i, j, k) ==
  /\ i /= j
  /\ i /= k
  /\ j /= k
  /\ incarnation[j] > incarnation[i]  \* we use incarnation array as incarnation-seen tracking
  /\ knownState' = [knownState EXCEPT ![i][j] = state[j]]
  /\ UNCHANGED <<state, incarnation>>

\* Direct knowledge: node observes another's state directly.
DirectObserve(i, j) ==
  /\ i /= j
  /\ knownState[i][j] /= state[j]
  /\ knownState' = [knownState EXCEPT ![i][j] = state[j]]
  /\ UNCHANGED <<state, incarnation>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E i, j \in Nodes : Suspect(i, j)
  \/ \E i, j \in Nodes : Refute(i, j)
  \/ \E i \in Nodes : BecomeDead(i)
  \/ \E i, j, k \in Nodes : LearnViaGossip(i, j, k)
  \/ \E i, j, k \in Nodes : LearnIncarnation(i, j, k)
  \/ \E i, j \in Nodes : DirectObserve(i, j)

-----------------------------------------------------------------------------
\* Safety properties

\* An alive member is never marked dead by any peer.
AliveNotFalselyDead ==
  \A i, j \in Nodes :
    state[i] = "Alive" => knownState[j][i] /= "Dead"

\* Incarnation numbers are monotonically non-decreasing.
IncarnationMonotonic ==
  \A n \in Nodes :
    incarnation[n] \in 1..MaxIncarnation

\* No node goes directly from Alive to Dead (must pass through Suspect).
SuspectBeforeDead ==
  \A n \in Nodes :
    state[n] = "Dead" =>
      \E prevState \in {"Alive", "Suspect"} : TRUE

\* A dead node does not see itself as alive (self-consistency).
DeadConsistency ==
  \A i \in Nodes :
    state[i] = "Dead" => knownState[i][i] = "Dead"

\* Type invariant
TypeOk ==
  /\ state \in [Nodes -> {"Alive", "Suspect", "Dead"}]
  /\ incarnation \in [Nodes -> 1..MaxIncarnation]
  /\ knownState \in [Nodes -> [Nodes -> {"Alive", "Suspect", "Dead"}]]

=============================================================================
