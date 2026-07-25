--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for MongoDB MongoRaftReconfig — the committed (non-force)
 * logless dynamic reconfiguration path.
 *
 * Derived from: mongodb/mongo db/repl/
 *   - replication_coordinator_impl.cpp        (reconfig orchestration, install, commit point)
 *   - replication_coordinator_impl_heartbeat.cpp (heartbeat-driven config propagation)
 *   - topology_coordinator.cpp                (quorum/commit/vote/term math)
 *   - repl_set_config.{h,cpp} / repl_set_config_checks.cpp ((version,term) order, quorums, validation)
 *
 * This spec models the IMPLEMENTATION's control flow, not the MongoRaftReconfig
 * paper algorithm. The reference protocol has a TLAPS machine-checked proof, so
 * real bugs live in the implementation's deviations from / extensions beyond it:
 *
 *   Bug Family 1: election-term `_term` and config-`configTerm` are DECOUPLED.
 *     The heartbeat install path installs a config whose configTerm exceeds the
 *     node's _term without bumping _term, and lacks the command path's term guard.
 *   Bug Family 2: commit-point / oplog-commitment (Q2) bookkeeping across the
 *     de-atomized install window (Q1/Q2 checked, mutex dropped, config installed
 *     later, commit point recomputed under the NEW config before prev snapshot).
 *   Bug Family 3: arbiter / PSA dual-quorum (config quorum incl. arbiters vs
 *     data quorum excl. arbiters) + single-voting-member-change overlap fidelity.
 *
 * Out of scope (already investigated, see modeling-brief §3.2): force reconfig
 * (configTerm=-1 comparator bypass), newlyAdded quorum reduction, prepared-txn
 * lock yielding, initial sync, storage engine, sharding.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server            \* Set of all server IDs (universe of nodes that may appear in a config)
CONSTANT MaxTerm           \* Bound on election term
CONSTANT MaxLogLen         \* Bound on oplog length
CONSTANT MaxConfigVersion  \* Bound on config version

\* --- Role (topology_coordinator Role) ---
Primary    == "Primary"      \* Role::kLeader
Secondary  == "Secondary"    \* Role::kFollower

\* --- Primary sub-state (topology_coordinator LeaderMode) ---
NotPrimary      == "NotPrimary"      \* kNotLeader (node is Secondary)
LeaderElect     == "LeaderElect"     \* kLeaderElect: won election, draining (commit frozen)
WritablePrimary == "WritablePrimary" \* kWritablePrimary: drain complete, can accept writes
SteppingDown    == "SteppingDown"    \* kSteppingDown: learned higher term, async stepdown pending

\* --- De-atomized command reconfig phase (_rsConfigState progression) ---
PhaseIdle      == "idle"       \* kConfigSteady
PhaseChecked   == "checked"    \* Q1/Q2 checked, mutex dropped (impl.cpp:3636 lk.unlock)
PhasePersisted == "persisted"  \* persisted + journal-flushed (impl.cpp:3878), about to install

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-node election/role state (serverVars) ---
VARIABLE term          \* [Server -> Nat]  election term `_term` (topology_coordinator._term)
VARIABLE role          \* [Server -> {Primary, Secondary}]  topology Role
VARIABLE primaryState  \* [Server -> {NotPrimary, LeaderElect, WritablePrimary, SteppingDown}]
VARIABLE lastVoteTerm  \* [Server -> Nat]  `_lastVote.term` (one vote per term, topology_coordinator:3768/3790)

\* --- Per-node installed config (configVars) ---
\* config[n] is a record [version, term, voters, arbiters]:
\*   voters   : SUBSET Server  (isVoter() members; includes arbiters — votes:1, !newlyAdded)
\*   arbiters : SUBSET voters  (isArbiter() members; non-data-bearing voters)
VARIABLE config        \* [Server -> ConfigRec]  installed ReplSetConfig (version,term,members)

\* --- Per-node oplog / commit-point state (logVars) ---
VARIABLE log           \* [Server -> Seq(Nat)]  oplog; entry value = term it was created in
VARIABLE commitPoint   \* [Server -> OpTime]  `_lastCommittedOpTimeAndWallTime.opTime`
VARIABLE committedInPrev \* [Server -> OpTime] `_lastCommittedInPrevConfig` (Q2 snapshot)
VARIABLE firstOpTime   \* [Server -> OpTime]  `_firstOpTimeOfMyTerm` (∞ during drain freeze)

\* --- Per-node de-atomized reconfig bookkeeping (reconfigVars) ---
VARIABLE reconfigPhase \* [Server -> {PhaseIdle, PhaseChecked, PhasePersisted}]
VARIABLE pendingCfg    \* [Server -> ConfigRec]  config being installed across the lock-drop window

\* --- Per-node pending step-down (Family 1b: kTriggerStepDown async) (stepdownVars) ---
VARIABLE pendingStepDown \* [Server -> BOOLEAN]  `_pendingTermUpdateDuringStepDown` / leaderMode==kSteppingDown
VARIABLE pendingTerm     \* [Server -> Nat]  the higher term learned, applied at CompleteStepDown

\* Heartbeat config propagation needs no message buffer: a heartbeat carries the
\* responder's CURRENT config (topology_coordinator.cpp:1178), and the install gate
\* requires strictly-greater (v,t) (1179), so a stale in-flight config would be
\* rejected anyway. InstallConfigViaHeartbeat therefore reads config[q] directly.

\* --- History / auxiliary (for safety invariants) (histVars) ---
VARIABLE committed         \* SUBSET OpTime  every entry ever majority-committed (for LeaderCompleteness)
VARIABLE leaderHistory     \* [1..MaxTerm -> SUBSET Server]  who became leader in each term (ElectionSafety)
VARIABLE installedConfigs  \* SUBSET ConfigRec  every config ever installed anywhere (ConfigTotalOrder)
VARIABLE reconfigPairs     \* SUBSET [old: ConfigRec, new: ConfigRec]  (ConfigQuorumOverlap)

serverVars   == <<term, role, primaryState, lastVoteTerm>>
configVars   == <<config>>
logVars      == <<log, commitPoint, committedInPrev, firstOpTime>>
reconfigVars == <<reconfigPhase, pendingCfg>>
stepdownVars == <<pendingStepDown, pendingTerm>>
histVars     == <<committed, leaderHistory, installedConfigs, reconfigPairs>>

vars == <<serverVars, configVars, logVars, reconfigVars, stepdownVars,
          histVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

\* --- OpTime = [index, term] (models OpTime = (timestamp, term)) ---
OpTimeRec(i, t) == [index |-> i, term |-> t]
ZeroOpTime      == OpTimeRec(0, 0)
\* Sentinel "infinity" optime used for the drain freeze (topology_coordinator:2935).
InfOpTime       == OpTimeRec(MaxLogLen + 5, MaxTerm + 5)

\* OpTime order: timestamp(index)-major, then term (OpTime::operator<).
OpTimeLEQ(a, b) ==
    \/ a.index < b.index
    \/ (a.index = b.index /\ a.term <= b.term)
OpTimeMax(a, b) == IF OpTimeLEQ(a, b) THEN b ELSE a

\* --- Oplog helpers (MongoStaticRaft style) ---
LastTerm(lg) == IF Len(lg) = 0 THEN 0 ELSE lg[Len(lg)]
LastOpTime(n) == OpTimeRec(Len(log[n]), LastTerm(log[n]))

\* An OpTime is "in node n's log" iff n has an entry at that index with that term
\* (or it is the zero optime). Log-matching makes this a prefix containment check.
OpTimeInLog(opt, n) ==
    \/ opt.index = 0
    \/ (opt.index > 0 /\ Len(log[n]) >= opt.index /\ log[n][opt.index] = opt.term)

\* Candidate i's log is at least as up-to-date as voter v's (topology_coordinator:3761).
LogNewerOrEqual(a, b) ==
    \/ LastTerm(a) > LastTerm(b)
    \/ (LastTerm(a) = LastTerm(b) /\ Len(a) >= Len(b))

\* --- Config (version,term) order: term-major (ConfigVersionAndTerm, repl_set_config.h:91-100).
\* The force-only term=-1 special case is deliberately NOT modeled (out of scope).
CVTGeq(c1, c2) ==
    \/ c1.term > c2.term
    \/ (c1.term = c2.term /\ c1.version >= c2.version)
CVTGreater(c1, c2) ==
    \/ c1.term > c2.term
    \/ (c1.term = c2.term /\ c1.version > c2.version)
CVTEqual(c1, c2) == c1.term = c2.term /\ c1.version = c2.version

\* --- Quorum helpers (repl_set_config.cpp:631-640, _calculateMajorities) ---
\* voters            = isVoter() members (includes arbiters)
\* writableVoters    = voters \ arbiters  (isVoter() && !isArbiter())
\* majorityVoteCount = |voters| \div 2 + 1            ($configMajority / election quorum)
\* writeMajority     = min(majorityVoteCount, |writableVoters|)   ($majority / data quorum)
WritableVoters(cfg) == cfg.voters \ cfg.arbiters
MajorityVoteCount(cfg) == (Cardinality(cfg.voters) \div 2) + 1
WriteMajority(cfg) ==
    Min(MajorityVoteCount(cfg), Cardinality(WritableVoters(cfg)))

\* Config / election quorum: a majority of ALL voters (arbiters included).
IsConfigQuorum(S, cfg) ==
    /\ S \subseteq cfg.voters
    /\ 2 * Cardinality(S) > Cardinality(cfg.voters)
\* Data / oplog quorum: at least WriteMajority of the WRITABLE (non-arbiter) voters.
IsDataQuorum(S, cfg) ==
    /\ S \subseteq WritableVoters(cfg)
    /\ Cardinality(S) >= WriteMajority(cfg)

\* Q1 — Config Replication (impl.cpp:3593-3600 + makeConfigPredicate topology_coordinator:1425-1429):
\* a $configMajority of cfg's voters have INSTALLED exactly this (version,term).
ConfigIsCommitted(cfg) ==
    \E S \in SUBSET cfg.voters :
        /\ IsConfigQuorum(S, cfg)
        /\ \A s \in S : config[s].version = cfg.version /\ config[s].term = cfg.term

\* Q2 helper — an OpTime is committed under cfg iff a data-quorum holds it in their oplog
\* (impl.cpp:3610-3623, _doneWaitingForReplication with $majority oplog write concern).
OpTimeCommittedUnder(opt, cfg) ==
    \/ opt.index = 0
    \/ \E S \in SUBSET WritableVoters(cfg) :
         /\ IsDataQuorum(S, cfg)
         /\ \A s \in S : OpTimeInLog(opt, s)

\* getConfigOplogCommitmentOpTime (topology_coordinator:1705-1710):
\*   max(_lastCommittedInPrevConfig, _firstOpTimeOfMyTerm)
ConfigOplogCommitmentOpTime(n) == OpTimeMax(committedInPrev[n], firstOpTime[n])

\* Q1/Q2 as evaluated by a PRIMARY p running a reconfig. Same as the predicates
\* above but each acknowledging member must be reachable in p's own election term
\* (term[s] <= term[p]). This is the faithful abstraction of the heartbeat term-
\* propagation + stepdown coupling: a member with a strictly higher election term
\* would, via its heartbeat/position report, have driven updateTerm on p
\* (topology_coordinator:3305-3306 kTriggerStepDown) and stepped p down BEFORE its
\* acknowledgment could be counted. Without this, a stale primary in an old term
\* could keep reconfiguring using nodes that have already moved to a newer term.
ConfigCommittedByPrimary(p) ==
    \E S \in SUBSET config[p].voters :
        /\ IsConfigQuorum(S, config[p])
        /\ \A s \in S : /\ config[s].version = config[p].version
                        /\ config[s].term = config[p].term
                        /\ term[s] <= term[p]

OpTimeCommittedByPrimary(p, opt) ==
    \/ opt.index = 0
    \/ \E S \in SUBSET WritableVoters(config[p]) :
         /\ IsDataQuorum(S, config[p])
         /\ \A s \in S : OpTimeInLog(opt, s) /\ term[s] <= term[p]

\* canAcceptNonLocalWrites: writable primary. True for WritablePrimary and (per
\* analysis-report §3 Family 1b) STILL TRUE during the async SteppingDown window —
\* it drops only when the async stepdown acquires RSTL-X. False while draining
\* (LeaderElect) and while Secondary.
CanAcceptNonLocalWrites(n) ==
    /\ role[n] = Primary
    /\ primaryState[n] \in {WritablePrimary, SteppingDown}

\* canAdvanceCommit: commit point may move only for a writable primary that is not
\* stepping down (topology_coordinator:3136 `_leaderMode != kSteppingDown`) and not
\* draining (3193 `_firstOpTimeOfMyTerm` is ∞ until completeTransitionToPrimary).
CanAdvanceCommit(n) ==
    /\ role[n] = Primary
    /\ primaryState[n] = WritablePrimary

\* A node is electable (writable voter) in a config (checkElectable / isElectable,
\* member_config.h:270 — !isArbiter() && priority>0; priority modeled as: a writable voter).
ElectableIn(n, cfg) == n \in WritableVoters(cfg)

\* Empty / sentinel config for pendingCfg when idle.
NoCfg == [version |-> 0, term |-> 0, voters |-> {}, arbiters |-> {}]

\* ============================================================================
\* ACTIONS — Oplog protocol (MongoStaticRaft layer)
\* ============================================================================

\* --------------------------------------------------------------------------
\* ClientRequest: a writable primary appends a new oplog entry in its own term.
\* Reference: oplog write under primary; entry term = node's election term.
\* --------------------------------------------------------------------------
ClientRequest(p) ==
    /\ CanAdvanceCommit(p)                 \* writable primary only (canAcceptNonLocalWrites)
    /\ Len(log[p]) < MaxLogLen
    /\ log' = [log EXCEPT ![p] = Append(@, term[p])]
    /\ UNCHANGED <<serverVars, configVars, commitPoint, committedInPrev,
                   firstOpTime, reconfigVars, stepdownVars, netVars, histVars>>

\* --------------------------------------------------------------------------
\* GetEntries: secondary s replicates the next oplog entry from a source q.
\* Reference: oplog fetch; log-matching guarantees prefix consistency at s's tail.
\* --------------------------------------------------------------------------
GetEntries(s, q) ==
    /\ s /= q
    /\ role[s] = Secondary                 \* primaries do not pull entries
    /\ Len(log[q]) > Len(log[s])
    \* Prefix must match at s's current tail (log matching property).
    \* (Each disjunct self-guards: TLC branches \/ in the next-state relation.)
    /\ \/ Len(log[s]) = 0
       \/ /\ Len(log[s]) > 0
          /\ log[q][Len(log[s])] = log[s][Len(log[s])]
    /\ log' = [log EXCEPT ![s] = Append(@, log[q][Len(log[s]) + 1])]
    /\ UNCHANGED <<serverVars, configVars, commitPoint, committedInPrev,
                   firstOpTime, reconfigVars, stepdownVars, netVars, histVars>>

\* --------------------------------------------------------------------------
\* RollbackEntries: secondary s discards a divergent tail entry that conflicts
\* with a more-up-to-date node q (CanRollbackOplog).
\* Reference: rollback after election divergence.
\* --------------------------------------------------------------------------
CanRollback(s, q) ==
    /\ Len(log[s]) > 0
    /\ LastTerm(log[q]) > LastTerm(log[s])
    /\ \/ Len(log[s]) > Len(log[q])
       \/ (Len(log[s]) <= Len(log[q]) /\ LastTerm(log[s]) /= log[q][Len(log[s])])

RollbackEntries(s, q) ==
    /\ s /= q
    /\ role[s] = Secondary
    /\ CanRollback(s, q)
    /\ log' = [log EXCEPT ![s] = SubSeq(@, 1, Len(@) - 1)]
    /\ UNCHANGED <<serverVars, configVars, commitPoint, committedInPrev,
                   firstOpTime, reconfigVars, stepdownVars, netVars, histVars>>

\* --------------------------------------------------------------------------
\* AdvanceCommitPoint: a writable primary advances its commit point to an index
\* replicated to a DATA quorum of its current config, in its own term.
\* Reference: topology_coordinator.cpp:3131-3172 (updateLastCommittedOpTimeAndWallTime)
\*   3136: frozen if !_iAmPrimary() || _leaderMode == kSteppingDown  (CanAdvanceCommit)
\*   3148: only isVoter() members counted; 3159: needs >= getWriteMajority()
\*   3193: committedOpTime >= _firstOpTimeOfMyTerm  (drain freeze)
\*   3204: commit only entries of my own term (committedOpTime.term == lastWritten.term)
\* Committing index i commits the whole prefix 1..i (Raft commit rule).
\* --------------------------------------------------------------------------
AdvanceCommitPoint(p) ==
    /\ CanAdvanceCommit(p)                  \* 3136 freeze: WritablePrimary only
    /\ \E i \in 1..Len(log[p]) :
        /\ log[p][i] = term[p]              \* 3204: commit an entry of my own term
        /\ i > commitPoint[p].index         \* monotonic advance (3219/3223)
        /\ OpTimeLEQ(firstOpTime[p], OpTimeRec(i, term[p]))   \* 3193 drain freeze
        \* A data-quorum (writable voters of current config) has replicated up to i
        \* AND each member is in the primary's election term. The term-match is the
        \* proven oplog-commit rule (MongoStaticRaft CommitEntry): a node only counts
        \* toward commitment in the leader's term — in the implementation a member's
        \* reported position carries its term, so a higher-term member would force the
        \* primary to step down (updateTerm) before its ack could be counted.
        /\ \E S \in SUBSET WritableVoters(config[p]) :
             /\ IsDataQuorum(S, config[p])
             /\ \A s \in S : /\ Len(log[s]) >= i
                             /\ log[s][i] = term[p]
                             /\ term[s] = term[p]
        /\ commitPoint' = [commitPoint EXCEPT ![p] = OpTimeRec(i, term[p])]
        \* Record every NEWLY-committed prefix entry, tagged with the COMMIT term
        \* (this leader's term[p]). An index already in `committed` keeps its original
        \* commit term, so each entry's `cterm` is the term in which it FIRST reached a
        \* quorum (always >= the entry's own term, since the committed index i carries
        \* term[p]). LeaderCompleteness is relative to this commit term — a leader of a
        \* term BELOW an entry's commit term was elected before the entry was committed
        \* and may legitimately lack it (a benign stale leader; it cannot un-commit it).
        /\ committed' = committed \cup
               { [index |-> k, term |-> log[p][k], cterm |-> term[p]] :
                   k \in { j \in (commitPoint[p].index + 1)..i :
                              ~ \E c \in committed : c.index = j /\ c.term = log[p][j] } }
    /\ UNCHANGED <<serverVars, configVars, log, committedInPrev, firstOpTime,
                   reconfigVars, stepdownVars, netVars,
                   leaderHistory, installedConfigs, reconfigPairs>>

\* ============================================================================
\* ACTIONS — Elections (MongoRaftReconfig layer)
\* ============================================================================

\* CanVote: voter v grants a vote to candidate i for newTerm.
\* Reference: topology_coordinator.cpp:3719-3796 (processReplSetRequestVotes)
\*   3747: candidate config (version,term) must be >= voter's   (cross-config overlap)
\*   3752: args.term >= voter's _term
\*   3761: candidate's log >= voter's log
\*   3768: voter has not already voted in a term >= newTerm  (_lastVote.term)
CanVote(v, i, newTerm) ==
    /\ newTerm >= term[v]                          \* 3752
    /\ lastVoteTerm[v] < newTerm                   \* 3768 (one vote per term)
    /\ CVTGeq(config[i], config[v])                \* 3747 (candidate config not older)
    /\ LogNewerOrEqual(log[i], log[v])             \* 3761

\* --------------------------------------------------------------------------
\* BecomeLeader: candidate i wins an election in newTerm = term[i]+1 with an
\* election-quorum (majority of voters incl. arbiters) of its OWN config.
\* Models election atomically: the candidate increments term, every granting
\* voter records lastVote=newTerm.
\*
\* CRUCIAL (Family 1 decoupling): a granting voter that is a live primary does
\* NOT immediately bump its _term (updateTerm returns kTriggerStepDown,
\* topology_coordinator.cpp:3305-3306); it enters async step-down (commit frozen)
\* and keeps role=Primary in its OLD term until CompleteStepDown. A secondary
\* voter bumps its _term to newTerm (kUpdatedTerm, 3309).
\* --------------------------------------------------------------------------
BecomeLeader(i, voteQuorum) ==
    LET newTerm == term[i] + 1 IN
    /\ role[i] = Secondary                          \* a candidate is a follower
    /\ newTerm <= MaxTerm
    /\ i \in voteQuorum
    /\ IsConfigQuorum(voteQuorum, config[i])        \* election quorum of i's config
    /\ \A v \in voteQuorum : CanVote(v, i, newTerm)
    \* Candidate i becomes LeaderElect; commit frozen until drain (firstOpTime=∞, 2935).
    /\ term' = [v \in Server |->
                   IF v = i THEN newTerm
                   \* secondary voters adopt newTerm; primary voters defer (kTriggerStepDown)
                   ELSE IF v \in voteQuorum /\ role[v] = Secondary THEN newTerm
                   ELSE term[v]]
    /\ role' = [role EXCEPT ![i] = Primary]
    /\ primaryState' = [v \in Server |->
                   IF v = i THEN LeaderElect
                   \* a granting live primary enters async step-down (deferred term bump)
                   ELSE IF v \in voteQuorum /\ role[v] = Primary THEN SteppingDown
                   ELSE primaryState[v]]
    /\ pendingStepDown' = [v \in Server |->
                   IF v \in voteQuorum /\ v /= i /\ role[v] = Primary THEN TRUE
                   ELSE pendingStepDown[v]]
    /\ pendingTerm' = [v \in Server |->
                   IF v \in voteQuorum /\ v /= i /\ role[v] = Primary
                   THEN Max(pendingTerm[v], newTerm) ELSE pendingTerm[v]]
    /\ lastVoteTerm' = [v \in Server |->
                   IF v \in voteQuorum THEN newTerm ELSE lastVoteTerm[v]]
    /\ firstOpTime' = [firstOpTime EXCEPT ![i] = InfOpTime]   \* 2935 drain freeze
    /\ leaderHistory' = [leaderHistory EXCEPT ![newTerm] = @ \cup {i}]
    /\ UNCHANGED <<configVars, log, commitPoint, committedInPrev, reconfigVars,
                   netVars, committed, installedConfigs, reconfigPairs>>

\* --------------------------------------------------------------------------
\* CompletePrimaryDrain: new primary finishes drain — appends the first oplog
\* entry of its term (the "new primary" no-op) and unfreezes commit advancement.
\* Reference: completeTransitionToPrimary (topology_coordinator.cpp:3271-3279),
\*   _firstOpTimeOfMyTerm = firstOpTimeOfTerm; impl.cpp:1528 after the bump.
\* --------------------------------------------------------------------------
CompletePrimaryDrain(p) ==
    /\ role[p] = Primary
    /\ primaryState[p] = LeaderElect
    /\ Len(log[p]) < MaxLogLen
    /\ log' = [log EXCEPT ![p] = Append(@, term[p])]    \* first entry of my term
    /\ firstOpTime' = [firstOpTime EXCEPT ![p] = OpTimeRec(Len(log[p]) + 1, term[p])]
    /\ primaryState' = [primaryState EXCEPT ![p] = WritablePrimary]
    /\ UNCHANGED <<term, role, lastVoteTerm, configVars, commitPoint,
                   committedInPrev, reconfigVars, stepdownVars, netVars, histVars>>

\* --------------------------------------------------------------------------
\* StepUpBumpConfigTerm: the optimized step-up reconfig (doOptimizedReconfig,
\* skipSafetyChecks=true). Bumps the node's configTerm to its election term,
\* keeping the config version and membership unchanged. Runs during drain.
\* Reference: impl.cpp:3519 doOptimizedReconfig; analysis-report §2.1 step-up path;
\*   install never bumps _term (impl.cpp:4581-4584).
\* The (version, configTerm) strictly increases because configTerm rises to term[p].
\* --------------------------------------------------------------------------
StepUpBumpConfigTerm(p) ==
    /\ role[p] = Primary
    /\ primaryState[p] \in {LeaderElect, WritablePrimary}
    /\ config[p].term < term[p]                  \* configTerm behind election term
    /\ LET newCfg == [version  |-> config[p].version,
                      term     |-> term[p],
                      voters   |-> config[p].voters,
                      arbiters |-> config[p].arbiters]
       IN
       /\ config' = [config EXCEPT ![p] = newCfg]
       /\ installedConfigs' = installedConfigs \cup {newCfg}
    /\ UNCHANGED <<serverVars, logVars, reconfigVars, stepdownVars,
                   committed, leaderHistory, reconfigPairs>>

\* --------------------------------------------------------------------------
\* LearnHigherTerm: node n learns a strictly higher election term from peer m
\* (heartbeat carries the responder's _term; applied first at
\* ..._heartbeat.cpp:371 `_updateTerm(hbResponse.getTerm())`).
\* Reference: topology_coordinator.cpp:3296-3311 (updateTerm):
\*   - secondary: `_term = term` (kUpdatedTerm)
\*   - primary:   return kTriggerStepDown — _term NOT bumped; prepareForUnconditional-
\*                StepDown sets kSteppingDown SYNCHRONOUSLY (1948-1958), freezing commit.
\* --------------------------------------------------------------------------
LearnHigherTerm(n, m) ==
    /\ term[m] > term[n]
    /\ \/ \* Secondary: adopt the higher term immediately (kUpdatedTerm).
          /\ role[n] = Secondary
          /\ term' = [term EXCEPT ![n] = term[m]]
          /\ UNCHANGED <<role, primaryState, pendingStepDown, pendingTerm>>
       \/ \* Primary: defer term bump, enter synchronous step-down (kTriggerStepDown).
          /\ role[n] = Primary
          /\ primaryState[n] \in {LeaderElect, WritablePrimary}   \* not already stepping down
          /\ primaryState' = [primaryState EXCEPT ![n] = SteppingDown]  \* 1956 kSteppingDown (commit freeze)
          /\ pendingStepDown' = [pendingStepDown EXCEPT ![n] = TRUE]
          /\ pendingTerm' = [pendingTerm EXCEPT ![n] = Max(@, term[m])]
          /\ UNCHANGED <<term, role>>
       \/ \* Already stepping down: just record the (possibly higher) pending term.
          /\ role[n] = Primary
          /\ primaryState[n] = SteppingDown
          /\ pendingTerm' = [pendingTerm EXCEPT ![n] = Max(@, term[m])]
          /\ UNCHANGED <<term, role, primaryState, pendingStepDown>>
    /\ UNCHANGED <<lastVoteTerm, configVars, logVars, reconfigVars,
                   netVars, histVars>>

\* --------------------------------------------------------------------------
\* CompleteStepDown: the async unconditional step-down finishes (RSTL-X acquired).
\* The deferred term update is applied and the node becomes a secondary.
\* Reference: impl.cpp:3948-3989 / ..._heartbeat.cpp:973-998 stepdown completion;
\*   _updateWriteAbilityFromTopologyCoordinator drops canAcceptNonLocalWrites.
\* A pending command reconfig in flight on this node is aborted (config state guard).
\* --------------------------------------------------------------------------
CompleteStepDown(n) ==
    /\ role[n] = Primary
    /\ primaryState[n] = SteppingDown
    /\ term' = [term EXCEPT ![n] = Max(term[n], pendingTerm[n])]   \* deferred term bump
    /\ role' = [role EXCEPT ![n] = Secondary]
    /\ primaryState' = [primaryState EXCEPT ![n] = NotPrimary]
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![n] = FALSE]
    /\ pendingTerm' = [pendingTerm EXCEPT ![n] = 0]
    /\ firstOpTime' = [firstOpTime EXCEPT ![n] = ZeroOpTime]
    \* Abort any in-flight command reconfig (configStateGuard reverts to steady).
    /\ reconfigPhase' = [reconfigPhase EXCEPT ![n] = PhaseIdle]
    /\ pendingCfg' = [pendingCfg EXCEPT ![n] = NoCfg]
    /\ UNCHANGED <<lastVoteTerm, configVars, log, commitPoint, committedInPrev,
                   netVars, histVars>>

\* ============================================================================
\* ACTIONS — Command (non-force) reconfig, DE-ATOMIZED across the lock-drop window
\* ============================================================================

\* validateSingleNodeChange: symmetric difference of VOTING member id sets <= 1
\* (repl_set_config_checks.cpp:112-147). arbiterOnly cannot change for an existing
\* member (252-260). The candidate must remain a writable (electable) voter.
ValidSingleVotingChange(oldCfg, newVoters, newArbiters) ==
    /\ newArbiters \subseteq newVoters
    /\ Cardinality((oldCfg.voters \ newVoters) \cup (newVoters \ oldCfg.voters)) <= 1
    \* arbiterOnly unchanged for members present in both configs (252-260)
    /\ \A mem \in (oldCfg.voters \cap newVoters) :
           (mem \in oldCfg.arbiters) <=> (mem \in newArbiters)
    \* at least one writable (non-arbiter) voter so a data quorum exists
    /\ Cardinality(newVoters \ newArbiters) >= 1

\* --------------------------------------------------------------------------
\* ReconfigCheck: the entry gate of _doReplSetReconfig under _mutex, then drops
\* the lock (impl.cpp:3540-3636). Splits the reconfig so AdvanceCommitPoint /
\* LearnHigherTerm / InstallConfigViaHeartbeat can interleave before install.
\* Reference: impl.cpp
\*   3540-3558: must be kConfigSteady (reconfigPhase = idle)
\*   3563-3565: !canAcceptNonLocalWrites || _pendingTermUpdateDuringStepDown => reject
\*   3583-3587: config term == topCoord term (non-force; we don't model force)
\*   3593-3600: Q1 — current config is $configMajority committed
\*   3610-3623: Q2 — prev config's last committed optime committed in current config
\*   3636: lk.unlock()  (mutex dropped — the TOCTOU window begins)
\* Plus validateOldAndNewConfigsCompatible (checks.cpp:172) strictly-greater (v,t),
\* validateSingleNodeChange (checks.cpp:112), and checkElectable (impl.cpp:3785).
\* --------------------------------------------------------------------------
ReconfigCheck(p, newVoters, newArbiters) ==
    /\ reconfigPhase[p] = PhaseIdle                       \* 3540-3558 kConfigSteady
    /\ CanAcceptNonLocalWrites(p)                         \* 3563 canAcceptNonLocalWrites
    /\ ~pendingStepDown[p]                                \* 3563-3565 !_pendingTermUpdateDuringStepDown
    /\ primaryState[p] = WritablePrimary                  \* (entry gate: not draining/stepping down)
    /\ config[p].term = term[p]                           \* 3583-3587 configTerm == term
    /\ ConfigCommittedByPrimary(p)                        \* 3593-3600 Q1 (term-coupled)
    /\ config[p].version > 1 =>                           \* 3606 skip Q2 for initial config
         OpTimeCommittedByPrimary(p, ConfigOplogCommitmentOpTime(p))  \* 3610-3623 Q2 (term-coupled)
    /\ config[p].version + 1 <= MaxConfigVersion
    /\ ValidSingleVotingChange(config[p], newVoters, newArbiters)   \* checks.cpp:112-147
    /\ ElectableIn(p, [voters |-> newVoters, arbiters |-> newArbiters]) \* 3785 checkElectable
    /\ LET newCfg == [version  |-> config[p].version + 1,  \* version increments within term
                      term     |-> term[p],                \* non-force: configTerm = node term
                      voters   |-> newVoters,
                      arbiters |-> newArbiters]
       IN \* validateOldAndNewConfigsCompatible (checks.cpp:172): strictly greater (v,t)
          /\ CVTGreater(newCfg, config[p])
          /\ pendingCfg' = [pendingCfg EXCEPT ![p] = newCfg]
    /\ reconfigPhase' = [reconfigPhase EXCEPT ![p] = PhaseChecked]
    /\ UNCHANGED <<serverVars, configVars, logVars, stepdownVars, netVars, histVars>>

\* --------------------------------------------------------------------------
\* ReconfigPersist: persist the new config to disk + journal flush, after the
\* lock-drop. Models the persist re-check at impl.cpp:3849-3852.
\* Reference: impl.cpp:3843-3879. The re-check at 3850 tests ONLY
\* canAcceptNonLocalWrites — it does NOT re-test _pendingTermUpdateDuringStepDown
\* (Family 1b / CR1 asymmetry). canAcceptNonLocalWrites is still true during the
\* async SteppingDown window, so this re-check PASSES even if a higher term was
\* learned (pendingStepDown set) since ReconfigCheck.
\* --------------------------------------------------------------------------
ReconfigPersist(p) ==
    /\ reconfigPhase[p] = PhaseChecked
    /\ CanAcceptNonLocalWrites(p)   \* 3850 re-check: WritablePrimary OR SteppingDown (NO pendingStepDown test)
    /\ reconfigPhase' = [reconfigPhase EXCEPT ![p] = PhasePersisted]
    /\ UNCHANGED <<serverVars, configVars, logVars, pendingCfg, stepdownVars,
                   netVars, histVars>>

\* --------------------------------------------------------------------------
\* ReconfigInstall: _finishReplSetReconfig -> _setCurrentRSConfig installs the new
\* config. NO Q2 re-check here. Crucially, installing does NOT bump _term
\* (impl.cpp:4581-4584 — re-reads the existing term). The commit point is
\* recomputed under the NEW config, THEN the prev-config optime is snapshotted.
\* Reference: impl.cpp
\*   4572 _setCurrentRSConfig (install); 4581-4584 term shadow re-read (no bump)
\*   4738 _updateLastCommittedOpTimeAndWallTime (recompute under new config)
\*   4003 _topCoord->updateLastCommittedInPrevConfig() (snapshot AFTER recompute)
\* A non-force reconfig that keeps the primary electable never steps down here.
\* --------------------------------------------------------------------------
ReconfigInstall(p) ==
    /\ reconfigPhase[p] = PhasePersisted
    /\ LET newCfg == pendingCfg[p]
           oldCfg == config[p]
       IN
       /\ config' = [config EXCEPT ![p] = newCfg]         \* 4572 install (no _term bump, 4581-4584)
       \* 4003 snapshot prev-config commit point AFTER the new-config recompute.
       \* (The recompute itself is modeled by AdvanceCommitPoint now running under newCfg.)
       /\ committedInPrev' = [committedInPrev EXCEPT ![p] = commitPoint[p]]
       /\ installedConfigs' = installedConfigs \cup {newCfg}
       /\ reconfigPairs' = reconfigPairs \cup {[old |-> oldCfg, new |-> newCfg]}
    /\ reconfigPhase' = [reconfigPhase EXCEPT ![p] = PhaseIdle]
    /\ pendingCfg' = [pendingCfg EXCEPT ![p] = NoCfg]
    /\ UNCHANGED <<serverVars, log, commitPoint, firstOpTime, stepdownVars,
                   committed, leaderHistory>>

\* ============================================================================
\* ACTIONS — Heartbeat-driven config propagation (Family 1/2: async, no oplog)
\* ============================================================================

\* --------------------------------------------------------------------------
\* SendConfig: a node advertises its currently-installed config via heartbeat.
\* Reference: heartbeat responses carry the responder's ReplSetConfig
\* (topology_coordinator.cpp:1173 hbResponse.getValue().hasConfig()).
\* --------------------------------------------------------------------------
SendConfig(n) ==
    /\ config[n] \notin configMsgs
    /\ configMsgs' = configMsgs \cup {config[n]}
    /\ UNCHANGED <<serverVars, configVars, logVars, reconfigVars, stepdownVars,
                   histVars>>

\* --------------------------------------------------------------------------
\* InstallConfigViaHeartbeat: node p installs a strictly-newer config learned via
\* heartbeat. THE Family-1 mechanism: this path does NOT bump _term, and unlike
\* the command path it has NO configTerm-vs-_term re-check — so p can end up with
\* config[p].term > term[p].
\* Reference:
\*   topology_coordinator.cpp:1179 — install iff newConfig (v,t) > current (v,t)
\*   ..._heartbeat.cpp:707-716 — a PRIMARY that is not yet writable REFUSES a
\*       non-force heartbeat config (drain protection); a WRITABLE primary accepts.
\*   ..._heartbeat.cpp:680-698 — refuse while already reconfiguring (phase = idle)
\*   ..._heartbeat.cpp:1052 _setCurrentRSConfig; 899-1072 does NOT snapshot prev
\*       config nor drop snapshots (command-vs-heartbeat asymmetry).
\* --------------------------------------------------------------------------
InstallConfigViaHeartbeat(p, msg) ==
    /\ msg \in configMsgs
    /\ CVTGreater(msg, config[p])                  \* 1179 strictly newer (v,t)
    /\ reconfigPhase[p] = PhaseIdle                \* 680-698 not mid command-reconfig
    \* 707-716: a primary that cannot accept writes (draining) refuses non-force config.
    /\ ~(role[p] = Primary /\ primaryState[p] = LeaderElect)
    /\ config' = [config EXCEPT ![p] = msg]        \* install; _term NOT bumped (decoupling)
    /\ installedConfigs' = installedConfigs \cup {msg}
    \* _shouldStepDownOnReconfig: if p is no longer an electable voter, step down to a
    \* clean secondary, applying any deferred (pending) term update.
    /\ IF role[p] = Primary /\ ~ElectableIn(p, msg)
       THEN /\ role' = [role EXCEPT ![p] = Secondary]
            /\ primaryState' = [primaryState EXCEPT ![p] = NotPrimary]
            /\ firstOpTime' = [firstOpTime EXCEPT ![p] = ZeroOpTime]
            /\ term' = [term EXCEPT ![p] = Max(term[p], pendingTerm[p])]
            /\ pendingStepDown' = [pendingStepDown EXCEPT ![p] = FALSE]
            /\ pendingTerm' = [pendingTerm EXCEPT ![p] = 0]
       ELSE UNCHANGED <<role, primaryState, firstOpTime, term, stepdownVars>>
    /\ UNCHANGED <<lastVoteTerm, log, commitPoint, committedInPrev,
                   reconfigVars, netVars, committed, leaderHistory,
                   reconfigPairs>>

\* ============================================================================
\* ACTIONS — Crash / recovery
\* ============================================================================

\* --------------------------------------------------------------------------
\* Crash: a node restarts. Durable state (term, log, config, lastVote, commit
\* point — all journal-flushed) survives; in-memory volatile state is reset:
\* the node comes back as a Secondary, abandoning any primary role or in-flight
\* command reconfig. Reference: analysis-report §3.1; config persisted+journal-
\* flushed before install (impl.cpp:3878); recovery re-derives role via election.
\* --------------------------------------------------------------------------
Crash(n) ==
    /\ role' = [role EXCEPT ![n] = Secondary]
    /\ primaryState' = [primaryState EXCEPT ![n] = NotPrimary]
    /\ reconfigPhase' = [reconfigPhase EXCEPT ![n] = PhaseIdle]
    /\ pendingCfg' = [pendingCfg EXCEPT ![n] = NoCfg]
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![n] = FALSE]
    /\ pendingTerm' = [pendingTerm EXCEPT ![n] = 0]
    /\ firstOpTime' = [firstOpTime EXCEPT ![n] = ZeroOpTime]
    /\ UNCHANGED <<term, lastVoteTerm, configVars, log, commitPoint,
                   committedInPrev, netVars, histVars>>

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

\* Genesis config: every node is a voting, non-arbiter member of config (v=1, t=1).
GenesisCfg == [version |-> 1, term |-> 1, voters |-> Server, arbiters |-> {}]

Init ==
    /\ term          = [n \in Server |-> 1]
    /\ role          = [n \in Server |-> Secondary]
    /\ primaryState  = [n \in Server |-> NotPrimary]
    /\ lastVoteTerm  = [n \in Server |-> 0]
    /\ config        = [n \in Server |-> GenesisCfg]
    /\ log           = [n \in Server |-> << >>]
    /\ commitPoint   = [n \in Server |-> ZeroOpTime]
    /\ committedInPrev = [n \in Server |-> ZeroOpTime]
    /\ firstOpTime   = [n \in Server |-> ZeroOpTime]
    /\ reconfigPhase = [n \in Server |-> PhaseIdle]
    /\ pendingCfg    = [n \in Server |-> NoCfg]
    /\ pendingStepDown = [n \in Server |-> FALSE]
    /\ pendingTerm   = [n \in Server |-> 0]
    /\ committed     = {}
    /\ leaderHistory = [t \in 1..MaxTerm |-> {}]
    /\ installedConfigs = {GenesisCfg}
    /\ reconfigPairs = {}

Next ==
    \/ \E p \in Server :
        \/ ClientRequest(p)
        \/ AdvanceCommitPoint(p)
        \/ StartElection(p)
        \/ CompletePrimaryDrain(p)
        \/ StepUpBumpConfigTerm(p)
        \/ CompleteStepDown(p)
        \/ PrimaryStepDown(p)
        \/ ReconfigPersist(p)
        \/ ReconfigInstall(p)
        \/ Crash(p)
    \/ \E s, q \in Server :
        \/ GetEntries(s, q)
        \/ RollbackEntries(s, q)
        \/ LearnHigherTerm(s, q)
        \/ InstallConfigViaHeartbeat(s, q)
    \/ \E i \in Server : \E Q \in SUBSET Server :
        BecomeLeader(i, Q)
    \/ \E p \in Server : \E nv \in SUBSET Server : \E na \in SUBSET Server :
        ReconfigCheck(p, nv, na)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* SAFETY INVARIANTS
\* ============================================================================

\* --- Standard protocol safety ---

\* ElectionSafety (Family 1, Standard): at most one leader was ever elected per term.
\* Reference: repl/README.md ElectionSafety. (History-based; the cross-config
\* election-quorum overlap is the property the proof established for reconfig.)
ElectionSafety ==
    \A t \in 1..MaxTerm : Cardinality(leaderHistory[t]) <= 1

\* LeaderCompleteness / NeverRollbackCommitted (Family 1, 2, Standard): every committed
\* entry is present in the log of every current primary whose term is at least the
\* entry's COMMIT term (`cterm`, the term in which it first reached a quorum) — the
\* correct Raft Leader Completeness. A primary elected in a term BELOW the entry's commit
\* term predates the commit and may legitimately lack it, but is a harmless stale leader:
\* it cannot re-commit a conflicting entry (the quorum has moved to a higher term) and
\* cannot win a future election without first obtaining the entry. The deeper durability
\* guarantee (no committed write ever lost across reconfig) is OplogCommitmentAcrossReconfig.
\* Reference: repl/README.md NeverRollbackCommitted.
LeaderCompleteness ==
    \A c \in committed :
        \A s \in Server :
            (role[s] = Primary /\ term[s] >= c.cterm) => OpTimeInLog(c, s)

\* CommittedConsistency (Standard, StateMachineSafety): a committed log index never
\* holds two different terms — i.e., a committed entry is never rolled back and
\* replaced by a conflicting one.
CommittedConsistency ==
    \A c1, c2 \in committed : (c1.index = c2.index) => (c1.term = c2.term)

\* --- Extension invariants (bug-family targeted) ---

\* ConfigTermLeqElectionTerm (Family 1): a node acting as a WRITABLE primary should
\* not hold a config whose configTerm exceeds its own election term. A heartbeat
\* install (which never bumps _term and lacks the command path's term re-check) can
\* drive configTerm > _term; if the node is a writable primary in that state it is
\* acting under a config from a future term it has not actually entered. Tripwire
\* for the decoupling — investigate alongside ElectionSafety/LeaderCompleteness.
\* Reference: impl.cpp:4066-4078 (the asymmetric command-path guard).
ConfigTermLeqElectionTerm ==
    \A n \in Server :
        (role[n] = Primary /\ primaryState[n] = WritablePrimary)
            => config[n].term <= term[n]

\* OplogCommitmentAcrossReconfig (Family 2): a committed entry survives every
\* reconfig — it is held by at least one member of EVERY election quorum of every
\* node's current config, so no future leader can be elected without it. This is the
\* inductive quorum-overlap durability the proof relies on (Q2 "Oplog Commitment" +
\* single voting-member change), exercised here across the de-atomized install and
\* the commit-recompute-under-new-config window where Q2 is NOT re-checked.
\* (Asserting immediate Q2 under the new config would be too strong: replication to
\* a newly-added voter is async, so the prev-config commit point is on a new-config
\* data-quorum only eventually — that asyncwait is the NEXT reconfig's Q2 condition.)
\* Reference: impl.cpp:4003 (snapshot timing); 3610-3623 (Q2 at the gate only);
\* repl_set_config_checks.cpp:281-309 (election/write quorum overlap).
OplogCommitmentAcrossReconfig ==
    \A c \in committed :
        \A n \in Server :
            \A eq \in SUBSET config[n].voters :
                IsConfigQuorum(eq, config[n]) => (\E s \in eq : OpTimeInLog(c, s))

\* ConfigQuorumOverlap (Family 3): for every reconfig (old -> new), every election
\* quorum of the NEW config intersects every data (write) quorum of the OLD config.
\* This is the single-voting-member-change overlap the proof relied on, extended to
\* the dual quorum (election counts arbiters, data quorum excludes them).
\* Reference: repl_set_config_checks.cpp:281-309 overlap reasoning.
ConfigQuorumOverlap ==
    \A pr \in reconfigPairs :
        \A eq \in SUBSET pr.new.voters :
            \A wq \in SUBSET WritableVoters(pr.old) :
                (IsConfigQuorum(eq, pr.new) /\ IsDataQuorum(wq, pr.old))
                    => eq \cap wq /= {}

\* ConfigTotalOrder (Family 3, negative for Q2): no two distinct installed configs
\* share the same (version, term). In the non-force path configs are totally ordered;
\* a collision would mean two different durable configs at one (version,term).
\* Reference: analysis-report §3 Open Q2; repl_set_config.h:91-100.
ConfigTotalOrder ==
    \A c1, c2 \in installedConfigs :
        CVTEqual(c1, c2) => (c1.voters = c2.voters /\ c1.arbiters = c2.arbiters)

\* --- Structural invariants (sanity; should hold in all correct states) ---

TypeOKLite ==
    /\ \A n \in Server : term[n] \in 0..(MaxTerm + 5)
    /\ \A n \in Server : role[n] \in {Primary, Secondary}
    /\ \A n \in Server : primaryState[n] \in {NotPrimary, LeaderElect, WritablePrimary, SteppingDown}
    /\ \A n \in Server : reconfigPhase[n] \in {PhaseIdle, PhaseChecked, PhasePersisted}

\* A secondary is never in a primary sub-state, and vice versa.
RolePrimaryStateConsistent ==
    \A n \in Server :
        /\ (role[n] = Secondary) => (primaryState[n] = NotPrimary)
        /\ (role[n] = Primary)   => (primaryState[n] \in {LeaderElect, WritablePrimary, SteppingDown})

\* Arbiters are always a subset of voters; at least one writable voter exists.
ConfigWellFormed ==
    \A n \in Server :
        /\ config[n].arbiters \subseteq config[n].voters
        /\ Cardinality(WritableVoters(config[n])) >= 1

\* pendingStepDown is set exactly when the node is in the SteppingDown sub-state.
PendingStepDownConsistent ==
    \A n \in Server :
        pendingStepDown[n] <=> (role[n] = Primary /\ primaryState[n] = SteppingDown)

\* Commit point never exceeds the node's own log length.
CommitWithinLog ==
    \A n \in Server : commitPoint[n].index <= Len(log[n])

====
