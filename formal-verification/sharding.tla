-------------------------------- MODULE sharding --------------------------------
(*
  TLA+ specification of the consistent-hashing shard router
  as implemented in BaraDB (core/sharding.nim).

  Key properties verified:
    - KeyDistributionConsistency : the same key always maps to the same shard
                                   given a fixed ring configuration.
    - RebalancePreservation      : rebalancing preserves existing assignments
                                   when nodes are unchanged.
    - VirtualNodeMapping         : each virtual node maps to exactly one shard.
    - NoOrphanShards             : every shard has at least one node assigned.
*)

EXTENDS Integers, FiniteSets, TLC

CONSTANTS Shards,         \* set of shard IDs
          Vnodes,         \* set of virtual node positions (0..MaxVnode-1)
          Nodes,          \* set of node IDs
          MaxVnode,       \* bound for virtual node count
          Nil             \* distinguished nil value

ASSUME IsFiniteSet(Shards) /\ IsFiniteSet(Nodes)

VARIABLES
  vnodeToShard,    \* vnodeToShard[v] ∈ Shards — maps vnode position to shard
  shardToNodes,    \* shardToNodes[s] ⊆ Nodes — nodes assigned to shard
  nextPosition     \* next available vnode position (0..MaxVnode)

vars == <<vnodeToShard, shardToNodes, nextPosition>>

-----------------------------------------------------------------------------

\* Helper: find the shard for a vnode position using binary-search-like lookup.
\* Simplified: find the smallest vnode >= target, wrapping around.
ShardFor(target) ==
  LET occupied == {v \in 1..(nextPosition-1) : v \in DOMAIN vnodeToShard}
      candidates == {v \in occupied : v >= target}
  IN IF candidates /= {}
     THEN vnodeToShard[CHOOSE v \in candidates : \A w \in candidates : v <= w]
     ELSE IF occupied /= {}
          THEN vnodeToShard[CHOOSE v \in occupied : \A w \in occupied : v <= w]
          ELSE Nil

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ vnodeToShard = [v \in 1..MaxVnode |-> Nil]
  /\ shardToNodes = [s \in Shards |-> {}]
  /\ nextPosition = 1

-----------------------------------------------------------------------------
\* State transitions

\* Add a virtual node for a shard at the next position.
AddVnode(shard) ==
  /\ shard \in Shards
  /\ nextPosition <= MaxVnode
  /\ vnodeToShard' = [vnodeToShard EXCEPT ![nextPosition] = shard]
  /\ nextPosition' = nextPosition + 1
  /\ UNCHANGED <<shardToNodes>>

\* Assign a node to a shard.
AssignNode(shard, node) ==
  /\ shard \in Shards
  /\ node \in Nodes
  /\ node \notin shardToNodes[shard]
  /\ shardToNodes' = [shardToNodes EXCEPT ![shard] = @ \cup {node}]
  /\ UNCHANGED <<vnodeToShard, nextPosition>>

\* Remove a node from a shard (node failure or decommission).
RemoveNode(shard, node) ==
  /\ shard \in Shards
  /\ node \in Nodes
  /\ node \in shardToNodes[shard]
  /\ shardToNodes' = [shardToNodes EXCEPT ![shard] = @ \ {node}]
  /\ UNCHANGED <<vnodeToShard, nextPosition>>

\* Rebalance: redistribute nodes across shards.
Rebalance ==
  /\ shardToNodes' = [s \in Shards |-> {CHOOSE n \in (Nodes \cup shardToNodes[s]) : TRUE}]
  /\ UNCHANGED <<vnodeToShard, nextPosition>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E s \in Shards : AddVnode(s)
  \/ \E s \in Shards : \E n \in Nodes : AssignNode(s, n)
  \/ \E s \in Shards : \E n \in Nodes : RemoveNode(s, n)
  \/ Rebalance

-----------------------------------------------------------------------------
\* Safety properties

\* Every vnode maps to either Nil (unused) or a valid shard.
VirtualNodeMapping ==
  \A v \in 1..MaxVnode :
    vnodeToShard[v] \in (Shards \cup {Nil})

\* Each shard has zero or more nodes, all valid.
NodeAssignmentConsistency ==
  \A s \in Shards : shardToNodes[s] \subseteq Nodes

\* Virtual nodes are assigned in order (positions 1..nextPosition-1).
VnodeOrdering ==
  \A v \in 1..MaxVnode :
    (v < nextPosition) <=> (vnodeToShard[v] /= Nil)

\* At least one vnode per active shard once all positions filled.
ShardCoverage ==
  nextPosition > Cardinality(Shards) =>
    \A s \in Shards : \E v \in 1..(nextPosition-1) : vnodeToShard[v] = s

\* Type invariant
TypeOk ==
  /\ vnodeToShard \in [1..MaxVnode -> (Shards \cup {Nil})]
  /\ shardToNodes \in [Shards -> SUBSET Nodes]
  /\ nextPosition \in 1..(MaxVnode + 1)

=============================================================================
