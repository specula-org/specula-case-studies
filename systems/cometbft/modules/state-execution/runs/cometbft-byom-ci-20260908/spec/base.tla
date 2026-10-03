------------------------------- MODULE base -------------------------------
(***************************************************************************
Exact-old CometBFT state execution and recovery model.

Consensus parameter records are represented by symbolic identities. Params
denotes complete records and ValidParams is the result of the old-tree
ValidateBasic + ValidateUpdate checks for the current bounded model.
***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS MaxHeight, Params, ValidParams, InitialParam, NoParam

ASSUME /\ MaxHeight \in Nat \ {0}
       /\ Params /= {}
       /\ ValidParams \subseteq Params
       /\ InitialParam \in ValidParams
       /\ NoParam \notin Params

VARIABLES
    blockStoreHeight,             \* internal/store/store.go:84-88
    appHeight,                    \* internal/consensus/replay.go:248-252
    stateStoreHeight,             \* internal/state/state.go:54-79
    stateHeight,                  \* in-memory State.LastBlockHeight
    activeParam,                  \* in-memory State.ConsensusParams
    persistedParam,               \* state-store parameter identity
    lastParamChange,              \* State.LastHeightConsensusParamsChanged
    persistedLastParamChange,
    responseHeight,               \* durable latest FinalizeBlockResponse
    responseParam,
    phase,
    replayMutatesState,
    pendingBlockHeight,
    pendingParam,
    updatePresent,
    validationOutcome,
    coverage                      \* observer-only non-vacuity markers

vars == <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
          activeParam, persistedParam, lastParamChange,
          persistedLastParamChange, responseHeight, responseParam, phase,
          replayMutatesState, pendingBlockHeight, pendingParam,
          updatePresent, validationOutcome, coverage>>

Phases == {"normal", "blockStored", "applying", "finalized",
           "responseSaved", "updated", "committed", "rejected",
           "down", "handshake"}
ValidationOutcomes == {"none", "accepted", "rejected"}
ParamOrNone == Params \cup {NoParam}

Init ==
    \* Genesis state: internal/state/state.go:334-352.
    /\ blockStoreHeight = 0
    /\ appHeight = 0
    /\ stateStoreHeight = 0
    /\ stateHeight = 0
    /\ activeParam = InitialParam
    /\ persistedParam = InitialParam
    /\ lastParamChange = 1
    /\ persistedLastParamChange = 1
    /\ responseHeight = 0
    /\ responseParam = NoParam
    /\ phase = "normal"
    /\ replayMutatesState = FALSE
    /\ pendingBlockHeight = 0
    /\ pendingParam = NoParam
    /\ updatePresent = FALSE
    /\ validationOutcome = "none"
    /\ coverage = {}

SaveBlock ==
    \* Consensus persists H before ApplyBlock: internal/consensus/state.go:1781-1817.
    /\ phase = "normal"
    /\ blockStoreHeight = stateStoreHeight
    /\ blockStoreHeight < MaxHeight
    /\ blockStoreHeight' = blockStoreHeight + 1
    /\ pendingBlockHeight' = blockStoreHeight + 1
    /\ phase' = "blockStored"
    /\ coverage' = coverage \cup {"blockStored"}
    /\ UNCHANGED <<appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    replayMutatesState, pendingParam, updatePresent,
                    validationOutcome>>

ApplyBlockStart ==
    \* ApplyBlock entry and non-mutating validation: execution.go:205-216.
    /\ phase = "blockStored"
    /\ pendingBlockHeight = blockStoreHeight
    /\ stateHeight = stateStoreHeight
    /\ phase' = "applying"
    /\ coverage' = coverage \cup {"applyStarted"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    replayMutatesState, pendingBlockHeight, pendingParam,
                    updatePresent, validationOutcome>>

FinalizeBlock(p) ==
    \* Synchronous app transition: internal/state/execution.go:219-234.
    /\ phase = "applying"
    /\ p \in ParamOrNone
    \* A previously saved response for H must replay deterministically.
    \* internal/consensus/replay.go:417-432.
    /\ (responseHeight = pendingBlockHeight => p = responseParam)
    /\ pendingParam' = p
    /\ updatePresent' = (p /= NoParam)
    /\ phase' = "finalized"
    /\ coverage' = coverage \cup {"finalized"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    replayMutatesState, pendingBlockHeight,
                    validationOutcome>>

SaveFinalizeBlockResponse ==
    \* Sync-save response before validation: execution.go:253-256 and
    \* internal/state/store.go:562-601.
    /\ phase = "finalized"
    /\ responseHeight' = pendingBlockHeight
    /\ responseParam' = pendingParam
    /\ phase' = "responseSaved"
    /\ coverage' = coverage \cup {"responseSaved"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, replayMutatesState,
                    pendingBlockHeight, pendingParam, updatePresent,
                    validationOutcome>>

UpdateStateAccepted ==
    \* Update copy, validate, then construct H state: execution.go:611-652.
    /\ phase = "responseSaved"
    /\ (pendingParam = NoParam \/ pendingParam \in ValidParams)
    /\ stateHeight' = pendingBlockHeight
    /\ activeParam' = IF updatePresent THEN pendingParam ELSE activeParam
    /\ lastParamChange' = IF updatePresent
                           THEN pendingBlockHeight + 1
                           ELSE lastParamChange
    /\ validationOutcome' = "accepted"
    /\ phase' = "updated"
    /\ coverage' = coverage \cup {"acceptedUpdate"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight,
                    persistedParam, persistedLastParamChange, responseHeight,
                    responseParam, replayMutatesState, pendingBlockHeight,
                    pendingParam, updatePresent>>

UpdateStateRejected ==
    \* Both validation failures return the input State: execution.go:617-625.
    /\ phase = "responseSaved"
    /\ updatePresent
    /\ pendingParam \in Params \ ValidParams
    /\ validationOutcome' = "rejected"
    /\ phase' = "rejected"
    /\ coverage' = coverage \cup {"rejectedUpdate"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    replayMutatesState, pendingBlockHeight, pendingParam,
                    updatePresent>>

CommitApp ==
    \* App persists H before state save: execution.go:370-418.
    /\ phase = "updated"
    /\ appHeight <= pendingBlockHeight
    /\ appHeight' = pendingBlockHeight
    /\ phase' = "committed"
    /\ coverage' = coverage \cup {"appCommitted"}
    /\ UNCHANGED <<blockStoreHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    replayMutatesState, pendingBlockHeight, pendingParam,
                    updatePresent, validationOutcome>>

SaveState ==
    \* Sync state/parameter batch: execution.go:295-299; store.go:204-243.
    /\ phase = "committed"
    /\ stateStoreHeight' = stateHeight
    /\ persistedParam' = activeParam
    /\ persistedLastParamChange' = lastParamChange
    /\ phase' = IF replayMutatesState THEN "handshake" ELSE "normal"
    /\ pendingBlockHeight' = 0
    /\ pendingParam' = NoParam
    /\ updatePresent' = FALSE
    /\ validationOutcome' = "none"
    /\ coverage' = coverage \cup {"stateSaved"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateHeight, activeParam,
                    lastParamChange, responseHeight, responseParam,
                    replayMutatesState>>

AbortRejectedApply ==
    \* Production consensus treats ApplyBlock error as fatal: consensus/state.go:1834-1836.
    /\ phase = "rejected"
    /\ stateHeight' = stateStoreHeight
    /\ activeParam' = persistedParam
    /\ lastParamChange' = persistedLastParamChange
    /\ phase' = "down"
    /\ replayMutatesState' = FALSE
    /\ pendingBlockHeight' = 0
    /\ pendingParam' = NoParam
    /\ updatePresent' = FALSE
    /\ validationOutcome' = "none"
    /\ coverage' = coverage \cup {"rejectedAbort"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight,
                    persistedParam, persistedLastParamChange, responseHeight,
                    responseParam>>

Crash ==
    \* Crash keeps durable stores/app and loses staged State.
    \* Recovery contract: spec/abci/abci++_app_requirements.md:899-950.
    /\ phase /= "down"
    /\ stateHeight' = stateStoreHeight
    /\ activeParam' = persistedParam
    /\ lastParamChange' = persistedLastParamChange
    /\ phase' = "down"
    /\ replayMutatesState' = FALSE
    /\ pendingBlockHeight' = 0
    /\ pendingParam' = NoParam
    /\ updatePresent' = FALSE
    /\ validationOutcome' = "none"
    /\ coverage' = coverage \cup {"crashed"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight,
                    persistedParam, persistedLastParamChange, responseHeight,
                    responseParam>>

AppReportsOlderHeight(h) ==
    \* Replay explicitly accepts an app behind the store: replay.go:388-406.
    /\ phase = "down"
    /\ h \in 0..appHeight
    /\ h < appHeight
    /\ appHeight' = h
    /\ coverage' = coverage \cup {"appReportedOlder"}
    /\ UNCHANGED <<blockStoreHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    phase, replayMutatesState, pendingBlockHeight,
                    pendingParam, updatePresent, validationOutcome>>

BeginHandshake ==
    \* Info height and old-tree admissibility guards: replay.go:240-267,358-383.
    /\ phase = "down"
    /\ appHeight <= blockStoreHeight
    /\ stateStoreHeight <= blockStoreHeight
    /\ blockStoreHeight <= stateStoreHeight + 1
    /\ phase' = "handshake"
    /\ coverage' = coverage \cup {"handshakeStarted"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    replayMutatesState, pendingBlockHeight, pendingParam,
                    updatePresent, validationOutcome>>

ReplayAppBlock ==
    \* Historical blocks use ExecCommitBlock without State mutation:
    \* internal/consensus/replay.go:441-489.
    /\ phase = "handshake"
    /\ appHeight < stateStoreHeight
    /\ appHeight' = appHeight + 1
    /\ replayMutatesState' = FALSE
    /\ coverage' = coverage \cup {"appOnlyReplay"}
    /\ UNCHANGED <<blockStoreHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    phase, pendingBlockHeight, pendingParam, updatePresent,
                    validationOutcome>>

SelectRealReplay ==
    \* App and state at S; use real app for stored block S+1:
    \* internal/consensus/replay.go:399-415,491-498.
    /\ phase = "handshake"
    /\ blockStoreHeight = stateStoreHeight + 1
    /\ appHeight = stateStoreHeight
    /\ pendingBlockHeight' = blockStoreHeight
    /\ phase' = "blockStored"
    /\ replayMutatesState' = TRUE
    /\ coverage' = coverage \cup {"realReplaySelected"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    pendingParam, updatePresent, validationOutcome>>

SelectMockReplay ==
    \* App already at B; load saved response and mutate State with mock app:
    \* internal/consensus/replay.go:417-433.
    /\ phase = "handshake"
    /\ blockStoreHeight = stateStoreHeight + 1
    /\ appHeight = blockStoreHeight
    /\ responseHeight = blockStoreHeight
    /\ pendingBlockHeight' = blockStoreHeight
    /\ phase' = "blockStored"
    /\ replayMutatesState' = TRUE
    /\ coverage' = coverage \cup {"mockReplaySelected"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    pendingParam, updatePresent, validationOutcome>>

CompleteHandshake ==
    \* Normal startup follows equality/replay cases: replay.go:385-438.
    /\ phase = "handshake"
    /\ appHeight = blockStoreHeight
    /\ stateStoreHeight = blockStoreHeight
    /\ stateHeight = stateStoreHeight
    /\ phase' = "normal"
    /\ replayMutatesState' = FALSE
    /\ coverage' = coverage \cup {"handshakeComplete"}
    /\ UNCHANGED <<blockStoreHeight, appHeight, stateStoreHeight, stateHeight,
                    activeParam, persistedParam, lastParamChange,
                    persistedLastParamChange, responseHeight, responseParam,
                    pendingBlockHeight, pendingParam, updatePresent,
                    validationOutcome>>

EnvironmentStutter ==
    \* Bounded model endpoint; unrelated next-height consensus is out of scope.
    /\ phase = "normal"
    /\ blockStoreHeight = MaxHeight
    /\ UNCHANGED vars

Next ==
    \/ SaveBlock
    \/ ApplyBlockStart
    \/ \E p \in ParamOrNone : FinalizeBlock(p)
    \/ SaveFinalizeBlockResponse
    \/ UpdateStateAccepted
    \/ UpdateStateRejected
    \/ CommitApp
    \/ SaveState
    \/ AbortRejectedApply
    \/ Crash
    \/ \E h \in 0..MaxHeight : AppReportsOlderHeight(h)
    \/ BeginHandshake
    \/ ReplayAppBlock
    \/ SelectRealReplay
    \/ SelectMockReplay
    \/ CompleteHandshake
    \/ EnvironmentStutter

TypeOK ==
    /\ blockStoreHeight \in 0..MaxHeight
    /\ appHeight \in 0..MaxHeight
    /\ stateStoreHeight \in 0..MaxHeight
    /\ stateHeight \in 0..MaxHeight
    /\ activeParam \in Params
    /\ persistedParam \in Params
    /\ lastParamChange \in Nat
    /\ persistedLastParamChange \in Nat
    /\ responseHeight \in 0..MaxHeight
    /\ responseParam \in ParamOrNone
    /\ phase \in Phases
    /\ replayMutatesState \in BOOLEAN
    /\ pendingBlockHeight \in 0..MaxHeight
    /\ pendingParam \in ParamOrNone
    /\ updatePresent \in BOOLEAN
    /\ validationOutcome \in ValidationOutcomes
    /\ coverage \subseteq {"blockStored", "applyStarted", "finalized",
                            "responseSaved", "acceptedUpdate",
                            "rejectedUpdate", "appCommitted", "stateSaved",
                            "rejectedAbort", "crashed", "appReportedOlder",
                            "handshakeStarted", "appOnlyReplay",
                            "realReplaySelected", "mockReplaySelected",
                            "handshakeComplete"}

PersistedHeightRelationships ==
    /\ stateStoreHeight <= blockStoreHeight
    /\ blockStoreHeight <= stateStoreHeight + 1
    /\ appHeight <= blockStoreHeight

SuccessfulApplyAdvancesExactlyOne ==
    phase \in {"updated", "committed"} =>
        /\ stateHeight = stateStoreHeight + 1
        /\ stateHeight = pendingBlockHeight

RejectedUpdateDoesNotInstall ==
    phase = "rejected" =>
        /\ stateHeight = stateStoreHeight
        /\ activeParam = persistedParam
        /\ lastParamChange = persistedLastParamChange

ParameterUpdateReflected ==
    (phase \in {"updated", "committed"} /\ updatePresent) =>
        /\ pendingParam \in ValidParams
        /\ activeParam = pendingParam
        /\ lastParamChange = pendingBlockHeight + 1

NormalPhaseIsSynchronized ==
    phase = "normal" =>
        /\ appHeight = blockStoreHeight
        /\ stateStoreHeight = blockStoreHeight
        /\ stateHeight = stateStoreHeight
        /\ activeParam = persistedParam
        /\ lastParamChange = persistedLastParamChange

RecoveryNormalOnlySupported ==
    (phase = "normal" /\ "handshakeStarted" \in coverage) =>
        /\ "handshakeComplete" \in coverage
        /\ appHeight = blockStoreHeight
        /\ stateStoreHeight = blockStoreHeight

=============================================================================
