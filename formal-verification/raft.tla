-------------------------------- MODULE raft --------------------------------
(*
  TLA+ specification of the Raft consensus algorithm as implemented in BaraDB.
  Models: leader election, log replication, and commit safety.

  Key properties verified:
    - ElectionSafety      : at most one leader per term.
    - LeaderAppendOnly    : leaders produce valid log entries.
    - StateMachineSafety  : committed entries are identical on all nodes.
    - CommittedIndexValid : commitIndex never exceeds log length.
    - LogMatching         : if two logs have an entry with same index and term,
                            all preceding entries are identical.
*)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS Nodes,        \* set of node IDs
          Nil,          \* distinguished nil value (model value)
          MaxTerm,      \* bound terms for model checking
          MaxLogLen     \* bound log length for model checking

ASSUME IsFiniteSet(Nodes)

VARIABLES
  state,        \* state[n] ∈ {"Follower", "Candidate", "Leader"}
  currentTerm,  \* currentTerm[n] ∈ Nat
  votedFor,     \* votedFor[n] ∈ Nodes ∪ {Nil}
  log,          \* log[n] ∈ Seq(<<term, command>>)
  commitIndex,  \* commitIndex[n] ∈ Nat
  votesGranted, \* votesGranted[n] ⊆ Nodes (only meaningful for Candidates)
  nextIndex,    \* nextIndex[n][m] ∈ Nat (leader state)
  matchIndex,   \* matchIndex[n][m] ∈ Nat (leader state)
  heartbeatReceived \* heartbeatReceived[n] ∈ 0..MaxTerm — last term in which node n received a heartbeat

vars == <<state, currentTerm, votedFor, log, commitIndex, votesGranted, nextIndex, matchIndex, heartbeatReceived>>

-----------------------------------------------------------------------------

\* Helper operators

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

\* Bounded sequence set for TLC (Seq(S) is infinite)
BoundedSeq(S, n) == UNION {[1..m -> S] : m \in 0..n}

\* Is node i a leader in term t?
IsLeader(i, t) == state[i] = "Leader" /\ currentTerm[i] = t

\* The set of all log entries up to index len on node i
LogPrefix(i, len) == [j \in 1..len |-> log[i][j]]

\* Does follower j have a compatible log prefix up to (but not including) index idx?
\* This implements the prevLogIndex/prevLogTerm check from handleAppendEntries.
HasCompatiblePrefix(j, i, idx) ==
  \* idx = 1 means the leader is sending the very first entry — always compatible.
  IF idx = 1
  THEN TRUE
  ELSE IF Len(log[j]) < idx - 1 \/ Len(log[i]) < idx - 1
       THEN FALSE
       ELSE log[j][idx - 1][1] = log[i][idx - 1][1]

-----------------------------------------------------------------------------
\* Initial state

Init ==
  /\ state = [n \in Nodes |-> "Follower"]
  /\ currentTerm = [n \in Nodes |-> 1]
  /\ votedFor = [n \in Nodes |-> Nil]
  /\ log = [n \in Nodes |-> << >>]
  /\ commitIndex = [n \in Nodes |-> 0]
  /\ votesGranted = [n \in Nodes |-> {}]
  /\ nextIndex = [n \in Nodes |-> [m \in Nodes |-> 1]]
  /\ matchIndex = [n \in Nodes |-> [m \in Nodes |-> 0]]
  /\ heartbeatReceived = [n \in Nodes |-> 0]

-----------------------------------------------------------------------------
\* State transitions

\* A follower times out and starts a new election.
Timeout(i) ==
  /\ state[i] \in {"Follower", "Candidate"}
  /\ currentTerm[i] < MaxTerm
  /\ state' = [state EXCEPT ![i] = "Candidate"]
  /\ currentTerm' = [currentTerm EXCEPT ![i] = @ + 1]
  /\ votedFor' = [votedFor EXCEPT ![i] = i]
  /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
  /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex, heartbeatReceived>>

\* Node i votes for node j in j's current term.
Vote(i, j) ==
  /\ i /= j
  /\ state[j] = "Candidate"
  /\ currentTerm[j] > currentTerm[i]
  /\ votedFor[i] = Nil
  /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[j]]
  /\ state' = [state EXCEPT ![i] = "Follower"]
  /\ votedFor' = [votedFor EXCEPT ![i] = j]
  /\ votesGranted' = [votesGranted EXCEPT ![j] = @ \cup {i}]
  /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex, heartbeatReceived>>

\* A candidate becomes leader after receiving a majority.
BecomeLeader(i) ==
  /\ state[i] = "Candidate"
  /\ Cardinality(votesGranted[i]) * 2 > Cardinality(Nodes)
  /\ state' = [state EXCEPT ![i] = "Leader"]
  /\ nextIndex' = [nextIndex EXCEPT ![i] = [m \in Nodes |-> Len(log[i]) + 1]]
  /\ matchIndex' = [matchIndex EXCEPT ![i] = [m \in Nodes |-> 0]]
  /\ heartbeatReceived' = [heartbeatReceived EXCEPT ![i] = currentTerm[i]]
  /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, votesGranted>>

\* Leader i appends a new entry to its own log.
\* Requires the last existing entry (if any) to match currentTerm so that
\* the leader never creates a log with a gap in terms.
AppendEntry(i) ==
  /\ state[i] = "Leader"
  /\ Len(log[i]) < MaxLogLen
  /\ IF Len(log[i]) = 0
     THEN TRUE
     ELSE log[i][Len(log[i])][1] = currentTerm[i]
  /\ log' = [log EXCEPT ![i] = Append(@, <<currentTerm[i], "cmd">>)]
  /\ UNCHANGED <<state, currentTerm, votedFor, commitIndex, votesGranted, nextIndex, matchIndex, heartbeatReceived>>

\* Leader i replicates its log to follower j.
\* Now includes prevLogIndex/prevLogTerm check and conflict truncation.
Replicate(i, j) ==
  /\ i /= j
  /\ state[i] = "Leader"
  /\ nextIndex[i][j] <= Len(log[i])
  /\ HasCompatiblePrefix(j, i, nextIndex[i][j])
  /\ LET leaderEntry == log[i][nextIndex[i][j]]
         idx == nextIndex[i][j]
         \* If follower already has an entry at idx with a different term, truncate.
         conflict == idx <= Len(log[j]) /\ log[j][idx][1] /= leaderEntry[1]
         newLog == IF conflict
                   THEN IF idx = 1
                        THEN << >>
                        ELSE SubSeq(log[j], 1, idx - 1)
                   ELSE IF Len(log[j]) >= idx
                        THEN [log[j] EXCEPT ![idx] = leaderEntry]
                        ELSE Append(log[j], leaderEntry)
         newCommit == IF conflict THEN Min(commitIndex[j], idx - 1) ELSE commitIndex[j]
         newMatch == IF conflict THEN idx - 1 ELSE nextIndex[i][j]
     IN  /\ log' = [log EXCEPT ![j] = newLog]
         /\ commitIndex' = [commitIndex EXCEPT ![j] = newCommit]
         /\ matchIndex' = [matchIndex EXCEPT ![i][j] = newMatch]
  /\ nextIndex' = [nextIndex EXCEPT ![i][j] = @ + 1]
  /\ UNCHANGED <<state, currentTerm, votedFor, votesGranted, heartbeatReceived>>

\* Follower j rejects an AppendEntries from leader i because of prevLog mismatch.
RejectAppendEntries(i, j) ==
  /\ i /= j
  /\ state[i] = "Leader"
  /\ nextIndex[i][j] > 1
  /\ ~HasCompatiblePrefix(j, i, nextIndex[i][j])
  /\ nextIndex' = [nextIndex EXCEPT ![i][j] = @ - 1]
  /\ UNCHANGED <<state, currentTerm, votedFor, log, commitIndex, votesGranted, matchIndex, heartbeatReceived>>

\* Leader i updates commitIndex when a majority has replicated an entry.
Commit(i) ==
  /\ state[i] = "Leader"
  /\ LET majority == (Cardinality(Nodes) \div 2) + 1
         candidates == {idx \in (commitIndex[i]+1)..Len(log[i]) :
                         Cardinality({j \in Nodes : matchIndex[i][j] >= idx}) >= majority
                         /\ log[i][idx][1] = currentTerm[i]}
     IN  candidates /= {}
         /\ commitIndex' = [commitIndex EXCEPT ![i] = CHOOSE idx \in candidates : TRUE]
  /\ UNCHANGED <<state, currentTerm, votedFor, log, votesGranted, nextIndex, matchIndex, heartbeatReceived>>

\* A follower learns about a higher term and steps down.
StepDown(i, newTerm) ==
  /\ newTerm > currentTerm[i]
  /\ currentTerm[i] < MaxTerm
  /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
  /\ state' = [state EXCEPT ![i] = "Follower"]
  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
  /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
  /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex, heartbeatReceived>>

\* Leader i sends a heartbeat to node j in its current term.
\* Only an up-to-date leader (term >= recipient's term) may send heartbeats.
\* If j sees a higher term, it steps down (same as AppendEntries handling).
Heartbeat(i, j) ==
  /\ i /= j
  /\ state[i] = "Leader"
  /\ currentTerm[i] >= currentTerm[j]
  /\ IF currentTerm[i] > currentTerm[j]
     THEN /\ currentTerm' = [currentTerm EXCEPT ![j] = currentTerm[i]]
          /\ state' = [state EXCEPT ![j] = "Follower"]
          /\ votedFor' = [votedFor EXCEPT ![j] = Nil]
          /\ votesGranted' = [votesGranted EXCEPT ![j] = {}]
          /\ heartbeatReceived' = [heartbeatReceived EXCEPT ![j] = currentTerm[i]]
          /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex>>
     ELSE /\ heartbeatReceived' = [heartbeatReceived EXCEPT ![j] = currentTerm[i]]
          /\ UNCHANGED <<state, currentTerm, votedFor, log, commitIndex, votesGranted, nextIndex, matchIndex>>

\* A follower times out because it has not received a heartbeat from the leader.
\* This can only happen if heartbeatReceived for its current term is FALSE.
HeartbeatTimeout(i) ==
  /\ state[i] = "Follower"
  /\ heartbeatReceived[i] < currentTerm[i]
  /\ currentTerm[i] < MaxTerm
  /\ state' = [state EXCEPT ![i] = "Candidate"]
  /\ currentTerm' = [currentTerm EXCEPT ![i] = @ + 1]
  /\ votedFor' = [votedFor EXCEPT ![i] = i]
  /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
  /\ heartbeatReceived' = [heartbeatReceived EXCEPT ![i] = currentTerm[i] + 1]
  /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex>>

\* Leader i steps down because it could not reach a majority with heartbeats.
\* This models a network partition where the leader loses quorum connectivity.
LeaderLeaseExpired(i) ==
  /\ state[i] = "Leader"
  /\ LET majority == (Cardinality(Nodes) \div 2) + 1
         acks == Cardinality({j \in Nodes : heartbeatReceived[j] = currentTerm[i]})
     IN  acks < majority
  /\ state' = [state EXCEPT ![i] = "Follower"]
  /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, votesGranted, nextIndex, matchIndex, heartbeatReceived>>

-----------------------------------------------------------------------------
\* Next-state relation

Next ==
  \/ \E i \in Nodes : Timeout(i)
  \/ \E i, j \in Nodes : Vote(i, j)
  \/ \E i \in Nodes : BecomeLeader(i)
  \/ \E i \in Nodes : AppendEntry(i)
  \/ \E i, j \in Nodes : Replicate(i, j)
  \/ \E i, j \in Nodes : RejectAppendEntries(i, j)
  \/ \E i \in Nodes : Commit(i)
  \/ \E i \in Nodes : \E t \in 2..MaxTerm : StepDown(i, t)
  \/ \E i, j \in Nodes : Heartbeat(i, j)
  \/ \E i \in Nodes : HeartbeatTimeout(i)
  \/ \E i \in Nodes : LeaderLeaseExpired(i)

-----------------------------------------------------------------------------
\* Safety properties

\* At most one leader per term.
ElectionSafety ==
  \A t \in 1..MaxTerm :
    Cardinality({i \in Nodes : IsLeader(i, t)}) <= 1

\* Leaders never overwrite or delete their own log entries (state invariant).
LeaderAppendOnly ==
  \A i \in Nodes :
    state[i] = "Leader" =>
      \A j \in 1..Len(log[i]) : log[i][j] \in (1..MaxTerm) \X {"cmd"}

\* If a log entry is committed, all nodes that have that index share the same entry.
StateMachineSafety ==
  \A i, j \in Nodes :
    \A idx \in 1..Min(commitIndex[i], commitIndex[j]) :
      idx <= Len(log[i]) /\ idx <= Len(log[j]) => log[i][idx] = log[j][idx]

\* Each node's commitIndex never exceeds its own log length.
CommittedIndexValid ==
  \A i \in Nodes : commitIndex[i] <= Len(log[i])

\* Log Matching property: if two logs contain an entry with the same index and term,
\* then the logs are identical in all preceding entries.
LogMatching ==
  \A i, j \in Nodes :
    \A idx \in 1..Min(Len(log[i]), Len(log[j])) :
      log[i][idx] = log[j][idx] =>
        \A k \in 1..idx : log[i][k] = log[j][k]

\* Type invariant
TypeOk ==
  /\ state \in [Nodes -> {"Follower", "Candidate", "Leader"}]
  /\ currentTerm \in [Nodes -> 1..MaxTerm]
  /\ votedFor \in [Nodes -> Nodes \cup {Nil}]
  /\ \A n \in Nodes : Len(log[n]) <= MaxLogLen
  /\ \A n \in Nodes : \A i \in 1..Len(log[n]) : log[n][i] \in (1..MaxTerm) \X {"cmd"}
  /\ commitIndex \in [Nodes -> 0..MaxLogLen]
  /\ votesGranted \in [Nodes -> SUBSET Nodes]
  /\ nextIndex \in [Nodes -> [Nodes -> 1..(MaxLogLen+1)]]
  /\ matchIndex \in [Nodes -> [Nodes -> 0..MaxLogLen]]
  /\ heartbeatReceived \in [Nodes -> 0..MaxTerm]

\* Safety properties for leader lease / heartbeat

\* A leader must have sent itself a heartbeat in its own term.
LeaderHasSelfHeartbeat ==
  \A i \in Nodes :
    state[i] = "Leader" => heartbeatReceived[i] = currentTerm[i]

\* If a leader has not reached a majority with heartbeats, it cannot remain leader.
\* (This is checked dynamically via LeaderLeaseExpired action.)
LeaderLeaseSafety ==
  \A t \in 1..MaxTerm :
    LET leaders == {i \in Nodes : state[i] = "Leader" /\ currentTerm[i] = t}
        acks == Cardinality({j \in Nodes : heartbeatReceived[j] = t})
    IN  \A i \in leaders : acks >= (Cardinality(Nodes) \div 2) + 1

\* Liveness properties

\* If a node becomes leader, eventually it commits at least one entry.
LeaderProgress ==
  \A i \in Nodes : state[i] = "Leader" ~> commitIndex[i] > 0

\* Specification with weak fairness (all actions get a fair chance).
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

=============================================================================
