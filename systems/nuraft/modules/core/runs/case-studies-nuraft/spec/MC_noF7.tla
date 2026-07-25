---------------------------- MODULE MC_noF7 ----------------------------
\* Variant MC spec that removes the config entry barrier from BecomeLeader.
\* Used with MC_hunt_F7.cfg to verify that the implicit Raft §5.4.2
\* mitigation is necessary for LeaderCompleteness.
\*
\* The only change: BecomeLeader does NOT append a ConfigEntry.
\* This removes the current-term barrier, so entries from previous terms
\* can be committed purely based on quorum (without term check).
\*
EXTENDS MC

\* Override BecomeLeader to NOT append config entry
\* Compare with base.tla BecomeLeader which appends ConfigEntry at
\* raft_server.cxx:1183-1195
BecomeLeaderNoBarrier(i) ==
    /\ state[i] /= Leader
    /\ IsElectionQuorum(votesGranted[i], i)
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* NO config entry appended! This is the change.
    /\ precommitIndex' = [precommitIndex EXCEPT ![i] = LastLogIndex(i)]
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, smCommitIndex,
                   candidateVars, persistVars, configVars, quorumVars, hbVars,
                   messages, faultVars>>

=============================================================================
