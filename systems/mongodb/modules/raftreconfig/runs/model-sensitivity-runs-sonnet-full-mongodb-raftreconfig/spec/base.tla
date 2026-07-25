---- MODULE base ----
\* MongoDB Replica-Set Reconfiguration — Base Spec
\* Category A: Distributed / Message-Passing
\*
\* Bug-family driven extensions (Families 1-6 from modeling-brief.md):
\*   Family 1 — ConfigVersionAndTerm non-total ordering under force reconfig
\*   Family 2 — Dual reconfig paths with asymmetric safety gates
\*   Family 3 — Single-phase membership cutover and commit-point safety barrier
\*   Family 4 — Voting eligibility under config version/term constraints
\*   Family 5 — Non-atomic vote persistence
\*   Family 6 — Step-up auto-reconfig config term initialization race
\*
\* Source root: src/mongo/db/repl/

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* =========================================================
\* CONSTANTS
\* =========================================================

CONSTANTS
    Server        \* finite set of node identifiers

\* Roles
CONSTANTS Follower, Candidate, Leader

\* Config state machine values
\* replication_coordinator_impl.h (kConfigSteady / kConfigReconfiguring / kConfigHBReconfiguring)
CONSTANTS
    Steady,           \* kConfigSteady
    Reconfiguring,    \* kConfigReconfiguring — safe reconfig in progress
    PostSwap,         \* synthetic: between _setCurrentRSConfig and updateLastCommittedInPrevConfig
    HBReconfiguring   \* kConfigHBReconfiguring — heartbeat reconfig scheduled, not yet committed

\* Sentinel for force-reconfig configTerm (Family 1)
\* repl_set_config.h:76 — kUninitializedTerm = -1
CONSTANTS UNINITIALIZED

\* Message types
CONSTANTS
    M_RequestVote,
    M_RequestVoteReply,
    M_Heartbeat,
    M_HeartbeatReply,
    M_AppendEntries,
    M_AppendEntriesReply

\* Null sentinel
CONSTANTS Nil

\* Model bounds (overridden in MC.tla)
CONSTANTS MaxTerm, MaxLogLen, MaxConfigVersion, MaxCrash

\* =========================================================
\* VARIABLES
\* =========================================================

VARIABLES
    \* --- Standard Raft state ---
    currentTerm,  \* [Server -> Nat]
    role,         \* [Server -> {Follower,Candidate,Leader}]
    votedFor,     \* [Server -> Server ∪ {Nil}] — in-memory only (persisted via durableVote)
    log,          \* [Server -> Seq([term:Nat,index:Nat])]
    commitIndex,  \* [Server -> Nat]

    \* --- Config state (Family 1, 2, 3, 6) ---
    \* repl_set_config.h:76-129 — ConfigVersionAndTerm struct
    configVersion,  \* [Server -> Nat]
    configTerm,     \* [Server -> Nat ∪ {UNINITIALIZED}]  (Family 1: force sets to UNINITIALIZED)
    config,         \* [Server -> SUBSET Server] — current voting member set
    configState,    \* [Server -> {Steady,Reconfiguring,PostSwap,HBReconfiguring}]

    \* --- Commit barrier (Family 3) ---
    \* topology_coordinator.cpp:1705-1709 — lastCommittedInPrevConfig
    lastCommittedInPrevConfig,  \* [Server -> Nat] — oplog index barrier

    \* --- Non-atomic vote persistence (Family 5) ---
    \* replication_coordinator_impl.cpp:5325-5340
    inMemVote,    \* [Server -> [term:Nat, for:Server∪{Nil}]] — updated first, in-memory
    durableVote,  \* [Server -> [term:Nat, for:Server∪{Nil}]] — written later, survives crash

    \* --- Step-up auto-reconfig (Family 6) ---
    \* replication_coordinator_impl.cpp:1468 — async auto-reconfig pending flag
    autoReconfigPending,  \* [Server -> Bool]

    \* --- Pending HB reconfig state (Family 2) ---
    \* replication_coordinator_impl_heartbeat.cpp:689 — scheduled HB reconfig parameters
    pendingHBConfig,      \* [Server -> [cfg:SUBSET Server, ver:Nat, trm:Nat∪{UNINITIALIZED}] ∪ {Nil}]

    \* --- Message pool ---
    messages  \* set of message records

----

\* Variable groupings for UNCHANGED clauses
serverVars    == <<currentTerm, role, votedFor>>
logVars       == <<log, commitIndex>>
configVars    == <<configVersion, configTerm, config, configState>>
barrierVars   == <<lastCommittedInPrevConfig>>
voteVars      == <<inMemVote, durableVote>>
leaderVars    == <<autoReconfigPending>>
hbVars        == <<pendingHBConfig>>
vars == <<serverVars, logVars, configVars, barrierVars, voteVars, leaderVars, hbVars, messages>>

----

\* =========================================================
\* HELPERS
\* =========================================================

\* ConfigVersionAndTerm comparison — non-total ordering under force reconfig (Family 1)
\* repl_set_config.h:108-120 — operator< with term=UNINITIALIZED shortcut
ConfigLess(a, b) ==
    \* repl_set_config.h:108-115 — if either term is UNINITIALIZED, compare version only
    IF a.term = UNINITIALIZED \/ b.term = UNINITIALIZED
    THEN a.version < b.version
    \* repl_set_config.h:117-120 — normal case: lexicographic (term, version)
    ELSE \/ a.term < b.term
         \/ /\ a.term = b.term
            /\ a.version < b.version

ConfigLeq(a, b) == a = b \/ ConfigLess(a, b)

ConfigVAT(n) == [version |-> configVersion[n], term |-> configTerm[n]]

\* Is this node's config a force-reconfig config? (Family 1)
IsForceConfig(n) == configTerm[n] = UNINITIALIZED

\* Message helpers
Send(m)    == messages' = messages \cup {m}
Discard(m) == messages' = messages \ {m}
Reply(response, request) == messages' = (messages \ {request}) \cup {response}

\* Quorum: any majority of the given set
Quorum(S) == {Q \in SUBSET S : Cardinality(Q) * 2 > Cardinality(S)}

\* Log helpers
LastTerm(xlog)  == IF xlog = <<>> THEN 0 ELSE xlog[Len(xlog)].term
LastIndex(xlog) == Len(xlog)

\* replication_coordinator_impl_elect_v1.cpp:179 — log up-to-date check
LogUpToDate(lterm, lindex, n) ==
    \/ lterm > LastTerm(log[n])
    \/ /\ lterm = LastTerm(log[n])
       /\ lindex >= Len(log[n])

Min2(a, b) == IF a < b THEN a ELSE b

----

\* =========================================================
\* INIT
\* =========================================================

Init ==
    /\ currentTerm          = [n \in Server |-> 0]
    /\ role                 = [n \in Server |-> Follower]
    /\ votedFor             = [n \in Server |-> Nil]
    /\ log                  = [n \in Server |-> <<>>]
    /\ commitIndex          = [n \in Server |-> 0]
    /\ configVersion        = [n \in Server |-> 1]
    /\ configTerm           = [n \in Server |-> 0]
    /\ config               = [n \in Server |-> Server]
    /\ configState          = [n \in Server |-> Steady]
    /\ lastCommittedInPrevConfig = [n \in Server |-> 0]
    /\ inMemVote            = [n \in Server |-> [term |-> 0, for |-> Nil]]
    /\ durableVote          = [n \in Server |-> [term |-> 0, for |-> Nil]]
    /\ autoReconfigPending  = [n \in Server |-> FALSE]
    /\ pendingHBConfig      = [n \in Server |-> Nil]
    /\ messages             = {}

----

\* =========================================================
\* ACTIONS
\* =========================================================

\* ---------------------------------------------------------
\* Timeout: node becomes candidate, increments term
\* replication_coordinator_impl_elect_v1.cpp:140
\* ---------------------------------------------------------

Timeout(n) ==
    \* replication_coordinator_impl_elect_v1.cpp:140 — election timeout fires
    /\ role[n] \in {Follower, Candidate}
    /\ currentTerm[n] < MaxTerm
    /\ currentTerm' = [currentTerm EXCEPT ![n] = currentTerm[n] + 1]
    /\ role' = [role EXCEPT ![n] = Candidate]
    \* Self-vote: in-memory only first (Family 5: persist happens separately)
    /\ votedFor' = [votedFor EXCEPT ![n] = n]
    /\ inMemVote' = [inMemVote EXCEPT
            ![n] = [term |-> currentTerm[n] + 1, for |-> n]]
    /\ durableVote' = [durableVote EXCEPT
            ![n] = [term |-> currentTerm[n] + 1, for |-> n]]
    /\ UNCHANGED <<logVars, configVars, barrierVars, leaderVars, hbVars, messages>>

\* ---------------------------------------------------------
\* RequestVotes: send vote requests to all config members
\* vote_requester.cpp:83-124
\* ---------------------------------------------------------

RequestVotes(candidate) ==
    /\ role[candidate] = Candidate
    \* Each voter receives exactly one request
    /\ LET newMsgs == { [mtype         |-> M_RequestVote,
                          mterm         |-> currentTerm[candidate],
                          mfrom         |-> candidate,
                          mto           |-> voter,
                          \* vote_requester.cpp:96-112 — configTerm omitted when UNINITIALIZED (Family 1)
                          mconfigVAT    |-> ConfigVAT(candidate),
                          mlastLogTerm  |-> LastTerm(log[candidate]),
                          mlastLogIndex |-> Len(log[candidate])]
                       : voter \in config[candidate] \ {candidate} }
       IN messages' = messages \cup newMsgs
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, voteVars, leaderVars, hbVars>>

\* ---------------------------------------------------------
\* HandleRequestVote: process incoming vote request
\* topology_coordinator.cpp:3747-3791 (Families 4, 5)
\* ---------------------------------------------------------

HandleRequestVote(voter, m) ==
    /\ m.mtype  = M_RequestVote
    /\ m.mto    = voter
    /\ LET req       == m
           voterVAT  == ConfigVAT(voter)
           \* topology_coordinator.cpp:3747-3752 — config check before term check (Family 4)
           configOK  == ConfigLeq(voterVAT, req.mconfigVAT)
           \* topology_coordinator.cpp:3753 — term must be >= current
           termOK    == req.mterm >= currentTerm[voter]
           logOK     == LogUpToDate(req.mlastLogTerm, req.mlastLogIndex, voter)
           \* SERVER-57262: relaxed ">= configVAT" rule; prior strict rule was "= configVAT" (Family 4)
           canGrant  == configOK /\ termOK /\ logOK
                        /\ (votedFor[voter] = Nil \/ votedFor[voter] = req.mfrom)
           newTerm   == IF req.mterm > currentTerm[voter]
                        THEN req.mterm ELSE currentTerm[voter]
       IN
       /\ currentTerm' = [currentTerm EXCEPT ![voter] = newTerm]
       /\ role' = [role EXCEPT
               ![voter] = IF req.mterm > currentTerm[voter] THEN Follower ELSE role[voter]]
       /\ votedFor' = [votedFor EXCEPT
               ![voter] = IF canGrant THEN req.mfrom ELSE votedFor[voter]]
       \* topology_coordinator.cpp:3789-3791 — in-memory vote advanced BEFORE caller persists (Family 5)
       /\ inMemVote' = [inMemVote EXCEPT
               ![voter] = IF canGrant
                          THEN [term |-> newTerm, for |-> req.mfrom]
                          ELSE inMemVote[voter]]
       /\ Reply([mtype    |-> M_RequestVoteReply,
                 mterm    |-> newTerm,
                 mfrom    |-> voter,
                 mto      |-> req.mfrom,
                 mgranted |-> canGrant], m)
       \* replication_coordinator_impl.cpp — step-down aborts in-progress safe reconfig
       /\ configState' = [configState EXCEPT
              ![voter] = IF req.mterm > currentTerm[voter] THEN Steady ELSE configState[voter]]
       /\ UNCHANGED <<log, commitIndex, configVersion, configTerm, config, barrierVars, durableVote, leaderVars, hbVars>>

\* ---------------------------------------------------------
\* PersistVote: flush in-memory vote to durable storage (Family 5)
\* replication_coordinator_impl.cpp:5325-5340
\* storeLocalLastVoteDocument called outside the mutex AFTER in-memory update
\* ---------------------------------------------------------

PersistVote(n) ==
    \* replication_coordinator_impl.cpp:5340 — persist called after in-memory update
    /\ inMemVote[n] /= durableVote[n]
    /\ durableVote' = [durableVote EXCEPT ![n] = inMemVote[n]]
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, inMemVote, leaderVars, hbVars, messages>>

\* ---------------------------------------------------------
\* BecomeLeader: win election on receiving quorum of votes
\* replication_coordinator_impl_elect_v1.cpp:_onVoteRequestComplete
\* ---------------------------------------------------------

BecomeLeader(n) ==
    /\ role[n] = Candidate
    /\ \E Q \in Quorum(config[n]) :
        /\ n \in Q
        /\ \A voter \in Q \ {n} :
            \E m \in messages :
                /\ m.mtype    = M_RequestVoteReply
                /\ m.mto      = n
                /\ m.mfrom    = voter
                /\ m.mgranted = TRUE
                /\ m.mterm    = currentTerm[n]
    /\ role' = [role EXCEPT ![n] = Leader]
    \* replication_coordinator_impl.cpp:1468 — schedules auto-reconfig immediately on becoming primary (Family 6)
    /\ autoReconfigPending' = [autoReconfigPending EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, configVars, barrierVars, voteVars, hbVars, messages>>

\* ---------------------------------------------------------
\* AutoReconfig: step-up auto-reconfig — bump configTerm to election term (Family 6)
\* replication_coordinator_impl.cpp:1468-1514
\* Runs as a separate async operation after BecomeLeader
\* ---------------------------------------------------------

AutoReconfig(n) ==
    \* replication_coordinator_impl.cpp:1484-1487 — only proceed if configTerm still needs update
    /\ role[n] = Leader
    /\ autoReconfigPending[n] = TRUE
    /\ configState[n] = Steady
    /\ configTerm[n] /= currentTerm[n]   \* configTerm lags (still UNINITIALIZED or old term)
    /\ configVersion' = [configVersion EXCEPT ![n] = configVersion[n] + 1]
    /\ configTerm'   = [configTerm   EXCEPT ![n] = currentTerm[n]]
    \* replication_coordinator_impl.cpp:1504 — auto-reconfig complete
    /\ autoReconfigPending' = [autoReconfigPending EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, config, configState, barrierVars, voteVars, hbVars, messages>>

\* replication_coordinator_impl.cpp:1504-1512 — ConfigurationInProgress error is non-fatal (Family 6)
\* Concurrent HBReconfig or SafeReconfig preempts auto-reconfig; flag cleared, configTerm NOT updated
AutoReconfigPreempted(n) ==
    /\ role[n] = Leader
    /\ autoReconfigPending[n] = TRUE
    /\ configState[n] /= Steady   \* concurrent reconfig in progress blocks auto-reconfig
    /\ autoReconfigPending' = [autoReconfigPending EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, voteVars, hbVars, messages>>

\* ---------------------------------------------------------
\* ForceReconfig: external force reconfig path (Family 1)
\* replication_coordinator_impl.cpp:3425 — _doReplSetReconfig force=true branch
\* Sets configTerm := UNINITIALIZED (kUninitializedTerm) instead of currentTerm
\* ---------------------------------------------------------

ForceReconfig(n, newCfg, newVersion) ==
    /\ configState[n] = Steady
    /\ newVersion > configVersion[n]
    /\ newVersion <= MaxConfigVersion
    /\ Cardinality(newCfg) >= 1
    /\ config'        = [config        EXCEPT ![n] = newCfg]
    /\ configVersion' = [configVersion EXCEPT ![n] = newVersion]
    \* replication_coordinator_impl.cpp:3425 — force sets configTerm := kUninitializedTerm (Family 1)
    /\ configTerm'    = [configTerm    EXCEPT ![n] = UNINITIALIZED]
    /\ configState'   = [configState   EXCEPT ![n] = Steady]
    \* Force reconfig resets lastCommittedInPrevConfig barrier (Family 3)
    /\ lastCommittedInPrevConfig' = [lastCommittedInPrevConfig EXCEPT ![n] = 0]
    /\ UNCHANGED <<serverVars, logVars, voteVars, leaderVars, hbVars, messages>>

\* ---------------------------------------------------------
\* SafeReconfigStart: begin leader-driven reconfig (Family 2)
\* replication_coordinator_impl.cpp:_doReplSetReconfig (force=false)
\* Enforces full safety gate before entering Reconfiguring state
\* ---------------------------------------------------------

SafeReconfigStart(n, newCfg) ==
    \* replication_coordinator_impl.cpp:3412 — entry: must be leader
    /\ role[n] = Leader
    /\ configState[n] = Steady
    /\ currentTerm[n] >= 1
    \* repl_set_config_checks.cpp:542 — validateConfigForReconfig: must be non-empty
    /\ Cardinality(newCfg) >= 1
    /\ newCfg /= config[n]    \* new config must differ
    \* check_quorum_for_config_change.cpp:64 — quorum reachability check (simplified: use current commit)
    /\ \E Q \in Quorum(config[n]) : n \in Q   \* leader has quorum in current config
    /\ configState' = [configState EXCEPT ![n] = Reconfiguring]
    /\ UNCHANGED <<serverVars, logVars, configVersion, configTerm, config, barrierVars, voteVars, leaderVars, hbVars, messages>>

\* Step 2 of safe reconfig: install new config (Family 3)
\* replication_coordinator_impl.cpp:3997 — _setCurrentRSConfig (WRONG ORDER: before barrier capture)
\* Transitions to PostSwap, NOT Steady — exposes race window between lines 3997 and 4003
SafeReconfigSwap(n, newCfg) ==
    /\ configState[n] = Reconfiguring
    /\ role[n] = Leader
    /\ Cardinality(newCfg) >= 1
    \* replication_coordinator_impl.cpp:3997 — config installed; quorum now uses new member set
    /\ config'        = [config        EXCEPT ![n] = newCfg]
    /\ configVersion' = [configVersion EXCEPT ![n] = configVersion[n] + 1]
    /\ configTerm'    = [configTerm    EXCEPT ![n] = currentTerm[n]]
    \* Transition to PostSwap: barrier NOT yet captured (CR1 — ordering inversion)
    /\ configState' = [configState EXCEPT ![n] = PostSwap]
    /\ UNCHANGED <<serverVars, logVars, barrierVars, voteVars, leaderVars, hbVars, messages>>

\* Step 3: capture commit barrier AFTER config swap (Family 3)
\* replication_coordinator_impl.cpp:4003 — updateLastCommittedInPrevConfig
\* In real code this runs AFTER _setCurrentRSConfig (line 3997), creating the race window
\* topology_coordinator.cpp:1705-1709 — barrier = max(lastCommittedInPrevConfig, firstOpTimeOfMyTerm)
SafeReconfigCaptureBarrier(n) ==
    /\ configState[n] = PostSwap
    /\ role[n] = Leader
    \* replication_coordinator_impl.cpp:4003 — barrier captured at current commitIndex
    /\ lastCommittedInPrevConfig' = [lastCommittedInPrevConfig EXCEPT
           ![n] = commitIndex[n]]
    /\ configState' = [configState EXCEPT ![n] = Steady]
    /\ UNCHANGED <<serverVars, logVars, configVersion, configTerm, config, voteVars, leaderVars, hbVars, messages>>

\* ---------------------------------------------------------
\* HBReconfigSchedule: heartbeat reconfig — schedule async callback (Family 2)
\* replication_coordinator_impl_heartbeat.cpp:689-698
\* Only checks configVersionAndTerm ordering; skips ALL safety gates
\* ---------------------------------------------------------

HBReconfigSchedule(n, newCfg, newVersion, newTerm) ==
    \* replication_coordinator_impl_heartbeat.cpp:698 — silently dropped when kConfigReconfiguring active
    /\ configState[n] = Steady
    \* topology_coordinator.cpp:1043 — compare configVersionAndTerm (sender vs receiver)
    /\ ConfigLess(ConfigVAT(n), [version |-> newVersion, term |-> newTerm])
    \* repl_set_config_checks.cpp:588-615 — HB reconfig skips validateSingleNodeChange, PSA checks, etc.
    /\ pendingHBConfig' = [pendingHBConfig EXCEPT
           ![n] = [cfg |-> newCfg, ver |-> newVersion, trm |-> newTerm]]
    /\ configState' = [configState EXCEPT ![n] = HBReconfiguring]
    /\ UNCHANGED <<serverVars, logVars, configVersion, configTerm, config, barrierVars, voteVars, leaderVars, messages>>

\* HBReconfig callback: install the config (Family 2)
\* replication_coordinator_impl_heartbeat.cpp:_heartbeatReconfigFinish
HBReconfigFinish(n) ==
    /\ configState[n] = HBReconfiguring
    /\ pendingHBConfig[n] /= Nil
    /\ LET hb == pendingHBConfig[n] IN
       /\ config'        = [config        EXCEPT ![n] = hb.cfg]
       /\ configVersion' = [configVersion EXCEPT ![n] = hb.ver]
       /\ configTerm'    = [configTerm    EXCEPT ![n] = hb.trm]
    /\ configState'     = [configState EXCEPT ![n] = Steady]
    /\ pendingHBConfig' = [pendingHBConfig EXCEPT ![n] = Nil]
    /\ UNCHANGED <<serverVars, logVars, barrierVars, voteVars, leaderVars, messages>>

\* TV1: HBReconfig callback fires after state was reset by concurrent user reconfig (Family 2)
\* replication_coordinator_impl_heartbeat.cpp — assertion fires when state != HBReconfiguring
HBReconfigAborted(n) ==
    \* concurrent SafeReconfig or ForceReconfig has already reset configState to Steady
    /\ configState[n] = Steady
    /\ pendingHBConfig[n] /= Nil
    \* Callback is aborted; no config installed; no retry scheduled (SERVER-46897 scenario)
    /\ pendingHBConfig' = [pendingHBConfig EXCEPT ![n] = Nil]
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, voteVars, leaderVars, messages>>

\* ---------------------------------------------------------
\* AppendEntry: leader appends a new log entry
\* ---------------------------------------------------------

AppendEntry(n) ==
    /\ role[n] = Leader
    /\ Len(log[n]) < MaxLogLen
    /\ LET entry == [term |-> currentTerm[n], index |-> Len(log[n]) + 1]
       IN log' = [log EXCEPT ![n] = Append(log[n], entry)]
    /\ UNCHANGED <<serverVars, commitIndex, configVars, barrierVars, voteVars, leaderVars, hbVars, messages>>

\* Leader sends log entries to a follower
SendAppendEntries(leader, follower) ==
    /\ role[leader] = Leader
    /\ leader /= follower
    /\ follower \in config[leader]
    /\ Len(log[leader]) > 0
    /\ Send([mtype      |-> M_AppendEntries,
             mfrom      |-> leader,
             mto        |-> follower,
             mterm      |-> currentTerm[leader],
             mentries   |-> log[leader],
             mcommit    |-> commitIndex[leader],
             mconfigVAT |-> ConfigVAT(leader)])
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, voteVars, leaderVars, hbVars>>

\* Follower handles AppendEntries (simplified: accepts if term >= current)
HandleAppendEntries(n, m) ==
    /\ m.mtype = M_AppendEntries
    /\ m.mto   = n
    /\ m.mterm >= currentTerm[n]
    /\ currentTerm' = [currentTerm EXCEPT ![n] = m.mterm]
    /\ role'        = [role        EXCEPT ![n] = Follower]
    /\ log'         = [log         EXCEPT ![n] = m.mentries]
    /\ commitIndex' = [commitIndex  EXCEPT ![n] = Min2(m.mcommit, Len(m.mentries))]
    /\ Discard(m)
    \* Receiving AppendEntries forces Follower role; abort any in-progress leader reconfig
    /\ configState' = [configState EXCEPT
           ![n] = IF configState[n] \in {Reconfiguring, PostSwap} THEN Steady ELSE configState[n]]
    /\ UNCHANGED <<votedFor, configVersion, configTerm, config, barrierVars, voteVars, leaderVars, hbVars>>

\* Leader advances commit index when a quorum of the CURRENT config has replicated
\* replication_coordinator_impl.cpp:updateLastCommittedOpTimeAndWallTime
\* Note: after config swap, quorum is computed against the NEW config immediately
AdvanceCommitIndex(n) ==
    /\ role[n] = Leader
    /\ \E newCI \in (commitIndex[n] + 1)..Len(log[n]) :
        \* log[n][newCI].term must be current term (leader completeness)
        /\ log[n][newCI].term = currentTerm[n]
        \* quorum of CURRENT config[n] (Family 3: after swap, new config used for quorum)
        /\ \E Q \in Quorum(config[n]) :
             \A m \in Q : Len(log[m]) >= newCI /\ log[m][newCI] = log[n][newCI]
        /\ commitIndex' = [commitIndex EXCEPT ![n] = newCI]
    /\ UNCHANGED <<serverVars, log, configVars, barrierVars, voteVars, leaderVars, hbVars, messages>>

\* ---------------------------------------------------------
\* SendHeartbeat / HandleHeartbeat (Family 2, 6)
\* replication_coordinator_impl_heartbeat.cpp
\* Heartbeats carry configVersionAndTerm to trigger HBReconfig
\* ---------------------------------------------------------

SendHeartbeat(from, to) ==
    /\ from /= to
    /\ to \in config[from]
    /\ Send([mtype      |-> M_Heartbeat,
             mfrom      |-> from,
             mto        |-> to,
             mterm      |-> currentTerm[from],
             mconfigVAT |-> ConfigVAT(from),
             mcfg       |-> config[from]])
    /\ UNCHANGED <<serverVars, logVars, configVars, barrierVars, voteVars, leaderVars, hbVars>>

HandleHeartbeat(n, m) ==
    /\ m.mtype = M_Heartbeat
    /\ m.mto   = n
    /\ LET senderHigherTerm == m.mterm > currentTerm[n]
           senderHigherVAT  == ConfigLess(ConfigVAT(n), m.mconfigVAT)
       IN
       \* Update term if stale
       /\ currentTerm' = [currentTerm EXCEPT
               ![n] = IF senderHigherTerm THEN m.mterm ELSE currentTerm[n]]
       /\ role' = [role EXCEPT
               ![n] = IF senderHigherTerm THEN Follower ELSE role[n]]
       \* replication_coordinator_impl_heartbeat.cpp:689-698 — schedule HBReconfig if sender has higher VAT
       /\ IF senderHigherVAT /\ configState[n] = Steady
          THEN /\ pendingHBConfig' = [pendingHBConfig EXCEPT
                     ![n] = [cfg |-> m.mcfg, ver |-> m.mconfigVAT.version, trm |-> m.mconfigVAT.term]]
               /\ configState' = [configState EXCEPT ![n] = HBReconfiguring]
          ELSE /\ UNCHANGED pendingHBConfig
               \* Step-down aborts any in-progress safe reconfig
               /\ configState' = [configState EXCEPT
                      ![n] = IF senderHigherTerm /\ configState[n] \in {Reconfiguring, PostSwap}
                             THEN Steady ELSE configState[n]]
       /\ Discard(m)
       /\ UNCHANGED <<votedFor, logVars, configVersion, configTerm, config, barrierVars, voteVars, leaderVars>>

\* ---------------------------------------------------------
\* Crash and Restart (Families 3, 5)
\* In-memory state lost; durable state (log, durableVote, configVersion/Term) survives
\* ---------------------------------------------------------

Crash(n) ==
    /\ role'           = [role           EXCEPT ![n] = Follower]
    \* replication_coordinator_impl.cpp:5325 — in-memory vote reverts to durable on restart (Family 5)
    /\ inMemVote'      = [inMemVote      EXCEPT ![n] = durableVote[n]]
    /\ votedFor'       = [votedFor       EXCEPT ![n] = durableVote[n].for]
    \* replication_coordinator_impl.cpp:783-786 — _finishLoadLocalConfig bumps term to
    \* max(lastVote.term, configTerm); UNINITIALIZED = -1 never exceeds a valid term
    /\ currentTerm'    = [currentTerm    EXCEPT
           ![n] = IF configTerm[n] /= UNINITIALIZED /\ configTerm[n] > durableVote[n].term
                  THEN configTerm[n]
                  ELSE durableVote[n].term]
    /\ configState'    = [configState    EXCEPT ![n] = Steady]
    /\ autoReconfigPending' = [autoReconfigPending EXCEPT ![n] = FALSE]
    /\ pendingHBConfig' = [pendingHBConfig EXCEPT ![n] = Nil]
    \* Config (version, term, members) persisted to disk — survives crash
    \* commitIndex reset to 0 on restart (must re-derive from log)
    /\ commitIndex'    = [commitIndex    EXCEPT ![n] = 0]
    /\ UNCHANGED <<log, configVersion, configTerm, config, lastCommittedInPrevConfig, durableVote, messages>>

----

\* =========================================================
\* NEXT
\* =========================================================

Next ==
    \/ \E n \in Server : Timeout(n)
    \/ \E n \in Server : RequestVotes(n)
    \/ \E m \in messages : m.mtype = M_RequestVote /\ HandleRequestVote(m.mto, m)
    \/ \E n \in Server : PersistVote(n)
    \/ \E n \in Server : BecomeLeader(n)
    \/ \E n \in Server : AutoReconfig(n)
    \/ \E n \in Server : AutoReconfigPreempted(n)
    \/ \E n \in Server, newCfg \in SUBSET Server, newVer \in 1..MaxConfigVersion :
           ForceReconfig(n, newCfg, newVer)
    \/ \E n \in Server, newCfg \in SUBSET Server : SafeReconfigStart(n, newCfg)
    \/ \E n \in Server, newCfg \in SUBSET Server : SafeReconfigSwap(n, newCfg)
    \/ \E n \in Server : SafeReconfigCaptureBarrier(n)
    \/ \E n \in Server, newCfg \in SUBSET Server, v \in 1..MaxConfigVersion,
           t \in ({UNINITIALIZED} \cup 0..MaxTerm) :
               HBReconfigSchedule(n, newCfg, v, t)
    \/ \E n \in Server : HBReconfigFinish(n)
    \/ \E n \in Server : HBReconfigAborted(n)
    \/ \E n \in Server : AppendEntry(n)
    \/ \E n \in Server, m2 \in Server : SendAppendEntries(n, m2)
    \/ \E m \in messages : m.mtype = M_AppendEntries /\ HandleAppendEntries(m.mto, m)
    \/ \E n \in Server : AdvanceCommitIndex(n)
    \/ \E from \in Server, to \in Server : from /= to /\ SendHeartbeat(from, to)
    \/ \E m \in messages : m.mtype = M_Heartbeat /\ HandleHeartbeat(m.mto, m)
    \/ \E n \in Server : Crash(n)

Spec == Init /\ [][Next]_vars

FairSpec == Spec /\ WF_vars(Next)

----

\* =========================================================
\* INVARIANTS
\* =========================================================

\* Standard: at most one leader per term across all servers
\* Targets Families 1, 4
ElectionSafety ==
    \A n1, n2 \in Server :
        /\ role[n1] = Leader
        /\ role[n2] = Leader
        /\ currentTerm[n1] = currentTerm[n2]
        => n1 = n2

\* Entries at the same (index, term) must be identical on both logs
\* Targets Family 3
LogMatching ==
    \A n1, n2 \in Server :
    \A i \in 1..Min2(Len(log[n1]), Len(log[n2])) :
        log[n1][i].term = log[n2][i].term =>
        SubSeq(log[n1], 1, i) = SubSeq(log[n2], 1, i)

\* Family 1: configVersion is always positive
ConfigVersionPositive ==
    \A n \in Server : configVersion[n] >= 1

\* Family 2: nodes in Reconfiguring/PostSwap state must have been leaders
\* (Only leaders can initiate safe reconfig)
ReconfigOnlyByLeader ==
    \A n \in Server :
        configState[n] \in {Reconfiguring, PostSwap} => role[n] = Leader

\* Family 5: Durable vote term never exceeds in-memory vote term
VoteTermMonotone ==
    \A n \in Server :
        durableVote[n].term <= inMemVote[n].term

\* Family 5: No node grants two votes in the same term (including after crash)
\* Simplified: no two distinct in-flight vote-reply grants for the same term
VoteOnce ==
    \A m1, m2 \in messages :
        /\ m1.mtype    = M_RequestVoteReply
        /\ m2.mtype    = M_RequestVoteReply
        /\ m1.mfrom    = m2.mfrom
        /\ m1.mgranted = TRUE
        /\ m2.mgranted = TRUE
        /\ m1.mterm    = m2.mterm
        => m1.mto = m2.mto

\* Family 6: A leader's configTerm is at most its election term
ConfigTermBelowElectionTerm ==
    \A n \in Server :
        role[n] = Leader =>
        (configTerm[n] = UNINITIALIZED \/ configTerm[n] <= currentTerm[n])

\* Family 3: Commit barrier does not exceed current commit index
CommitBarrierConsistency ==
    \A n \in Server :
        lastCommittedInPrevConfig[n] <= commitIndex[n]

\* Family 3: After config swap (PostSwap), committed entries must reach
\*  quorum of the NEW config before the barrier is final
\* This is the extension invariant targeting MC3 and CR1
CommitPointSafety ==
    \A n \in Server :
        \A i \in 1..lastCommittedInPrevConfig[n] :
            \E Q \in Quorum(config[n]) :
                \A m \in Q : Len(log[m]) >= i

\* Structural: configState values are valid
ConfigStateValid ==
    \A n \in Server :
        configState[n] \in {Steady, Reconfiguring, PostSwap, HBReconfiguring}

\* Structural: pendingHBConfig is non-Nil iff in HBReconfiguring state
HBConfigStateConsistency ==
    \A n \in Server :
        (pendingHBConfig[n] /= Nil) => configState[n] = HBReconfiguring

\* =========================================================
\* LIVENESS
\* =========================================================

\* Family 6: Eventually every primary has configTerm = electionTerm
LeaderConfigCurrentness ==
    <>(\A n \in Server : role[n] = Leader => configTerm[n] = currentTerm[n])

====
