------------------------------ MODULE base ------------------------------
(**************************************************************************)
(* SONiC warm-reboot orchestration                                       *)
(*                                                                        *)
(* Category A: distributed / message-passing.  Containers and daemons     *)
(* coordinate through Redis, notification channels, files, signals, and   *)
(* systemd.  Every state extension below is motivated by one of the six    *)
(* scenarios in modeling-brief.md.                                        *)
(**************************************************************************)

EXTENDS Integers, Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Owners,                 \* Scenario 1: competing CLI/DBus callers
    WarmRequest, FastRequest,
    Asics,                  \* Scenario 3: independently stopped namespaces
    OrchProducer, RingProducer, FdbProducer,
    Components, FpmComponent,
    Routes,                 \* Scenario 6: abstract restored/refreshed routes
    Vids, Rids,             \* Scenario 5: symmetric identity graphs
    MaxQueue,
    MaxApplyOps,
    UseEpochCAS,            \* MC-1: proposed owner/epoch acquisition
    ReplyAfterLocalDrain,   \* MC-2: proposed READY reorder
    UseDurableApplyJournal, \* MC-3: proposed APPLY journal
    KnownVid, KnownRid,
    UseKnownIdentityLabels  \* MC-6: label known special objects

RequestKinds == {WarmRequest, FastRequest}
ProducerKinds == {OrchProducer, RingProducer, FdbProducer}
Producers == Asics \X ProducerKinds
ApplyOps == 1..MaxApplyOps

NoEpoch == -1
NoOwner == "no-owner"
NoAsic == "no-asic"
NoRid == "no-rid"
NoVid == "no-vid"

PhaseNames ==
    {"idle", "requested", "checked", "flags-published", "cancelled",
     "freeze-acked", "irreversible", "completed", "cold"}
ProducerStates == {"running", "fenced"}
FreezeResults == {"pending", "ready", "ignored-failure"}
PostReadySteps ==
    {"none", "check-passed", "ready-sent", "ring-drained",
     "aging-disabled", "learning-disabled", "pipeline-flushed",
     "ready-after-flush", "heartbeat"}
LocalModes == {"unknown", "warm", "cold"}
ShutdownStatuses == {"pending", "succeeded", "failed", "lost"}
SnapshotStages == {"idle", "saved", "copied", "loaded", "renamed"}
DecisionStates == {"undecided", "warm", "cold"}
ApplyStates ==
    {"idle", "matching", "executing", "remove-db", "remove-temp",
     "write-db", "delete-v2r", "delete-r2v", "write-maps", "verify",
     "committed", "crashed", "aborted"}
RecoveryModes == {"none", "resume", "cold", "unsafe-warm"}
JournalStates == {"none", "intent", "dirty", "committed"}
MapStages == {"stable", "deleting-v2r", "deleting-r2v", "writing", "complete"}
TerminalStates == {"initial", "restored", "reconciled", "failed"}
AttemptOutcomes == {"none", "pending", "rejected", "warm", "cold"}

ASSUME
    /\ IsFiniteSet(Owners) /\ Owners /= {}
    /\ IsFiniteSet(Asics) /\ Asics /= {}
    /\ IsFiniteSet(Components) /\ Components /= {}
    /\ FpmComponent \in Components
    /\ IsFiniteSet(Routes) /\ Routes /= {}
    /\ IsFiniteSet(Vids) /\ Vids /= {}
    /\ IsFiniteSet(Rids) /\ Rids /= {}
    /\ Cardinality(Vids) = Cardinality(Rids)
    /\ MaxQueue \in Nat /\ MaxQueue > 0
    /\ MaxApplyOps \in Nat /\ MaxApplyOps > 0
    /\ UseEpochCAS \in BOOLEAN
    /\ ReplyAfterLocalDrain \in BOOLEAN
    /\ UseDurableApplyJournal \in BOOLEAN
    /\ KnownVid \in Vids
    /\ KnownRid \in Rids
    /\ UseKnownIdentityLabels \in BOOLEAN

(**************************************************************************)
(* Variables grouped by scenario.                                        *)
(**************************************************************************)

VARIABLES
    \* Scenario 1 -- RebootEpoch
    epoch, owner, requestKind, phase, cancelled, flags, cleanupOwner,
    checked, admitted, attemptEpoch, attemptOutcome, irreversibleStarted,

    \* Scenario 2 -- ProducerFence
    producerState, inflight, queue, readySent, readyConsumed, freezeResult,
    postReadyStep, quiescent,

    \* Scenario 3 -- ParticipantSnapshot
    writerStopped, localMode, shutdownStatus, snapshotEpoch, snapshotValid,
    snapshotPresent, snapshotConsumed, snapshotStage, globalDecision,
    selectedEpoch,

    \* Scenario 4 -- ApplyJournal
    initEpoch, plannedOps, opCursor, hardwareView, dbView, applyEpoch,
    applyAsic, applyState, recoveryMode, applyDirty, journalState,

    \* Scenario 5 -- IdentityGraph (also the split map publication in S4)
    stableLabels, candidates, matching, vidToRid, ridToVid, mapStage,
    mapPending, mapHalf,

    \* Scenario 6 -- CompletionBarrier
    inputComplete, timerExpired, cachedOld, refreshedNew, outputBuffered,
    outputPublished, derivedOutputs, terminal, flagsCleared,
    finalizerTimedOut

epochVars ==
    <<epoch, owner, requestKind, phase, cancelled, flags, cleanupOwner,
      checked, admitted, attemptEpoch, attemptOutcome, irreversibleStarted>>

producerVars ==
    <<producerState, inflight, queue, readySent, readyConsumed, freezeResult,
      postReadyStep, quiescent>>

snapshotVars ==
    <<writerStopped, localMode, shutdownStatus, snapshotEpoch, snapshotValid,
      snapshotPresent, snapshotConsumed, snapshotStage, globalDecision,
      selectedEpoch>>

applyVars ==
    <<initEpoch, plannedOps, opCursor, hardwareView, dbView, applyEpoch,
      applyAsic, applyState, recoveryMode, applyDirty, journalState>>

identityVars ==
    <<stableLabels, candidates, matching, vidToRid, ridToVid, mapStage,
      mapPending, mapHalf>>

completionVars ==
    <<inputComplete, timerExpired, cachedOld, refreshedNew, outputBuffered,
      outputPublished, derivedOutputs, terminal, flagsCleared,
      finalizerTimedOut>>

vars ==
    <<epoch, owner, requestKind, phase, cancelled, flags, cleanupOwner,
      checked, admitted, attemptEpoch, attemptOutcome, irreversibleStarted,
      producerState, inflight, queue, readySent, readyConsumed, freezeResult,
      postReadyStep, quiescent,
      writerStopped, localMode, shutdownStatus, snapshotEpoch, snapshotValid,
      snapshotPresent, snapshotConsumed, snapshotStage, globalDecision,
      selectedEpoch,
      initEpoch, plannedOps, opCursor, hardwareView, dbView, applyEpoch,
      applyAsic, applyState, recoveryMode, applyDirty, journalState,
      stableLabels, candidates, matching, vidToRid, ridToVid, mapStage,
      mapPending, mapHalf,
      inputComplete, timerExpired, cachedOld, refreshedNew, outputBuffered,
      outputPublished, derivedOutputs, terminal, flagsCleared,
      finalizerTimedOut>>

(**************************************************************************)
(* Helpers.                                                               *)
(**************************************************************************)

CurrentEpoch ==
    IF owner \in Owners THEN attemptEpoch[owner] ELSE epoch

AllNamespaceProducers(a) == {p \in Producers : p[1] = a}

ProducerIsQuiescent(p) ==
    /\ producerState[p] = "fenced"
    /\ queue[p] = 0
    /\ ~inflight[p]
    /\ quiescent[p]

NamespaceQuiescent(a) ==
    \A p \in AllNamespaceProducers(a) : ProducerIsQuiescent(p)

ActiveIrreversibleOwners ==
    {c \in Owners : irreversibleStarted[c] /\ attemptOutcome[c] = "pending"}

IdentityMapsReciprocal ==
    /\ \A v \in Vids :
          vidToRid[v] \in Rids => ridToVid[vidToRid[v]] = v
    /\ \A r \in Rids :
          ridToVid[r] \in Vids => vidToRid[ridToVid[r]] = r

IdentityMapsTotal ==
    /\ \A v \in Vids : vidToRid[v] \in Rids
    /\ \A r \in Rids : ridToVid[r] \in Vids

MatchingComplete ==
    /\ \A v \in Vids : matching[v] \in Rids
    /\ \A r \in Rids : \E v \in Vids : matching[v] = r

InverseMatching ==
    [r \in Rids |-> CHOOSE v \in Vids : matching[v] = r]

AllRequiredTerminal ==
    \A comp \in Components : terminal[comp] \in {"reconciled", "failed"}

OutputsDurable ==
    /\ outputBuffered = {}
    /\ derivedOutputs \subseteq outputPublished

(**************************************************************************)
(* Initial state.                                                         *)
(**************************************************************************)

Init ==
    \* Reboot request state starts without an owner or published flag.
    \* src/sonic-utilities/scripts/fast-reboot:922-977 (Scenario 1)
    /\ epoch = 0
    /\ owner = NoOwner
    /\ requestKind = [c \in Owners |-> "none"]
    /\ phase = [c \in Owners |-> "idle"]
    /\ cancelled = [c \in Owners |-> FALSE]
    /\ flags = [warm |-> FALSE, fast |-> FALSE, epoch |-> NoEpoch]
    /\ cleanupOwner = NoOwner
    /\ checked = [c \in Owners |-> FALSE]
    /\ admitted = [c \in Owners |-> FALSE]
    /\ attemptEpoch = [c \in Owners |-> NoEpoch]
    /\ attemptOutcome = [c \in Owners |-> "none"]
    /\ irreversibleStarted = [c \in Owners |-> FALSE]

    \* Producers initially accept work; no global fence exists.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1170-1187 (Scenario 2)
    /\ producerState = [p \in Producers |-> "running"]
    /\ inflight = [p \in Producers |-> FALSE]
    /\ queue = [p \in Producers |-> 0]
    /\ readySent = [a \in Asics |-> FALSE]
    /\ readyConsumed = [a \in Asics |-> FALSE]
    /\ freezeResult = [a \in Asics |-> "pending"]
    /\ postReadyStep = [a \in Asics |-> "none"]
    /\ quiescent = [p \in Producers |-> FALSE]

    \* No participant outcome or checkpoint has yet been aggregated.
    \* src/sonic-utilities/scripts/fast-reboot:1206-1219 (Scenario 3)
    /\ writerStopped = [a \in Asics |-> FALSE]
    /\ localMode = [a \in Asics |-> "unknown"]
    /\ shutdownStatus = [a \in Asics |-> "pending"]
    /\ snapshotEpoch = [a \in Asics |-> NoEpoch]
    /\ snapshotValid = [a \in Asics |-> FALSE]
    /\ snapshotPresent = [a \in Asics |-> FALSE]
    /\ snapshotConsumed = [a \in Asics |-> FALSE]
    /\ snapshotStage = [a \in Asics |-> "idle"]
    /\ globalDecision = "undecided"
    /\ selectedEpoch = NoEpoch

    \* Current hardware and DB abstractly agree on the pre-APPLY view ({}).
    \* src/sonic-sairedis/syncd/Syncd.cpp:5716-5757 (Scenario 4)
    /\ initEpoch = [a \in Asics |-> NoEpoch]
    /\ plannedOps = {}
    /\ opCursor = 0
    /\ hardwareView = {}
    /\ dbView = {}
    /\ applyEpoch = NoEpoch
    /\ applyAsic = NoAsic
    /\ applyState = "idle"
    /\ recoveryMode = "none"
    /\ applyDirty = FALSE
    /\ journalState = "none"

    \* The existing Redis maps begin reciprocal; matching is rebuilt per APPLY.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:664-679 (Scenarios 4-5)
    /\ stableLabels =
          [x \in Vids \cup Rids |->
              IF UseKnownIdentityLabels /\ x \in {KnownVid, KnownRid}
              THEN "known-special" ELSE "unlabelled"]
    /\ candidates = {}
    /\ matching = [v \in Vids |-> NoRid]
    /\ vidToRid \in [Vids -> Rids]
    /\ \A v1, v2 \in Vids : vidToRid[v1] = vidToRid[v2] => v1 = v2
    /\ ridToVid = [r \in Rids |-> CHOOSE v \in Vids : vidToRid[v] = r]
    /\ mapStage = "stable"
    /\ mapPending = {}
    /\ mapHalf = NoVid

    \* Restoration and reconciliation have not started.
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:102-133 (Scenario 6)
    /\ inputComplete = FALSE
    /\ timerExpired = FALSE
    /\ cachedOld = {}
    /\ refreshedNew = {}
    /\ outputBuffered = {}
    /\ outputPublished = {}
    /\ derivedOutputs = {}
    /\ terminal = [comp \in Components |-> "initial"]
    /\ flagsCleared = [comp \in Components |-> FALSE]
    /\ finalizerTimedOut = FALSE

(**************************************************************************)
(* Scenario 1 actions: admission, publication, cancellation, ownership.   *)
(**************************************************************************)

FastReboot_Request(c, kind) ==
    \* CLI/DBus entry parses a request before reading the warm flags.
    \* src/sonic-utilities/scripts/fast-reboot:922-973
    /\ c \in Owners
    /\ kind \in RequestKinds
    /\ phase[c] = "idle"
    \* The caller-local request exists independently of global Redis state.
    \* src/sonic-utilities/scripts/fast-reboot:949-975
    /\ requestKind' = [requestKind EXCEPT ![c] = kind]
    /\ phase' = [phase EXCEPT ![c] = "requested"]
    /\ attemptOutcome' = [attemptOutcome EXCEPT ![c] = "pending"]
    /\ UNCHANGED <<epoch, owner, cancelled, flags, cleanupOwner, checked,
                    admitted, attemptEpoch, irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

CheckWarmRestartInProgress_Admit(c) ==
    \* Each utility invocation independently scans flags; this is not a CAS.
    \* src/sonic-utilities/scripts/fast-reboot:883-894
    /\ c \in Owners
    /\ phase[c] = "requested"
    /\ ~flags.warm /\ ~flags.fast
    \* Returning from the check does not reserve the reboot epoch.
    \* src/sonic-utilities/scripts/fast-reboot:973-977,980-992
    /\ checked' = [checked EXCEPT ![c] = TRUE]
    /\ phase' = [phase EXCEPT ![c] = "checked"]
    /\ UNCHANGED <<epoch, owner, requestKind, cancelled, flags, cleanupOwner,
                    admitted, attemptEpoch, attemptOutcome,
                    irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

CheckWarmRestartInProgress_Reject(c) ==
    \* A caller that observes an enabled flag exits unless FORCE is used.
    \* src/sonic-utilities/scripts/fast-reboot:884-891
    /\ c \in Owners
    /\ phase[c] = "requested"
    /\ (flags.warm \/ flags.fast)
    \* The rejected caller never owns or advances the active attempt.
    \* src/sonic-utilities/scripts/fast-reboot:889-890
    /\ phase' = [phase EXCEPT ![c] = "completed"]
    /\ attemptOutcome' = [attemptOutcome EXCEPT ![c] = "rejected"]
    /\ UNCHANGED <<epoch, owner, requestKind, cancelled, flags, cleanupOwner,
                    checked, admitted, attemptEpoch, irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

EnableWarmRestart(c) ==
    \* Flag publication occurs after the unreserved read and is a separate DB call.
    \* src/sonic-utilities/scripts/fast-reboot:896-898,973-992
    /\ c \in Owners
    /\ phase[c] = "checked"
    /\ checked[c]
    /\ (~UseEpochCAS \/ owner = NoOwner)
    \* A second checked caller may overwrite owner/epoch and still leave the
    \* first process alive; the implementation stores no owner in Redis.
    \* src/sonic-utilities/scripts/fast-reboot:975-977,990-992
    /\ epoch' = epoch + 1
    /\ owner' = c
    /\ flags' = [warm |-> TRUE,
                  fast |-> requestKind[c] = FastRequest,
                  epoch |-> epoch + 1]
    /\ phase' = [phase EXCEPT ![c] = "flags-published"]
    /\ checked' = [checked EXCEPT ![c] = FALSE]
    /\ admitted' = [admitted EXCEPT ![c] = TRUE]
    /\ attemptEpoch' = [attemptEpoch EXCEPT ![c] = epoch + 1]
    /\ attemptOutcome' = [attemptOutcome EXCEPT ![c] = "pending"]
    /\ cancelled' = [cancelled EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<requestKind, cleanupOwner, irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

ClearBoot(c) ==
    \* EXIT/signal cleanup is not guarded by an epoch or owner comparison.
    \* src/sonic-utilities/scripts/fast-reboot:341-370,975-996
    /\ c \in Owners
    /\ admitted[c]
    /\ attemptOutcome[c] = "pending"
    /\ phase[c] \in {"flags-published", "freeze-acked", "cancelled"}
    \* Cleanup disables global warm/fast flags and records only the process
    \* that happened to run it, not the owner whose state it erased.
    \* src/sonic-utilities/scripts/fast-reboot:354-369
    /\ cleanupOwner' = c
    /\ owner' = IF UseEpochCAS /\ owner = c THEN NoOwner ELSE owner
    /\ flags' = [flags EXCEPT !.warm = FALSE, !.fast = FALSE,
                              !.epoch = NoEpoch]
    /\ cancelled' = [cancelled EXCEPT ![c] = TRUE]
    /\ phase' = [phase EXCEPT ![c] = "cancelled"]
    \* The same cleanup renames every namespace dump it can find.
    \* src/sonic-utilities/scripts/fast-reboot:358-364
    /\ snapshotPresent' =
          [a \in Asics |->
              IF snapshotPresent[a] /\ snapshotEpoch[a] = flags.epoch
              THEN FALSE ELSE snapshotPresent[a]]
    /\ snapshotValid' =
          [a \in Asics |->
              IF snapshotEpoch[a] = flags.epoch
              THEN FALSE ELSE snapshotValid[a]]
    /\ snapshotStage' =
          [a \in Asics |->
              IF snapshotEpoch[a] = flags.epoch /\ snapshotStage[a] /= "idle"
              THEN "renamed" ELSE snapshotStage[a]]
    /\ UNCHANGED <<epoch, requestKind, checked, admitted,
                    attemptEpoch, attemptOutcome, irreversibleStarted>>
    /\ UNCHANGED <<producerVars, writerStopped, localMode, shutdownStatus,
                    snapshotEpoch, snapshotConsumed, globalDecision,
                    selectedEpoch, applyVars, identityVars, completionVars>>

FastReboot_ContinueAfterSignal(c) ==
    \* A trapped signal invokes clear_boot but the shell handler does not exit;
    \* execution can resume in the same caller before traps are disabled.
    \* src/sonic-utilities/scripts/fast-reboot:341-370,975-996,1179-1180
    /\ c \in Owners
    /\ phase[c] = "cancelled"
    /\ cancelled[c]
    \* Resumption does not republish the flags cleared by the handler.
    \* src/sonic-utilities/scripts/fast-reboot:975-1005
    /\ phase' = [phase EXCEPT ![c] = "flags-published"]
    /\ UNCHANGED <<epoch, owner, requestKind, cancelled, flags, cleanupOwner,
                    checked, admitted, attemptEpoch, attemptOutcome,
                    irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

FastReboot_PauseOrchagentComplete(c) ==
    \* Per-ASIC pause jobs are aggregated after each restart-check invocation.
    \* src/sonic-utilities/scripts/fast-reboot:1130-1156
    /\ c \in Owners
    /\ owner = c
    /\ phase[c] = "flags-published"
    /\ \A a \in Asics : freezeResult[a] \in {"ready", "ignored-failure"}
    \* FORCE permits an ignored failure to be treated as completion.
    \* src/sonic-utilities/scripts/fast-reboot:1137-1146,1149-1155
    /\ phase' = [phase EXCEPT ![c] = "freeze-acked"]
    /\ UNCHANGED <<epoch, owner, requestKind, cancelled, flags, cleanupOwner,
                    checked, admitted, attemptEpoch, attemptOutcome,
                    irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

FastReboot_BeginIrreversibleWork(c) ==
    \* The script declares the no-rollback point after pause and before stops.
    \* src/sonic-utilities/scripts/fast-reboot:1154-1165
    /\ c \in Owners
    /\ phase[c] = "freeze-acked"
    /\ attemptOutcome[c] = "pending"
    \* Traps are disabled only later, so cancellation state may survive into
    \* irreversible work after a signal handler returned.
    \* src/sonic-utilities/scripts/fast-reboot:1163-1180
    /\ irreversibleStarted' = [irreversibleStarted EXCEPT ![c] = TRUE]
    /\ phase' = [phase EXCEPT ![c] = "irreversible"]
    /\ UNCHANGED <<epoch, owner, requestKind, cancelled, flags, cleanupOwner,
                    checked, admitted, attemptEpoch, attemptOutcome>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

FastReboot_RecordOutcome(c) ==
    \* Completion consumes the independently aggregated warm/cold decision.
    \* src/sonic-utilities/scripts/fast-reboot:1206-1222;
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:299-302
    /\ c \in Owners
    /\ phase[c] = "irreversible"
    /\ globalDecision \in {"warm", "cold"}
    /\ (globalDecision = "cold" \/ applyState = "committed")
    \* The outcome is caller-local; no global transaction closes other callers.
    \* src/sonic-utilities/scripts/fast-reboot:1163-1165
    /\ attemptOutcome' = [attemptOutcome EXCEPT ![c] = globalDecision]
    /\ phase' = [phase EXCEPT ![c] =
                    IF globalDecision = "cold" THEN "cold" ELSE "completed"]
    /\ UNCHANGED <<epoch, owner, requestKind, cancelled, flags, cleanupOwner,
                    checked, admitted, attemptEpoch, irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

(**************************************************************************)
(* Scenario 2 actions: READY, post-reply work, producers, and freeze.      *)
(**************************************************************************)

Producer_Enqueue(p) ==
    \* Redis/ring/FDB producers remain independently scheduled while running.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1170-1179,1190-1199
    /\ p \in Producers
    /\ producerState[p] = "running"
    /\ queue[p] < MaxQueue
    \* An enqueue after READY recreates both queued and in-flight work.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1190-1201
    /\ queue' = [queue EXCEPT ![p] = @ + 1]
    /\ inflight' = [inflight EXCEPT ![p] = TRUE]
    /\ quiescent' = [quiescent EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<producerState, readySent, readyConsumed, freezeResult,
                    postReadyStep>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

Producer_DrainOne(p) ==
    \* Normal event-loop work drains independently of coordinator progress.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1170-1179
    /\ p \in Producers
    /\ queue[p] > 0
    \* A drained producer is globally quiescent only after it is also fenced.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1190-1221
    /\ queue' = [queue EXCEPT ![p] = @ - 1]
    /\ inflight' = [inflight EXCEPT ![p] = (queue[p] - 1) > 0]
    /\ quiescent' =
          [quiescent EXCEPT ![p] =
              (queue[p] - 1 = 0) /\ producerState[p] = "fenced"]
    /\ UNCHANGED <<producerState, readySent, readyConsumed, freezeResult,
                    postReadyStep>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_WarmRestartCheck(a) ==
    \* warmRestartCheck examines only orch pending tasks before replying.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1384-1413
    /\ a \in Asics
    /\ owner \in Owners
    /\ phase[owner] = "flags-published"
    /\ queue[<<a, OrchProducer>>] = 0
    /\ ~readySent[a]
    \* Actual code publishes READY here. MC-2 can instead defer it until the
    \* existing post-check drain/flush steps have completed.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1412-1414,1187-1221
    /\ readySent' =
          [readySent EXCEPT ![a] = IF ReplyAfterLocalDrain THEN FALSE ELSE TRUE]
    /\ postReadyStep' =
          [postReadyStep EXCEPT ![a] =
              IF ReplyAfterLocalDrain THEN "check-passed" ELSE "ready-sent"]
    /\ UNCHANGED <<producerState, inflight, queue, readyConsumed,
                    freezeResult, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchagentRestartCheck_ConsumeReply(a) ==
    \* The utility pops any READY reply; no request/epoch correlation is checked.
    \* src/sonic-swss/orchagent/orchagent_restart_check.cpp:108-140
    /\ a \in Asics
    /\ readySent[a]
    /\ ~readyConsumed[a]
    \* A consumed READY is reported as "frozen" although post-reply work remains.
    \* src/sonic-swss/orchagent/orchagent_restart_check.cpp:135-140
    /\ readyConsumed' = [readyConsumed EXCEPT ![a] = TRUE]
    /\ freezeResult' = [freezeResult EXCEPT ![a] = "ready"]
    /\ UNCHANGED <<producerState, inflight, queue, readySent,
                    postReadyStep, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

PauseOrchagent_IgnoreFailure(a) ==
    \* A failed restart-check is suppressed when FORCE is set (always on
    \* multi-ASIC after pause begins).
    \* src/sonic-utilities/scripts/fast-reboot:1137-1152
    /\ a \in Asics
    /\ owner \in Owners
    /\ phase[owner] = "flags-published"
    /\ freezeResult[a] = "pending"
    \* Coordinator progress records no producer fence on the failed ASIC.
    \* src/sonic-utilities/scripts/fast-reboot:1140-1146
    /\ freezeResult' = [freezeResult EXCEPT ![a] = "ignored-failure"]
    /\ readyConsumed' = [readyConsumed EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<producerState, inflight, queue, readySent,
                    postReadyStep, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_DrainRing(a) ==
    \* The route ring is drained only after warmRestartCheck returned READY.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1187-1199
    /\ a \in Asics
    /\ postReadyStep[a] \in {"check-passed", "ready-sent"}
    \* The worker may be drained, but it is not yet frozen against new work.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1190-1201
    /\ queue' = [queue EXCEPT ![<<a, RingProducer>>] = 0]
    /\ inflight' = [inflight EXCEPT ![<<a, RingProducer>>] = FALSE]
    /\ quiescent' = [quiescent EXCEPT ![<<a, RingProducer>>] = FALSE]
    /\ postReadyStep' = [postReadyStep EXCEPT ![a] = "ring-drained"]
    /\ UNCHANGED <<producerState, readySent, readyConsumed, freezeResult>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_SetAgingFDB(a) ==
    \* FDB aging is disabled after the ring drain and after READY.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1201-1205
    /\ a \in Asics
    /\ postReadyStep[a] = "ring-drained"
    \* Keep this observable boundary separate from bridge-port learning changes.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1204-1215
    /\ postReadyStep' = [postReadyStep EXCEPT ![a] = "aging-disabled"]
    /\ UNCHANGED <<producerState, inflight, queue, readySent, readyConsumed,
                    freezeResult, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_SetBridgePortLearningFDB(a) ==
    \* Each bridge port's FDB learning is disabled after aging is changed.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1207-1215
    /\ a \in Asics
    /\ postReadyStep[a] = "aging-disabled"
    \* The model abstracts the port loop as one namespace-level completion.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1208-1215
    /\ postReadyStep' = [postReadyStep EXCEPT ![a] = "learning-disabled"]
    /\ UNCHANGED <<producerState, inflight, queue, readySent, readyConsumed,
                    freezeResult, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_Flush(a) ==
    \* The sairedis Redis pipeline flush follows both FDB mutations.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1217-1218
    /\ a \in Asics
    /\ postReadyStep[a] = "learning-disabled"
    \* Pipeline completion remains distinct from the final heartbeat freeze.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1217-1221
    /\ postReadyStep' = [postReadyStep EXCEPT ![a] = "pipeline-flushed"]
    /\ UNCHANGED <<producerState, inflight, queue, readySent, readyConsumed,
                    freezeResult, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_WarmRestartReplyAfterFlush(a) ==
    \* MC-2's proposed ordering moves the same reply after local drain/FDB/flush,
    \* without inventing a global producer fence.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1187-1221,1378-1414
    /\ ReplyAfterLocalDrain
    /\ a \in Asics
    /\ postReadyStep[a] = "pipeline-flushed"
    /\ ~readySent[a]
    \* Other producer/channel state is deliberately unchanged at publication.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1190-1221 (MC-2 reorder)
    /\ readySent' = [readySent EXCEPT ![a] = TRUE]
    /\ postReadyStep' = [postReadyStep EXCEPT ![a] = "ready-after-flush"]
    /\ UNCHANGED <<producerState, inflight, queue, readyConsumed,
                    freezeResult, quiescent>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

OrchDaemon_FreezeAndHeartBeat(a) ==
    \* freezeAndHeartBeat is the final post-READY step.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1217-1221
    /\ a \in Asics
    /\ postReadyStep[a] =
          IF ReplyAfterLocalDrain THEN "ready-after-flush"
          ELSE "pipeline-flushed"
    \* Only now are the modeled namespace producers fenced; queued work remains
    \* non-quiescent until independently drained.
    \* src/sonic-swss/orchagent/orchdaemon.cpp:1190-1221
    /\ producerState' =
          [p \in Producers |->
              IF p[1] = a THEN "fenced" ELSE producerState[p]]
    /\ quiescent' =
          [p \in Producers |->
              IF p[1] = a
              THEN queue[p] = 0 /\ ~inflight[p]
              ELSE quiescent[p]]
    /\ postReadyStep' = [postReadyStep EXCEPT ![a] = "heartbeat"]
    /\ UNCHANGED <<inflight, queue, readySent, readyConsumed, freezeResult>>
    /\ UNCHANGED <<epochVars, snapshotVars, applyVars, identityVars,
                    completionVars>>

(**************************************************************************)
(* Scenario 3 actions: per-ASIC stop/mode and multi-step checkpoint.       *)
(**************************************************************************)

StopSystemdService_Success(a) ==
    \* Services are stopped one-by-one after the irreversible point.
    \* src/sonic-utilities/scripts/fast-reboot:1206-1217
    /\ a \in Asics
    /\ ActiveIrreversibleOwners /= {}
    /\ ~writerStopped[a]
    \* A successful stop removes the namespace writer; status is still local.
    \* src/sonic-utilities/scripts/fast-reboot:198-216
    /\ writerStopped' = [writerStopped EXCEPT ![a] = TRUE]
    /\ shutdownStatus' = [shutdownStatus EXCEPT ![a] = "succeeded"]
    /\ UNCHANGED <<localMode, snapshotEpoch, snapshotValid, snapshotPresent,
                    snapshotConsumed, snapshotStage, globalDecision,
                    selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

StopSystemdService_MaskedFailure(a) ==
    \* Shell helpers continue through command failures once set +e is active.
    \* src/sonic-utilities/scripts/fast-reboot:1163-1165,1206-1219
    /\ a \in Asics
    /\ ActiveIrreversibleOwners /= {}
    /\ ~writerStopped[a]
    \* The participant outcome can be lost while global progress continues.
    \* files/scripts/swss.sh:533-544
    /\ shutdownStatus' = [shutdownStatus EXCEPT ![a] = "lost"]
    /\ UNCHANGED <<writerStopped, localMode, snapshotEpoch, snapshotValid,
                    snapshotPresent, snapshotConsumed, snapshotStage,
                    globalDecision, selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

Syncd_PerformWarmShutdown(a) ==
    \* A requested warm shutdown locally enables warm restart on the switch.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6982-7000
    /\ a \in Asics
    /\ ActiveIrreversibleOwners /= {}
    /\ localMode[a] = "unknown"
    \* Success is written only to the participant-local state table.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6997-7010,7022-7029;
    \* src/sonic-sairedis/syncd/WarmRestartTable.cpp:37-43
    /\ localMode' = [localMode EXCEPT ![a] = "warm"]
    /\ shutdownStatus' = [shutdownStatus EXCEPT ![a] = "succeeded"]
    /\ UNCHANGED <<writerStopped, snapshotEpoch, snapshotValid,
                    snapshotPresent, snapshotConsumed, snapshotStage,
                    globalDecision, selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

Syncd_DowngradeWarmShutdown(a) ==
    \* Missing warm-boot file or SAI flag failure forces this syncd cold.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6982-7009
    /\ a \in Asics
    /\ ActiveIrreversibleOwners /= {}
    /\ localMode[a] \in {"unknown", "warm"}
    \* The coordinator does not read this mode back before checkpointing.
    \* files/scripts/syncd.sh:145-173
    /\ localMode' = [localMode EXCEPT ![a] = "cold"]
    /\ shutdownStatus' = [shutdownStatus EXCEPT ![a] = "failed"]
    /\ UNCHANGED <<writerStopped, snapshotEpoch, snapshotValid,
                    snapshotPresent, snapshotConsumed, snapshotStage,
                    globalDecision, selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

CentralizeDatabase_RedisSave(a) ==
    \* centralize_database migrates DBs and then invokes Redis SAVE.
    \* src/sonic-utilities/scripts/centralize_database:10-42;
    \* src/sonic-utilities/scripts/fast-reboot:498-501
    /\ a \in Asics
    /\ ActiveIrreversibleOwners /= {}
    /\ snapshotStage[a] = "idle"
    \* backup_database runs only after the complete SERVICES_TO_STOP loop.
    \* A swss stop may succeed (writerStopped) or be masked ("lost"), but it
    \* cannot still be unattempted when Redis SAVE begins.
    \* src/sonic-utilities/scripts/fast-reboot:1348-1361
    /\ \A b \in Asics : writerStopped[b] \/ shutdownStatus[b] = "lost"
    \* SAVE records the current epoch, but validity depends on the separate
    \* producer/service fence; the command itself does not validate it.
    \* src/sonic-utilities/scripts/centralize_database:17-42
    /\ snapshotEpoch' = [snapshotEpoch EXCEPT ![a] = CurrentEpoch]
    /\ snapshotValid' =
          [snapshotValid EXCEPT ![a] =
              writerStopped[a] /\ NamespaceQuiescent(a)]
    /\ snapshotStage' = [snapshotStage EXCEPT ![a] = "saved"]
    /\ UNCHANGED <<writerStopped, localMode, shutdownStatus,
                    snapshotPresent, snapshotConsumed, globalDecision,
                    selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

BackupDatabase_DockerCopy(a) ==
    \* dump.rdb is copied to the host after SAVE as an independent operation.
    \* src/sonic-utilities/scripts/fast-reboot:468-502
    /\ a \in Asics
    /\ snapshotStage[a] = "saved"
    \* Existence is published even though no epoch/completeness metadata is read.
    \* src/sonic-utilities/scripts/fast-reboot:498-505
    /\ snapshotPresent' = [snapshotPresent EXCEPT ![a] = TRUE]
    /\ snapshotStage' = [snapshotStage EXCEPT ![a] = "copied"]
    /\ UNCHANGED <<writerStopped, localMode, shutdownStatus, snapshotEpoch,
                    snapshotValid, snapshotConsumed, globalDecision,
                    selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

FastReboot_AggregateWarmDecision ==
    \* Global progress follows dump existence and reboot flags, not participant
    \* mode/status read-back.
    \* src/sonic-utilities/scripts/fast-reboot:1219-1222;
    \* files/scripts/syncd.sh:145-173
    /\ globalDecision = "undecided"
    /\ ActiveIrreversibleOwners /= {}
    /\ flags.warm
    /\ flags.epoch /= NoEpoch
    /\ \A a \in Asics : snapshotPresent[a]
    \* Mixed local warm/cold outcomes are deliberately not in this guard.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6982-7009
    /\ globalDecision' = "warm"
    /\ selectedEpoch' = flags.epoch
    /\ UNCHANGED <<writerStopped, localMode, shutdownStatus, snapshotEpoch,
                    snapshotValid, snapshotPresent, snapshotConsumed,
                    snapshotStage>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

FastReboot_AggregateColdDecision ==
    \* Explicit cold fallback is possible after a local downgrade or lost flags.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6988-7009
    /\ globalDecision = "undecided"
    /\ ActiveIrreversibleOwners /= {}
    /\ (\/ ~flags.warm
        \/ \E a \in Asics : localMode[a] = "cold")
    \* Cold is an explicit terminal recovery choice rather than dirty warm reuse.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6990-7009
    /\ globalDecision' = "cold"
    /\ selectedEpoch' = IF flags.epoch = NoEpoch THEN epoch ELSE flags.epoch
    /\ UNCHANGED <<writerStopped, localMode, shutdownStatus, snapshotEpoch,
                    snapshotValid, snapshotPresent, snapshotConsumed,
                    snapshotStage>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

DockerImageCtl_PreStartAction(a) ==
    \* Startup selects warm data solely from boot type plus dump existence.
    \* files/build_templates/docker_image_ctl.j2:102-115
    /\ a \in Asics
    /\ globalDecision = "warm"
    /\ snapshotPresent[a]
    /\ ~snapshotConsumed[a]
    \* Neither epoch nor snapshot validity is checked before the copy/load.
    \* files/build_templates/docker_image_ctl.j2:105-109,296-299
    /\ snapshotConsumed' = [snapshotConsumed EXCEPT ![a] = TRUE]
    /\ snapshotStage' = [snapshotStage EXCEPT ![a] = "loaded"]
    /\ UNCHANGED <<writerStopped, localMode, shutdownStatus, snapshotEpoch,
                    snapshotValid, snapshotPresent, globalDecision,
                    selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, applyVars, identityVars,
                    completionVars>>

(**************************************************************************)
(* Scenarios 4-5 actions: INIT/APPLY, identity choice, fragmented commit.  *)
(**************************************************************************)

Syncd_ProcessNotifySyncdInitView(a) ==
    \* INIT_VIEW switches syncd into temporary-view mode and clears the old temp.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5531-5555
    /\ a \in Asics
    /\ globalDecision = "warm"
    /\ initEpoch[a] /= selectedEpoch
    \* The response is sent after the local mode change, with no global INIT txn.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5533-5555
    /\ initEpoch' = [initEpoch EXCEPT ![a] = selectedEpoch]
    /\ UNCHANGED <<plannedOps, opCursor, hardwareView, dbView, applyEpoch,
                    applyAsic, applyState, recoveryMode, applyDirty,
                    journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

Syncd_ApplyViewCompare(a) ==
    \* applyView first reads current/temp views and performs non-destructive
    \* comparison before any ASIC operation.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5716-5832
    /\ a \in Asics
    /\ applyState = "idle"
    /\ initEpoch[a] = selectedEpoch
    /\ selectedEpoch /= NoEpoch
    \* Symmetric candidates remain possible when labels/graph heuristics do not
    \* distinguish them; every relation edge is explored by TLC.
    \* src/sonic-sairedis/syncd/ComparisonLogic.cpp:2874-2999;
    \* src/sonic-sairedis/syncd/BestCandidateFinder.cpp:1888-1999
    /\ applyAsic' = a
    /\ applyEpoch' = selectedEpoch
    /\ plannedOps' = ApplyOps
    /\ opCursor' = 0
    /\ applyState' = "matching"
    /\ applyDirty' = FALSE
    /\ recoveryMode' = "none"
    /\ journalState' = IF UseDurableApplyJournal THEN "intent" ELSE "none"
    /\ candidates' =
          {pair \in Vids \X Rids :
              stableLabels[pair[1]] = stableLabels[pair[2]]}
    /\ matching' = [v \in Vids |-> NoRid]
    /\ UNCHANGED <<initEpoch, hardwareView, dbView>>
    /\ UNCHANGED <<stableLabels, vidToRid, ridToVid, mapStage,
                    mapPending, mapHalf>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, completionVars>>

BestCandidateFinder_SelectRandomCandidate(v, r) ==
    \* Equal-label/equal-graph candidates fall through to random selection.
    \* src/sonic-sairedis/syncd/BestCandidateFinder.cpp:1965-1999,2015-2035
    /\ v \in Vids
    /\ r \in Rids
    /\ applyState = "matching"
    /\ matching[v] = NoRid
    /\ <<v, r>> \in candidates
    /\ r \notin {matching[vv] : vv \in Vids}
    \* One current object becomes FINAL per binding, so it cannot be reused by
    \* a later candidate choice in the same comparison.
    \* src/sonic-sairedis/syncd/ComparisonLogic.cpp:1069-1118,1790-1818
    /\ matching' = [matching EXCEPT ![v] = r]
    /\ UNCHANGED <<stableLabels, candidates, vidToRid, ridToVid, mapStage,
                    mapPending, mapHalf>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    completionVars>>

ComparisonLogic_CompareViewsComplete ==
    \* Destructive execution starts only after all comparison choices finish.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5794-5847
    /\ applyState = "matching"
    /\ MatchingComplete
    \* The planned operation loop is a later stage and therefore a new action.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5834-5847
    /\ applyState' = "executing"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode, applyDirty,
                    journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

ComparisonLogic_ExecuteOperationsOnAsic ==
    \* executeOperationsOnAsic iterates irreversible SAI calls in order.
    \* src/sonic-sairedis/syncd/ComparisonLogic.cpp:3797-3879
    /\ applyState = "executing"
    /\ opCursor < MaxApplyOps
    \* One modeled operation is one crash boundary; a failure leaves hardware
    \* inconsistent and causes syncd to exit.
    \* src/sonic-sairedis/syncd/ComparisonLogic.cpp:3861-3889
    /\ opCursor' = opCursor + 1
    /\ hardwareView' = hardwareView \cup {opCursor + 1}
    /\ applyDirty' = TRUE
    /\ journalState' = IF UseDurableApplyJournal THEN "dirty" ELSE journalState
    /\ UNCHANGED <<initEpoch, plannedOps, dbView, applyEpoch, applyAsic,
                    applyState, recoveryMode>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

Syncd_ApplyViewBeginRedisUpdate ==
    \* Redis replacement follows all hardware operations as a separate stage.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5844-5849
    /\ applyState = "executing"
    /\ opCursor = MaxApplyOps
    \* updateRedisDatabase begins by removing the current ASIC state table.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5921-5935
    /\ applyState' = "remove-db"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode, applyDirty,
                    journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

RedisClient_RemoveAsicStateTable ==
    \* Each existing ASIC_STATE key is deleted independently by RedisClient.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:886-896
    /\ applyState = "remove-db"
    \* The abstract table becomes empty before any temporary object is copied.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5931-5939
    /\ dbView' = {}
    /\ applyState' = "remove-temp"
    /\ applyDirty' = TRUE
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, applyEpoch,
                    applyAsic, recoveryMode, journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

RedisClient_RemoveTempAsicStateTable ==
    \* TEMP_ASIC_STATE keys are removed after current ASIC_STATE keys.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:898-908
    /\ applyState = "remove-temp"
    \* Object-by-object publication can now begin.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5933-5957
    /\ applyState' = "write-db"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode, applyDirty,
                    journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

RedisClient_CreateAsicObject(op) ==
    \* createAsicObject publishes each object/attribute with separate HSETs.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:582-600;
    \* src/sonic-sairedis/syncd/Syncd.cpp:5939-5957
    /\ op \in ApplyOps
    /\ applyState = "write-db"
    /\ op \notin dbView
    \* This model uses one abstract object per operation and preserves a crash
    \* cut between every publication fragment.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:590-599
    /\ dbView' = dbView \cup {op}
    /\ applyDirty' = TRUE
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, applyEpoch,
                    applyAsic, applyState, recoveryMode, journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

Syncd_UpdateRedisDatabaseBeginMaps ==
    \* Identity maps are replaced only after all ASIC objects are copied.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5937-5978
    /\ applyState = "write-db"
    /\ dbView = ApplyOps
    \* RedisClient deletes VIDTORID before RIDTOVID.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:664-672
    /\ applyState' = "delete-v2r"
    /\ mapStage' = "deleting-v2r"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode, applyDirty,
                    journalState>>
    /\ UNCHANGED <<stableLabels, candidates, matching, vidToRid, ridToVid,
                    mapPending, mapHalf>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, completionVars>>

RedisClient_SetVidAndRidMapDeleteVidToRid ==
    \* First Redis DEL removes the complete VIDTORID hash.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:664-670
    /\ applyState = "delete-v2r"
    \* RIDTOVID remains externally observable until the next command.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:669-670
    /\ vidToRid' = [v \in Vids |-> NoRid]
    /\ applyState' = "delete-r2v"
    /\ mapStage' = "deleting-r2v"
    /\ UNCHANGED <<stableLabels, candidates, matching, ridToVid,
                    mapPending, mapHalf>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, initEpoch,
                    plannedOps, opCursor, hardwareView, dbView, applyEpoch,
                    applyAsic, recoveryMode, applyDirty, journalState,
                    completionVars>>

RedisClient_SetVidAndRidMapDeleteRidToVid ==
    \* The next Redis DEL removes RIDTOVID.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:669-671
    /\ applyState = "delete-r2v"
    \* The unordered map loop will republish pairs one entry at a time.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:672-679
    /\ ridToVid' = [r \in Rids |-> NoVid]
    /\ mapPending' = Vids
    /\ mapHalf' = NoVid
    /\ applyState' = "write-maps"
    /\ mapStage' = "writing"
    /\ UNCHANGED <<stableLabels, candidates, matching, vidToRid>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, initEpoch,
                    plannedOps, opCursor, hardwareView, dbView, applyEpoch,
                    applyAsic, recoveryMode, applyDirty, journalState,
                    completionVars>>

RedisClient_SetVidAndRidMapWriteVidToRid(v) ==
    \* For one unordered-map entry, VIDTORID is written first.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:672-678
    /\ v \in Vids
    /\ applyState = "write-maps"
    /\ mapHalf = NoVid
    /\ v \in mapPending
    /\ matching[v] \in Rids
    \* RIDTORVID is intentionally unchanged until the paired next action.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:677-678
    /\ vidToRid' = [vidToRid EXCEPT ![v] = matching[v]]
    /\ mapHalf' = v
    /\ UNCHANGED <<stableLabels, candidates, matching, ridToVid, mapStage,
                    mapPending>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    completionVars>>

RedisClient_SetVidAndRidMapWriteRidToVid ==
    \* The paired RIDTOVID HSET follows the VIDTORID HSET.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:674-679
    /\ applyState = "write-maps"
    /\ mapHalf \in Vids
    /\ matching[mapHalf] \in Rids
    \* Only after both writes is this unordered-map entry considered complete.
    \* src/sonic-sairedis/syncd/RedisClient.cpp:677-679
    /\ ridToVid' = [ridToVid EXCEPT ![matching[mapHalf]] = mapHalf]
    /\ mapPending' = mapPending \ {mapHalf}
    /\ mapHalf' = NoVid
    /\ UNCHANGED <<stableLabels, candidates, matching, vidToRid, mapStage>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    completionVars>>

Syncd_UpdateRedisDatabaseComplete ==
    \* updateRedisDatabase returns after every map pair is written.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5960-5980
    /\ applyState = "write-maps"
    /\ mapPending = {}
    /\ mapHalf = NoVid
    \* Consistency checking and response publication remain later boundaries.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5849-5864
    /\ applyState' = "verify"
    /\ mapStage' = "complete"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode, applyDirty,
                    journalState>>
    /\ UNCHANGED <<stableLabels, candidates, matching, vidToRid, ridToVid,
                    mapPending, mapHalf>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, completionVars>>

Syncd_ApplyViewCommit ==
    \* applyView returns success only after hardware, DB, maps, and optional
    \* consistency checking finish.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5844-5864
    /\ applyState = "verify"
    /\ hardwareView = ApplyOps
    /\ dbView = ApplyOps
    /\ IdentityMapsTotal
    /\ IdentityMapsReciprocal
    \* A successful response clears the dirty/journal intent in the model.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5583-5605
    /\ applyState' = "committed"
    /\ applyDirty' = FALSE
    /\ journalState' = IF UseDurableApplyJournal THEN "committed" ELSE "none"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

Syncd_CrashDuringApply ==
    \* Exceptions/crashes after the destructive stage leave ASIC state
    \* inconsistent and terminate syncd.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5834-5849;
    \* src/sonic-sairedis/syncd/ComparisonLogic.cpp:3861-3889
    /\ applyState \in
          {"executing", "remove-db", "remove-temp", "write-db",
           "delete-v2r", "delete-r2v", "write-maps", "verify"}
    \* No implementation journal records which hardware/Redis fragment committed.
    \* src/sonic-sairedis/syncd/WarmRestartTable.cpp:20-43
    /\ applyState' = "crashed"
    /\ applyDirty' = TRUE
    /\ journalState' = IF UseDurableApplyJournal THEN "dirty" ELSE "none"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, recoveryMode>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

Syncd_ResumeFromDurableJournal ==
    \* MC-3's proposed durable journal supplies an explicit resume rule absent
    \* from WarmRestartTable today.
    \* src/sonic-sairedis/syncd/WarmRestartTable.cpp:20-43 (Scenario 4 extension)
    /\ UseDurableApplyJournal
    /\ applyState = "crashed"
    /\ journalState = "dirty"
    /\ MatchingComplete
    \* Recovery replays remaining fragments to one agreed authority before warm
    \* completion is exposed.
    \* src/sonic-sairedis/syncd/Syncd.cpp:5844-5980 (modeled repair policy)
    /\ recoveryMode' = "resume"
    /\ hardwareView' = ApplyOps
    /\ dbView' = ApplyOps
    /\ vidToRid' = matching
    /\ ridToVid' = InverseMatching
    /\ mapStage' = "complete"
    /\ mapPending' = {}
    /\ mapHalf' = NoVid
    /\ applyState' = "committed"
    /\ applyDirty' = FALSE
    /\ journalState' = "committed"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, applyEpoch, applyAsic>>
    /\ UNCHANGED <<stableLabels, candidates, matching>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, completionVars>>

Syncd_AcceptDirtyWarmRecovery ==
    \* Without a journal, warm startup accepts dump existence and has no APPLY
    \* dirty/epoch marker to consult.
    \* files/build_templates/docker_image_ctl.j2:105-109,296-299;
    \* src/sonic-sairedis/syncd/WarmRestartTable.cpp:20-43
    /\ ~UseDurableApplyJournal
    /\ applyState = "crashed"
    /\ globalDecision = "warm"
    /\ \E a \in Asics : snapshotConsumed[a]
    \* The incomplete hardware/DB/maps are treated as warm-authoritative.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6211-6357
    /\ recoveryMode' = "unsafe-warm"
    /\ applyState' = "committed"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, applyDirty, journalState>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, identityVars,
                    completionVars>>

Syncd_ForceColdRecovery ==
    \* Explicit cold fallback is the safe alternative after an unresumable cut.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6988-7009
    /\ applyState = "crashed"
    \* Cold selection prevents dirty APPLY state from becoming warm authority.
    \* src/sonic-sairedis/syncd/Syncd.cpp:6990-7009
    /\ recoveryMode' = "cold"
    /\ applyState' = "aborted"
    /\ applyDirty' = FALSE
    /\ globalDecision' = "cold"
    /\ UNCHANGED <<initEpoch, plannedOps, opCursor, hardwareView, dbView,
                    applyEpoch, applyAsic, journalState>>
    /\ UNCHANGED <<writerStopped, localMode, shutdownStatus, snapshotEpoch,
                    snapshotValid, snapshotPresent, snapshotConsumed,
                    snapshotStage, selectedEpoch>>
    /\ UNCHANGED <<epochVars, producerVars, identityVars, completionVars>>

(**************************************************************************)
(* Scenario 6 actions: timeout, reconciliation, publication, finalization. *)
(**************************************************************************)

WarmStartHelper_RunRestoration ==
    \* runRestoration copies existing AppDB state to a temporary vector.
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:96-128
    /\ terminal[FpmComponent] = "initial"
    /\ (flags.warm \/ globalDecision = "warm")
    \* A non-empty restoration enters RESTORED and starts timer-based waiting.
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:107-133
    /\ cachedOld' = Routes
    /\ terminal' = [terminal EXCEPT ![FpmComponent] = "restored"]
    /\ UNCHANGED <<inputComplete, timerExpired, refreshedNew, outputBuffered,
                    outputPublished, derivedOutputs, flagsCleared,
                    finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

WarmStartHelper_InsertRefreshMap(r) ==
    \* Early routing input is cached by key while warm reconciliation is active.
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:137-142
    /\ r \in Routes
    /\ terminal[FpmComponent] = "restored"
    /\ r \notin refreshedNew
    \* Insertion does not prove that the entire input stream is complete.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:154-181
    /\ refreshedNew' = refreshedNew \cup {r}
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, outputBuffered,
                    outputPublished, derivedOutputs, terminal, flagsCleared,
                    finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

FpmSyncd_EoiuInputComplete ==
    \* EOIU is one trigger for ending refresh collection.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:177-181,221-230
    /\ terminal[FpmComponent] = "restored"
    /\ ~inputComplete
    \* The EOIU signal is distinct from output reconciliation/flush.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:197-220
    /\ inputComplete' = TRUE
    /\ UNCHANGED <<timerExpired, cachedOld, refreshedNew, outputBuffered,
                    outputPublished, derivedOutputs, terminal, flagsCleared,
                    finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

FpmSyncd_WarmRestartTimerExpired ==
    \* Silence until the warm timer expires is accepted as a reconciliation
    \* trigger even without EOIU.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:154-174,197-214
    /\ terminal[FpmComponent] = "restored"
    /\ ~timerExpired
    \* Expiry does not set inputComplete; late input remains possible.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:203-218
    /\ timerExpired' = TRUE
    /\ UNCHANGED <<inputComplete, cachedOld, refreshedNew, outputBuffered,
                    outputPublished, derivedOutputs, terminal, flagsCleared,
                    finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

RouteSync_OnWarmStartEnd ==
    \* Timer/EOIU calls onWarmStartEnd, which invokes reconcile while RESTORED.
    \* src/sonic-swss/fpmsyncd/routesync.cpp:3768-3781;
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:152-176
    /\ terminal[FpmComponent] = "restored"
    /\ (timerExpired \/ inputComplete)
    \* Missing refresh entries become buffered deletes; reconcile then publishes
    \* RECONCILED before fpmsyncd flushes its Redis pipeline.
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:159-176,250-256;
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:214-219
    /\ derivedOutputs' = cachedOld \ refreshedNew
    /\ outputBuffered' = outputBuffered \cup (cachedOld \ refreshedNew)
    /\ terminal' = [terminal EXCEPT ![FpmComponent] = "reconciled"]
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, refreshedNew,
                    outputPublished, flagsCleared, finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

FpmSyncd_PipelineFlush ==
    \* The normal non-ZMQ pipeline flush occurs after onWarmStartEnd returns.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:214-219
    /\ outputBuffered /= {}
    \* Buffered derived writes become durable together at this later boundary.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:216-219
    /\ outputPublished' = outputPublished \cup outputBuffered
    /\ outputBuffered' = {}
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, refreshedNew,
                    derivedOutputs, terminal, flagsCleared,
                    finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

WarmStartHelper_LateInput(r) ==
    \* Input may arrive after timeout-based reconciliation declared terminal.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:190-220;
    \* src/sonic-swss/warmrestart/warmRestartHelper.cpp:159-176
    /\ r \in Routes
    /\ terminal[FpmComponent] = "reconciled"
    /\ r \notin refreshedNew
    \* Normal processing buffers the late publication after terminal state.
    \* src/sonic-swss/fpmsyncd/fpmsyncd.cpp:190-220
    /\ refreshedNew' = refreshedNew \cup {r}
    /\ outputBuffered' = outputBuffered \cup {r}
    /\ derivedOutputs' = derivedOutputs \cup {r}
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, outputPublished,
                    terminal, flagsCleared, finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

Component_PublishTerminal(comp) ==
    \* Other daemons independently publish their warm-restart state in Redis.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:139-155
    /\ comp \in Components \ {FpmComponent}
    /\ terminal[FpmComponent] /= "initial"
    /\ terminal[comp] = "initial"
    \* Success publication is per component, without a global transaction.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:145-155
    /\ terminal' = [terminal EXCEPT ![comp] = "reconciled"]
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, refreshedNew,
                    outputBuffered, outputPublished, derivedOutputs,
                    flagsCleared, finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

Component_PublishFailure(comp) ==
    \* The model gives pending participants an explicit terminal failure state,
    \* as required by MC-5's proposed policy.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:145-158
    /\ comp \in Components
    /\ terminal[FpmComponent] /= "initial"
    /\ terminal[comp] \in {"initial", "restored"}
    \* Failure is terminal but is not equivalent to durable output publication.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:246-258
    /\ terminal' = [terminal EXCEPT ![comp] = "failed"]
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, refreshedNew,
                    outputBuffered, outputPublished, derivedOutputs,
                    flagsCleared, finalizerTimedOut>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

FinalizeWarmboot_WaitTimeout ==
    \* The finalizer stops waiting after sixty five-second polls.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:237-258
    /\ ~finalizerTimedOut
    /\ terminal[FpmComponent] /= "initial"
    /\ ~AllRequiredTerminal
    \* Timeout is logged but does not fail or prevent subsequent finalization.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:246-259
    /\ finalizerTimedOut' = TRUE
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, refreshedNew,
                    outputBuffered, outputPublished, derivedOutputs, terminal,
                    flagsCleared>>
    /\ UNCHANGED <<epochVars, producerVars, snapshotVars, applyVars,
                    identityVars>>

FinalizeWarmboot_FinalizeGlobal ==
    \* Per-ASIC jobs and the global job join, then finalize_global clears flags.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:268-302
    /\ (finalizerTimedOut \/ AllRequiredTerminal)
    /\ terminal[FpmComponent] /= "initial"
    /\ \E comp \in Components : ~flagsCleared[comp]
    \* The timeout path has no output-durability or late-participant guard.
    \* files/image_config/warmboot-finalizer/finalize-warmboot.sh:165-196,299-302
    /\ flagsCleared' = [comp \in Components |-> TRUE]
    /\ flags' = [flags EXCEPT !.warm = FALSE, !.fast = FALSE,
                              !.epoch = NoEpoch]
    /\ UNCHANGED <<inputComplete, timerExpired, cachedOld, refreshedNew,
                    outputBuffered, outputPublished, derivedOutputs, terminal,
                    finalizerTimedOut>>
    /\ UNCHANGED <<epoch, owner, requestKind, phase, cancelled, cleanupOwner,
                    checked, admitted, attemptEpoch, attemptOutcome,
                    irreversibleStarted>>
    /\ UNCHANGED <<producerVars, snapshotVars, applyVars, identityVars>>

(**************************************************************************)
(* Next-state relation.                                                   *)
(**************************************************************************)

Next ==
    \/ \E c \in Owners, kind \in RequestKinds : FastReboot_Request(c, kind)
    \/ \E c \in Owners : CheckWarmRestartInProgress_Admit(c)
    \/ \E c \in Owners : CheckWarmRestartInProgress_Reject(c)
    \/ \E c \in Owners : EnableWarmRestart(c)
    \/ \E c \in Owners : ClearBoot(c)
    \/ \E c \in Owners : FastReboot_ContinueAfterSignal(c)
    \/ \E c \in Owners : FastReboot_PauseOrchagentComplete(c)
    \/ \E c \in Owners : FastReboot_BeginIrreversibleWork(c)
    \/ \E c \in Owners : FastReboot_RecordOutcome(c)

    \/ \E p \in Producers : Producer_Enqueue(p)
    \/ \E p \in Producers : Producer_DrainOne(p)
    \/ \E a \in Asics : OrchDaemon_WarmRestartCheck(a)
    \/ \E a \in Asics : OrchagentRestartCheck_ConsumeReply(a)
    \/ \E a \in Asics : PauseOrchagent_IgnoreFailure(a)
    \/ \E a \in Asics : OrchDaemon_DrainRing(a)
    \/ \E a \in Asics : OrchDaemon_SetAgingFDB(a)
    \/ \E a \in Asics : OrchDaemon_SetBridgePortLearningFDB(a)
    \/ \E a \in Asics : OrchDaemon_Flush(a)
    \/ \E a \in Asics : OrchDaemon_WarmRestartReplyAfterFlush(a)
    \/ \E a \in Asics : OrchDaemon_FreezeAndHeartBeat(a)

    \/ \E a \in Asics : StopSystemdService_Success(a)
    \/ \E a \in Asics : StopSystemdService_MaskedFailure(a)
    \/ \E a \in Asics : Syncd_PerformWarmShutdown(a)
    \/ \E a \in Asics : Syncd_DowngradeWarmShutdown(a)
    \/ \E a \in Asics : CentralizeDatabase_RedisSave(a)
    \/ \E a \in Asics : BackupDatabase_DockerCopy(a)
    \/ FastReboot_AggregateWarmDecision
    \/ FastReboot_AggregateColdDecision
    \/ \E a \in Asics : DockerImageCtl_PreStartAction(a)

    \/ \E a \in Asics : Syncd_ProcessNotifySyncdInitView(a)
    \/ \E a \in Asics : Syncd_ApplyViewCompare(a)
    \/ \E v \in Vids, r \in Rids : BestCandidateFinder_SelectRandomCandidate(v, r)
    \/ ComparisonLogic_CompareViewsComplete
    \/ ComparisonLogic_ExecuteOperationsOnAsic
    \/ Syncd_ApplyViewBeginRedisUpdate
    \/ RedisClient_RemoveAsicStateTable
    \/ RedisClient_RemoveTempAsicStateTable
    \/ \E op \in ApplyOps : RedisClient_CreateAsicObject(op)
    \/ Syncd_UpdateRedisDatabaseBeginMaps
    \/ RedisClient_SetVidAndRidMapDeleteVidToRid
    \/ RedisClient_SetVidAndRidMapDeleteRidToVid
    \/ \E v \in Vids : RedisClient_SetVidAndRidMapWriteVidToRid(v)
    \/ RedisClient_SetVidAndRidMapWriteRidToVid
    \/ Syncd_UpdateRedisDatabaseComplete
    \/ Syncd_ApplyViewCommit
    \/ Syncd_CrashDuringApply
    \/ Syncd_ResumeFromDurableJournal
    \/ Syncd_AcceptDirtyWarmRecovery
    \/ Syncd_ForceColdRecovery

    \/ WarmStartHelper_RunRestoration
    \/ \E r \in Routes : WarmStartHelper_InsertRefreshMap(r)
    \/ FpmSyncd_EoiuInputComplete
    \/ FpmSyncd_WarmRestartTimerExpired
    \/ RouteSync_OnWarmStartEnd
    \/ FpmSyncd_PipelineFlush
    \/ \E r \in Routes : WarmStartHelper_LateInput(r)
    \/ \E comp \in Components : Component_PublishTerminal(comp)
    \/ \E comp \in Components : Component_PublishFailure(comp)
    \/ FinalizeWarmboot_WaitTimeout
    \/ FinalizeWarmboot_FinalizeGlobal

Spec == Init /\ [][Next]_vars

(**************************************************************************)
(* Structural invariants.                                                 *)
(**************************************************************************)

TypeOK ==
    /\ epoch \in Nat
    /\ owner \in Owners \cup {NoOwner}
    /\ requestKind \in [Owners -> RequestKinds \cup {"none"}]
    /\ phase \in [Owners -> PhaseNames]
    /\ cancelled \in [Owners -> BOOLEAN]
    /\ flags \in [warm : BOOLEAN, fast : BOOLEAN, epoch : Int]
    /\ cleanupOwner \in Owners \cup {NoOwner}
    /\ checked \in [Owners -> BOOLEAN]
    /\ admitted \in [Owners -> BOOLEAN]
    /\ attemptEpoch \in [Owners -> Int]
    /\ attemptOutcome \in [Owners -> AttemptOutcomes]
    /\ irreversibleStarted \in [Owners -> BOOLEAN]
    /\ producerState \in [Producers -> ProducerStates]
    /\ inflight \in [Producers -> BOOLEAN]
    /\ queue \in [Producers -> 0..MaxQueue]
    /\ readySent \in [Asics -> BOOLEAN]
    /\ readyConsumed \in [Asics -> BOOLEAN]
    /\ freezeResult \in [Asics -> FreezeResults]
    /\ postReadyStep \in [Asics -> PostReadySteps]
    /\ quiescent \in [Producers -> BOOLEAN]
    /\ writerStopped \in [Asics -> BOOLEAN]
    /\ localMode \in [Asics -> LocalModes]
    /\ shutdownStatus \in [Asics -> ShutdownStatuses]
    /\ snapshotEpoch \in [Asics -> Int]
    /\ snapshotValid \in [Asics -> BOOLEAN]
    /\ snapshotPresent \in [Asics -> BOOLEAN]
    /\ snapshotConsumed \in [Asics -> BOOLEAN]
    /\ snapshotStage \in [Asics -> SnapshotStages]
    /\ globalDecision \in DecisionStates
    /\ selectedEpoch \in Int
    /\ initEpoch \in [Asics -> Int]
    /\ plannedOps \subseteq ApplyOps
    /\ opCursor \in 0..MaxApplyOps
    /\ hardwareView \subseteq ApplyOps
    /\ dbView \subseteq ApplyOps
    /\ applyEpoch \in Int
    /\ applyAsic \in Asics \cup {NoAsic}
    /\ applyState \in ApplyStates
    /\ recoveryMode \in RecoveryModes
    /\ applyDirty \in BOOLEAN
    /\ journalState \in JournalStates
    /\ stableLabels \in [Vids \cup Rids -> STRING]
    /\ candidates \subseteq (Vids \X Rids)
    /\ matching \in [Vids -> Rids \cup {NoRid}]
    /\ vidToRid \in [Vids -> Rids \cup {NoRid}]
    /\ ridToVid \in [Rids -> Vids \cup {NoVid}]
    /\ mapStage \in MapStages
    /\ mapPending \subseteq Vids
    /\ mapHalf \in Vids \cup {NoVid}
    /\ inputComplete \in BOOLEAN
    /\ timerExpired \in BOOLEAN
    /\ cachedOld \subseteq Routes
    /\ refreshedNew \subseteq Routes
    /\ outputBuffered \subseteq Routes
    /\ outputPublished \subseteq Routes
    /\ derivedOutputs \subseteq Routes
    /\ terminal \in [Components -> TerminalStates]
    /\ flagsCleared \in [Components -> BOOLEAN]
    /\ finalizerTimedOut \in BOOLEAN

StructuralWellFormed ==
    /\ \A p \in Producers : quiescent[p] => queue[p] = 0 /\ ~inflight[p]
    /\ \A a \in Asics : snapshotConsumed[a] => snapshotPresent[a]
    /\ applyState = "idle" => applyAsic = NoAsic
    /\ mapHalf /= NoVid => mapHalf \in mapPending
    /\ derivedOutputs \subseteq outputBuffered \cup outputPublished

(**************************************************************************)
(* Brief section 5 safety invariants.                                     *)
(**************************************************************************)

InitBeforeApply ==
    applyState \in
        {"executing", "remove-db", "remove-temp", "write-db",
         "delete-v2r", "delete-r2v", "write-maps", "verify", "committed"}
    => /\ applyAsic \in Asics
       /\ initEpoch[applyAsic] = applyEpoch

SingleAuthoritativeView ==
    /\ (applyState = "committed" /\ recoveryMode /= "cold")
       => /\ hardwareView = dbView
          /\ applyEpoch = selectedEpoch
    /\ globalDecision = "warm"
       => \A a \in Asics :
              snapshotConsumed[a]
              => snapshotEpoch[a] = selectedEpoch

PhaseMonotonicity ==
    \A c \in Owners :
        irreversibleStarted[c] /\ attemptOutcome[c] = "pending"
        => /\ phase[c] \in {"irreversible", "completed", "cold"}
           /\ ~cancelled[c]
           /\ flags.warm
           /\ flags.epoch = attemptEpoch[c]
           /\ owner = c

AtMostOneActiveEpoch ==
    Cardinality(ActiveIrreversibleOwners) <= 1

FreezeAckImpliesQuiescence ==
    \A a \in Asics : readySent[a] => NamespaceQuiescent(a)

CheckpointAfterQuiescence ==
    \A a \in Asics :
        snapshotStage[a] \in {"saved", "copied", "loaded"}
        => /\ writerStopped[a]
           /\ NamespaceQuiescent(a)

CompleteSameEpochSnapshot ==
    \A a \in Asics :
        snapshotConsumed[a]
        => /\ snapshotPresent[a]
           /\ snapshotValid[a]
           /\ snapshotEpoch[a] = selectedEpoch

ApplyCommitAgreement ==
    applyState = "committed" /\ recoveryMode /= "cold"
    => /\ hardwareView = ApplyOps
       /\ dbView = ApplyOps
       /\ hardwareView = dbView
       /\ IdentityMapsTotal
       /\ IdentityMapsReciprocal

NoWarmFromDirtyApply ==
    recoveryMode /= "unsafe-warm"

IdentityMapBijective ==
    IdentityMapsReciprocal

ReconciledImpliesOutputsPublished ==
    terminal[FpmComponent] = "reconciled" => OutputsDurable

WarmFlagSafeToClear ==
    (\E comp \in Components : flagsCleared[comp])
    => /\ AllRequiredTerminal
       /\ OutputsDurable

(**************************************************************************)
(* Brief section 5 liveness property.                                     *)
(**************************************************************************)

EventualRecoveryDecision ==
    \A c \in Owners :
        admitted[c] ~> (attemptOutcome[c] \in {"warm", "cold"})

(**************************************************************************)
(* Symmetry expression used by the MC layer.                              *)
(**************************************************************************)

Symmetry ==
    Permutations(Owners)
    \cup Permutations(Asics)
    \cup Permutations(Routes)
    \cup Permutations(Vids)
    \cup Permutations(Rids)

=============================================================================
