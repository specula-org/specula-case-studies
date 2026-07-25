---------------------------- MODULE MC ----------------------------
(* MC wrapper with counter-bounded fault injection *)

EXTENDS base, Naturals

(* ====== MC Constants ====== *)

CONSTANT
  MaxCrashLimit,
  MaxQuorumCheckLimit,
  MaxDiskBlockLimit,
  MaxResponseLossLimit,
  MaxConfigChangeLimit

(* ====== MC Counter Variables ====== *)

VARIABLE
  crashCount,
  quorumCheckCount,
  diskBlockCount,
  responseLossCount,
  configChangeCount

faultVars == <<
  crashCount, quorumCheckCount, diskBlockCount, responseLossCount, configChangeCount >>

(* ====== Constrained Fault Wrappers ====== *)

(* Crash with bounded counter *)
MCCrash(s) ==
  /\ crashCount < MaxCrashLimit
  /\ Crash_RecoverConfigFromDisk(s)
  /\ crashCount' = crashCount + 1
  /\ UNCHANGED <<quorumCheckCount, diskBlockCount, responseLossCount, configChangeCount>>

(* Quorum check with bounded counter *)
MCQuorumChecker_Timeout(s) ==
  /\ quorumCheckCount < MaxQuorumCheckLimit
  /\ QuorumChecker_Timeout(s)
  /\ quorumCheckCount' = quorumCheckCount + 1
  /\ UNCHANGED <<crashCount, diskBlockCount, responseLossCount, configChangeCount>>

(* Disk block with bounded counter *)
MCDiskWriteBlock(s) ==
  /\ diskBlockCount < MaxDiskBlockLimit
  /\ DiskWriteBlock(s)
  /\ diskBlockCount' = diskBlockCount + 1
  /\ UNCHANGED <<crashCount, quorumCheckCount, responseLossCount, configChangeCount>>

(* Response loss with bounded counter *)
MCResponseLoss(s, voter) ==
  /\ responseLossCount < MaxResponseLossLimit
  /\ ResponseLoss(s, voter)
  /\ responseLossCount' = responseLossCount + 1
  /\ UNCHANGED <<crashCount, quorumCheckCount, diskBlockCount, configChangeCount>>

(* Config change with bounded counter *)
MCDoReplSetReconfig_Initiate(s, newVersion, newTerm) ==
  /\ configChangeCount < MaxConfigChangeLimit
  /\ DoReplSetReconfig_Initiate(s, newVersion, newTerm)
  /\ configChangeCount' = configChangeCount + 1
  /\ UNCHANGED <<crashCount, quorumCheckCount, diskBlockCount, responseLossCount>>

(* ====== Reactive (Unbounded) Actions ====== *)

(* These actions are reactive to faults and should not be bounded *)

MCCompareConfigVersionAndTerm(s, other) ==
  /\ CompareConfigVersionAndTerm(s, other)
  /\ UNCHANGED faultVars

MCQuorumChecker_Start(s) ==
  /\ QuorumChecker_Start(s)
  /\ UNCHANGED faultVars

MCQuorumChecker_ProcessResponse(s, voter) ==
  /\ QuorumChecker_ProcessResponse(s, voter)
  /\ UNCHANGED faultVars

MCDoReplSetReconfig_Persist(s, newVersion, newTerm) ==
  /\ DoReplSetReconfig_Persist(s, newVersion, newTerm)
  /\ UNCHANGED faultVars

MCJournalFlush_Complete(s) ==
  /\ JournalFlush_Complete(s)
  /\ UNCHANGED faultVars

MCDoReplSetReconfig_FinishInstall(s, newVersion, newTerm) ==
  /\ DoReplSetReconfig_FinishInstall(s, newVersion, newTerm)
  /\ UNCHANGED faultVars

MCHeartbeat_SendCurrentConfig(s, dest) ==
  /\ Heartbeat_SendCurrentConfig(s, dest)
  /\ UNCHANGED faultVars

MCAdvanceCommittedOptime(s, optime) ==
  /\ AdvanceCommittedOptime(s, optime)
  /\ UNCHANGED faultVars

(* ====== MC Init and Next ====== *)

MCInit ==
  /\ Init
  /\ crashCount = 0
  /\ quorumCheckCount = 0
  /\ diskBlockCount = 0
  /\ responseLossCount = 0
  /\ configChangeCount = 0

MCNext ==
  \E s \in Server :
    \/ MCCompareConfigVersionAndTerm(s, (CHOOSE other \in Server : other # s))
    \/ \E newVersion \in 0..20, newTerm \in 0..20 :
         MCDoReplSetReconfig_Initiate(s, newVersion, newTerm)
    \/ MCQuorumChecker_Start(s)
    \/ MCQuorumChecker_Timeout(s)
    \/ \E voter \in Server : MCQuorumChecker_ProcessResponse(s, voter)
    \/ \E newVersion \in 0..20, newTerm \in 0..20 :
         MCDoReplSetReconfig_Persist(s, newVersion, newTerm)
    \/ MCJournalFlush_Complete(s)
    \/ \E newVersion \in 0..20, newTerm \in 0..20 :
         MCDoReplSetReconfig_FinishInstall(s, newVersion, newTerm)
    \/ MCCrash(s)
    \/ \E dest \in Server : MCHeartbeat_SendCurrentConfig(s, dest)
    \/ \E optime \in Nat : MCAdvanceCommittedOptime(s, optime)
    \/ MCDiskWriteBlock(s)
    \/ \E voter \in Server : MCResponseLoss(s, voter)

(* ====== MC Symmetry ====== *)

Symmetry == Permutations(Server)

(* ====== MC View (exclude counters from symmetry) ====== *)

MCView ==
  <<
    currentTerm, configTerm, configVersion, configState,
    persistedConfigTerm, persistedConfigVersion, pendingConfigWrite,
    quorumState, voterResponses, respondCount,
    committedOptimeInConfig, configStateEnum
  >>

(* ====== MC Invariants ====== *)

(* Base invariants *)
MCTypeOK_MC == MCTypeOK

ConfigVersionTermTransitivity_MC == ConfigVersionTermTransitivity

ConfigVersionMonotonicity_MC == ConfigVersionMonotonicity

PersistentConfigValidity_MC == PersistentConfigValidity

QuorumBasedOnActualResponses_MC == QuorumBasedOnActualResponses

ConfigStateConsistency_MC == ConfigStateConsistency

(* Commented out: extension invariants for bug-family hunting *)
\* CommittedEntriesPreserved_MC == CommittedEntriesPreserved
\* OneConfigurationInTransition_MC == OneConfigurationInTransition
\* ConfigStateValidity_MC == ConfigStateValidity

(* ====== Temporal Properties ====== *)

(* Liveness: config eventually installs *)
EventuallyInstalled ==
  <>(\E s \in Server : configStateEnum[s] = "kConfigSteady" /\
                        configTerm[s] # UninitTerm /\ configVersion[s] > 1)

=============================================================================
