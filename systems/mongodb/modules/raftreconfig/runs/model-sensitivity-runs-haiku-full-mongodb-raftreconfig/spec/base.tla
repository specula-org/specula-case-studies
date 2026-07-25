---------------------------- MODULE base ----------------------------
(* MongoDB Replica Set Reconfiguration (Raft-based) *)
(* Specification of config install safety under non-atomic persistence *)
(* and asymmetric term/version comparison *)

EXTENDS Naturals, Sequences, FiniteSets, TLC

(* ====== Constants ====== *)

CONSTANT Server      \* Set of server IDs
CONSTANT UninitTerm  \* Special value for uninitialized term (force reconfig)

\* Quorum function: majority of servers
Quorum(S) == 2 * Cardinality(S) > Cardinality(Server)

(* ====== Variables ====== *)

(* ---- Standard Protocol State ---- *)
(* ---- Non-Atomic Persistence (Family 2) ---- *)
(* ---- Quorum Checking (Family 3) ---- *)
(* ---- Commitment Tracking (Family 5) ---- *)
(* ---- Config State Machine (Family 6) ---- *)
VARIABLE
  currentTerm,         \* [s \in Server] -> Nat: current term/epoch
  configTerm,          \* [s \in Server] -> Int: config term (UninitTerm = uninitialized/force)
  configVersion,       \* [s \in Server] -> Nat: config version number
  configState,         \* [s \in Server] -> ConfigStateType
  persistedConfigTerm,    \* [s \in Server] -> Int: durable version on disk
  persistedConfigVersion, \* [s \in Server] -> Nat: durable version on disk
  pendingConfigWrite,      \* [s \in Server] -> BOOLEAN: persist in progress
  quorumState,        \* [s \in Server] -> QuorumCheckState: scatter-gather state
  voterResponses,     \* [s \in Server] -> SUBSET Server: voters who responded
  respondCount,       \* [s \in Server] -> Nat: response count for this quorum
  committedOptimeInConfig, \* [s \in Server] -> Int: highest committed optime in current config
  configStateEnum     \* [s \in Server] -> {kConfigSteady, kConfigReconfiguring, ...}

(* ---- Helpers ---- *)
vars == <<
  currentTerm, configTerm, configVersion, configState,
  persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
  quorumState, voterResponses, respondCount,
  committedOptimeInConfig, configStateEnum >>

(* ====== Type Definitions ====== *)

\* ConfigStateType == [term |->0..20, version |->0..20]

QuorumCheckState == {
  "idle",           \* Not checking
  "in_progress",    \* Quorum check active
  "succeeded",      \* Quorum check passed
  "failed"          \* Quorum check failed
}

(* ====== Helpers ====== *)

(* Config version/term comparison (Family 1: asymmetric)
   Lines 91-99 in repl_set_config.h *)
ConfigVersionTermLess(cvt1, cvt2) ==
  LET t1 == cvt1.term
      t2 == cvt2.term
      v1 == cvt1.version
      v2 == cvt2.version
  IN
    \* If either term is uninitialized (UninitTerm), compare versions only
    IF t1 = UninitTerm \/ t2 = UninitTerm THEN
      v1 < v2
    ELSE
      \* Both initialized: compare term first, then version
      IF t1 # t2 THEN t1 < t2 ELSE v1 < v2

ConfigVersionTermEq(cvt1, cvt2) ==
  LET t1 == cvt1.term
      t2 == cvt2.term
      v1 == cvt1.version
      v2 == cvt2.version
  IN
    \* If either term is uninitialized, compare versions only
    IF t1 = UninitTerm \/ t2 = UninitTerm THEN
      v1 = v2
    ELSE
      t1 = t2 /\ v1 = v2

ConfigVersionTermLte(cvt1, cvt2) ==
  ConfigVersionTermLess(cvt1, cvt2) \/ ConfigVersionTermEq(cvt1, cvt2)

(* Quorum check sufficient? (Family 3, lines 324-331)
   Sufficiency requires majority of voters *)
QuorumSufficient(s) ==
  LET voters == {ss \in Server : TRUE}  \* Simplified: all servers are voters
      needed == (Cardinality(voters) \div 2) + 1
  IN
    Cardinality(voterResponses[s]) >= needed

(* Is a force reconfig? Term = UninitTerm *)
IsForceReconfig(s) ==
  configTerm[s] = UninitTerm

(* ====== Init ====== *)

Init ==
  /\ currentTerm = [s \in Server |-> 0]
  /\ configTerm = [s \in Server |-> 0]
  /\ configVersion = [s \in Server |-> 1]
  /\ configState = [s \in Server |-> [term |-> 0, version |-> 1]]
  /\ persistedConfigTerm = [s \in Server |-> 0]
  /\ persistedConfigVersion = [s \in Server |-> 1]
  /\ pendingConfigWrite = [s \in Server |-> FALSE]
  /\ quorumState = [s \in Server |-> "idle"]
  /\ voterResponses = [s \in Server |-> {}]
  /\ respondCount = [s \in Server |-> 0]
  /\ committedOptimeInConfig = [s \in Server |-> 0]
  /\ configStateEnum = [s \in Server |-> "kConfigSteady"]

(* ====== Actions ====== *)

(* ---- Family 1: Config Version/Term Comparison ----
   Model the asymmetric comparison as a separate action to expose races *)

CompareConfigVersionAndTerm(s, other) ==
  \* Compare s's current config with other's config
  \* (Lines 91-99 in repl_set_config.h)
  LET currConfig == [term |->configTerm[s], version |->configVersion[s]]
      otherConfig == [term |->configTerm[other], version |->configVersion[other]]
      isLess == ConfigVersionTermLess(currConfig, otherConfig)
  IN
    IF isLess THEN
      \* s should fetch newer config from other
      /\ UNCHANGED vars
    ELSE
      \* s keeps its config or both are equivalent
      /\ UNCHANGED vars

(* ---- Family 2: Multi-Step Config Commit ----
   Split config installation into atomic phases to expose crash windows *)

(* Phase 1: Initiate reconfig (line 3626)
   Set state to kConfigReconfiguring *)
DoReplSetReconfig_Initiate(s, newVersion, newTerm) ==
  /\ configStateEnum[s] = "kConfigSteady"
  /\ newVersion > configVersion[s]
  /\ configStateEnum' = [configStateEnum EXCEPT ![s] = "kConfigReconfiguring"]
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
       quorumState, voterResponses, respondCount, committedOptimeInConfig >>

(* Phase 2: Quorum check (lines 3830-3840)
   Check if quorum agrees to new config *)
QuorumChecker_Start(s) ==
  /\ configStateEnum[s] = "kConfigReconfiguring"
  /\ quorumState[s] = "idle"
  /\ quorumState' = [quorumState EXCEPT ![s] = "in_progress"]
  /\ voterResponses' = [voterResponses EXCEPT ![s] = {s}]  \* Count self as responded
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
       respondCount, committedOptimeInConfig, configStateEnum >>

(* Process response from voter (lines 238-322)
   Accumulate responses from remote members *)
QuorumChecker_ProcessResponse(s, voter) ==
  /\ quorumState[s] = "in_progress"
  /\ voter \notin voterResponses[s]
  /\ voter # s
  /\ voterResponses' = [voterResponses EXCEPT ![s] = voterResponses[s] \cup {voter}]
  /\ IF QuorumSufficient(s) THEN
       quorumState' = [quorumState EXCEPT ![s] = "succeeded"]
     ELSE
       quorumState' = quorumState
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
       respondCount, committedOptimeInConfig, configStateEnum >>

(* Phase 3: Persist config to disk (lines 3842-3878)
   Write config and term to durable storage with journal flush *)
DoReplSetReconfig_Persist(s, newVersion, newTerm) ==
  /\ quorumState[s] = "succeeded"
  /\ configStateEnum[s] = "kConfigReconfiguring"
  /\ ~pendingConfigWrite[s]
  /\ pendingConfigWrite' = [pendingConfigWrite EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       persistedConfigTerm, persistedConfigVersion,
       quorumState, voterResponses, respondCount, committedOptimeInConfig,
       configStateEnum >>

(* Complete persistence with journal flush (line 3878)
   Transition: durable storage updated *)
JournalFlush_Complete(s) ==
  /\ pendingConfigWrite[s]
  /\ quorumState[s] = "succeeded"
  /\ persistedConfigVersion' = [persistedConfigVersion EXCEPT ![s] = configVersion[s]]
  /\ persistedConfigTerm' = [persistedConfigTerm EXCEPT ![s] = configTerm[s]]
  /\ pendingConfigWrite' = [pendingConfigWrite EXCEPT ![s] = FALSE]
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       quorumState, voterResponses, respondCount, committedOptimeInConfig,
       configStateEnum >>

(* Phase 4: Install config in-memory (lines 3881-3882)
   Call _finishReplSetReconfig to update in-memory state *)
DoReplSetReconfig_FinishInstall(s, newVersion, newTerm) ==
  /\ configStateEnum[s] = "kConfigReconfiguring"
  /\ ~pendingConfigWrite[s]  \* Persistence must be complete
  /\ configTerm' = [configTerm EXCEPT ![s] = newTerm]
  /\ configVersion' = [configVersion EXCEPT ![s] = newVersion]
  /\ configState' = [configState EXCEPT ![s] = [term |->newTerm, version |->newVersion]]
  /\ configStateEnum' = [configStateEnum EXCEPT ![s] = "kConfigSteady"]
  /\ quorumState' = [quorumState EXCEPT ![s] = "idle"]
  /\ voterResponses' = [voterResponses EXCEPT ![s] = {}]
  /\ UNCHANGED <<
       currentTerm, persistedConfigTerm, persistedConfigVersion,
       respondCount, committedOptimeInConfig, pendingConfigWrite >>

(* ---- Family 2: Crash and Recovery ----
   After crash, in-memory state reverts to persisted state *)

Crash_RecoverConfigFromDisk(s) ==
  \* Crash: revert in-memory config to persisted config (lines 3626-3631 scope guard)
  /\ configTerm' = [configTerm EXCEPT ![s] = persistedConfigTerm[s]]
  /\ configVersion' = [configVersion EXCEPT ![s] = persistedConfigVersion[s]]
  /\ configState' = [configState EXCEPT ![s] =
       [term |->persistedConfigTerm[s], version |->persistedConfigVersion[s]]]
  /\ configStateEnum' = [configStateEnum EXCEPT ![s] = "kConfigSteady"]
  /\ quorumState' = [quorumState EXCEPT ![s] = "idle"]
  /\ voterResponses' = [voterResponses EXCEPT ![s] = {}]
  /\ pendingConfigWrite' = [pendingConfigWrite EXCEPT ![s] = FALSE]
  /\ UNCHANGED <<
       currentTerm, persistedConfigTerm, persistedConfigVersion,
       respondCount, committedOptimeInConfig >>

(* ---- Family 3: Quorum Response Timeout ----
   Quorum check can fail if responses don't arrive *)

QuorumChecker_Timeout(s) ==
  /\ quorumState[s] = "in_progress"
  /\ ~QuorumSufficient(s)
  /\ quorumState' = [quorumState EXCEPT ![s] = "failed"]
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
       voterResponses, respondCount, committedOptimeInConfig, configStateEnum >>

(* ---- Family 4: Config State Synchronization ----
   Heartbeat process: send current config to other servers *)

Heartbeat_SendCurrentConfig(s, dest) ==
  \* Send s's current config to dest
  \* Expose potential races where dest sees s's config/term inconsistency
  /\ configTerm[s] # UninitTerm  \* Only send initialized configs
  /\ dest # s
  /\ UNCHANGED vars

(* ---- Family 5: Commitment Safety Across Config Changes ----
   Ensure oplog entries committed in previous config remain committed *)

AdvanceCommittedOptime(s, optime) ==
  /\ optime > committedOptimeInConfig[s]
  /\ committedOptimeInConfig' = [committedOptimeInConfig EXCEPT ![s] = optime]
  /\ UNCHANGED <<
       currentTerm, configTerm, configVersion, configState,
       persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
       quorumState, voterResponses, respondCount, configStateEnum >>

(* ---- Fault Injection ----
   Fault actions for model checking *)

(* Disk write block: persist operation hangs *)
DiskWriteBlock(s) ==
  /\ pendingConfigWrite[s] = TRUE
  /\ UNCHANGED vars

(* Message loss: responses never arrive *)
ResponseLoss(s, voter) ==
  /\ quorumState[s] = "in_progress"
  /\ voter \notin voterResponses[s]
  /\ UNCHANGED vars

(* ====== Next State ====== *)

Next ==
  \E s \in Server :
    \/ CompareConfigVersionAndTerm(s, (CHOOSE other \in Server : other # s))
    \/ \E newVersion \in Nat, newTerm \in {UninitTerm} \cup Nat :
         /\ newVersion > configVersion[s]
         /\ DoReplSetReconfig_Initiate(s, newVersion, newTerm)
    \/ QuorumChecker_Start(s)
    \/ QuorumChecker_Timeout(s)
    \/ \E voter \in Server : QuorumChecker_ProcessResponse(s, voter)
    \/ \E newVersion \in Nat, newTerm \in {UninitTerm} \cup Nat :
         DoReplSetReconfig_Persist(s, newVersion, newTerm)
    \/ JournalFlush_Complete(s)
    \/ \E newVersion \in Nat, newTerm \in {UninitTerm} \cup Nat :
         DoReplSetReconfig_FinishInstall(s, newVersion, newTerm)
    \/ Crash_RecoverConfigFromDisk(s)
    \/ \E dest \in Server : Heartbeat_SendCurrentConfig(s, dest)
    \/ \E optime \in Nat : AdvanceCommittedOptime(s, optime)
    \/ DiskWriteBlock(s)
    \/ \E voter \in Server : ResponseLoss(s, voter)

(* ====== Invariants ====== *)

(* Standard protocol invariants *)
MCTypeOK ==
  /\ currentTerm \in [Server -> 0..20]
  /\ configTerm \in [Server -> 0..20]
  /\ configVersion \in [Server -> 0..20]
  /\ persistedConfigTerm \in [Server -> 0..20]
  /\ persistedConfigVersion \in [Server -> 0..20]
  /\ pendingConfigWrite \in [Server -> BOOLEAN]
  /\ quorumState \in [Server -> QuorumCheckState]
  /\ voterResponses \in [Server -> SUBSET Server]
  /\ respondCount \in [Server -> 0..20]
  /\ committedOptimeInConfig \in [Server -> 0..20]
  /\ configStateEnum \in [Server -> STRING]

(* ---- Family 1: Config Version/Term Transitivity ----
   Invariant: Config comparison is transitive *)
ConfigVersionTermTransitivity ==
  \A s, s1, s2 \in Server :
    LET c0 == [term |->configTerm[s], version |->configVersion[s]]
        c1 == [term |->configTerm[s1], version |->configVersion[s1]]
        c2 == [term |->configTerm[s2], version |->configVersion[s2]]
    IN
      (ConfigVersionTermLess(c0, c1) /\ ConfigVersionTermLess(c1, c2)) =>
        ConfigVersionTermLess(c0, c2)

(* ---- Family 1: Config Monotonicity ----
   Invariant: A node never downgrades its config *)
ConfigVersionMonotonicity ==
  \A s \in Server :
    LET newConfig == [term |->configTerm[s], version |->configVersion[s]]
        oldConfig == [term |->persistedConfigTerm[s], version |->persistedConfigVersion[s]]
    IN
      \* In-memory config should be >= persisted config
      ConfigVersionTermLte(oldConfig, newConfig)

(* ---- Family 2: Persistent Config Validity ----
   Invariant: Persisted config version >= in-memory version after restart *)
PersistentConfigValidity ==
  \A s \in Server :
    LET inMemory == [term |->configTerm[s], version |->configVersion[s]]
        onDisk == [term |->persistedConfigTerm[s], version |->persistedConfigVersion[s]]
    IN
      ConfigVersionTermLte(inMemory, onDisk) \/
      (~pendingConfigWrite[s] /\ ConfigVersionTermEq(inMemory, onDisk))

(* ---- Family 3: Quorum Based on Actual Responses ----
   Invariant: Quorum success only if sufficient responses received *)
QuorumBasedOnActualResponses ==
  \A s \in Server :
    (quorumState[s] = "succeeded") =>
      QuorumSufficient(s)

(* ---- Family 4: Config State Consistency ----
   Invariant: Config state tracking is consistent *)
ConfigStateConsistency ==
  \A s \in Server :
    (configState[s].term = UninitTerm /\ configState[s].version = 1) \/
    (configState[s].term = configTerm[s] /\ configState[s].version = configVersion[s])

(* ---- Family 5: Committed Entries Preserved ----
   Invariant: Committed entries don't disappear after config change *)
CommittedEntriesPreserved ==
  \A s, s2 \in Server :
    (committedOptimeInConfig[s] > 0) =>
      (committedOptimeInConfig[s] <= committedOptimeInConfig[s2] \/
       committedOptimeInConfig[s2] = 0)

(* ---- Family 6: One Configuration in Transition ----
   Invariant: At most one node reconfiguring at a time *)
OneConfigurationInTransition ==
  Cardinality({s \in Server : configStateEnum[s] = "kConfigReconfiguring"}) <= 1

(* ---- Family 6: Config State Validity ----
   Invariant: Config state transitions are valid *)
ConfigStateValidity ==
  \A s \in Server :
    (configStateEnum[s] \in {"kConfigSteady", "kConfigReconfiguring", "kConfigInitiating"})

=============================================================================
