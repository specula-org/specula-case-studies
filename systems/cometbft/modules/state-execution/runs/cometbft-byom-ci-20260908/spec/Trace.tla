------------------------------- MODULE Trace -------------------------------
EXTENDS base, Json, IOUtils, Sequences, TLC

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/apply_valid.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0
ASSUME TraceLog[1].event.name \in {"BlockStored", "HandshakeStart"}

TraceStateParams ==
    {TraceLog[k].event.state.activeParam : k \in 1..Len(TraceLog)}
    \cup {TraceLog[k].event.state.persistedParam : k \in 1..Len(TraceLog)}

ProposedIndexes ==
    {k \in 1..Len(TraceLog) :
        /\ "proposedParam" \in DOMAIN TraceLog[k].event.msg
        /\ TraceLog[k].event.msg.proposedParam /= NoParam}

TraceProposedParams ==
    {TraceLog[k].event.msg.proposedParam : k \in ProposedIndexes}

TraceParams == TLCEval(TraceStateParams \cup TraceProposedParams)

AcceptedIndexes ==
    {k \in ProposedIndexes : TraceLog[k].event.name = "UpdateStateAccepted"}

TraceValidParams == TLCEval(
    TraceStateParams
    \cup {TraceLog[k].event.msg.proposedParam : k \in AcceptedIndexes})

TraceInitialParam == TraceLog[1].event.state.persistedParam

VARIABLE l
traceVars == <<vars, l>>

logline == TraceLog[l]

TraceInit ==
    LET s == TraceLog[1].event.state IN
    /\ l = 1
    /\ IF TraceLog[1].event.name = "BlockStored"
       THEN
         \* Reconstruct the pre-save state from the first post-save event.
         \* SaveBlock is at internal/consensus/state.go:1781-1790.
         /\ blockStoreHeight = s.blockStoreHeight - 1
         /\ appHeight = s.appHeight
         /\ stateStoreHeight = s.stateStoreHeight
         /\ stateHeight = s.stateStoreHeight
         /\ activeParam = s.persistedParam
         /\ persistedParam = s.persistedParam
         /\ lastParamChange = s.persistedLastParamChange
         /\ persistedLastParamChange = s.persistedLastParamChange
         /\ responseHeight = s.responseHeight
         /\ responseParam = s.responseParam
         /\ phase = "normal"
         /\ replayMutatesState = FALSE
         /\ pendingBlockHeight = 0
         /\ pendingParam = NoParam
         /\ updatePresent = FALSE
         /\ validationOutcome = "none"
         /\ coverage = {}
       ELSE
         \* Handshake trace starts after Info; reconstruct the down state.
         \* internal/consensus/replay.go:240-267.
         /\ blockStoreHeight = s.blockStoreHeight
         /\ appHeight = s.appHeight
         /\ stateStoreHeight = s.stateStoreHeight
         /\ stateHeight = s.stateHeight
         /\ activeParam = s.activeParam
         /\ persistedParam = s.persistedParam
         /\ lastParamChange = s.lastParamChange
         /\ persistedLastParamChange = s.persistedLastParamChange
         /\ responseHeight = s.responseHeight
         /\ responseParam = s.responseParam
         /\ phase = "down"
         /\ replayMutatesState = FALSE
         /\ pendingBlockHeight = 0
         /\ pendingParam = NoParam
         /\ updatePresent = FALSE
         /\ validationOutcome = "none"
         /\ coverage = {}

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

StepTrace == l' = l + 1

ValidatePostState ==
    LET s == logline.event.state IN
    /\ blockStoreHeight' = s.blockStoreHeight
    /\ appHeight' = s.appHeight
    /\ stateStoreHeight' = s.stateStoreHeight
    /\ stateHeight' = s.stateHeight
    /\ activeParam' = s.activeParam
    /\ persistedParam' = s.persistedParam
    /\ lastParamChange' = s.lastParamChange
    /\ persistedLastParamChange' = s.persistedLastParamChange
    /\ responseHeight' = s.responseHeight
    /\ responseParam' = s.responseParam
    /\ phase' = s.phase
    /\ replayMutatesState' = s.replayMutatesState
    /\ pendingBlockHeight' = s.pendingBlockHeight
    /\ pendingParam' = s.pendingParam
    /\ updatePresent' = (s.pendingParam /= NoParam)
    /\ validationOutcome' = s.validationOutcome

BlockStoredIfLogged ==
    /\ IsEvent("BlockStored")
    /\ SaveBlock
    /\ ValidatePostState
    /\ StepTrace

ApplyBlockStartIfLogged ==
    /\ IsEvent("ApplyBlockStart")
    /\ ApplyBlockStart
    /\ ValidatePostState
    /\ StepTrace

FinalizeBlockIfLogged ==
    /\ IsEvent("FinalizeBlock")
    /\ FinalizeBlock(logline.event.msg.proposedParam)
    /\ ValidatePostState
    /\ StepTrace

SaveFinalizeBlockResponseIfLogged ==
    /\ IsEvent("SaveFinalizeBlockResponse")
    /\ SaveFinalizeBlockResponse
    /\ ValidatePostState
    /\ StepTrace

UpdateStateAcceptedIfLogged ==
    /\ IsEvent("UpdateStateAccepted")
    /\ UpdateStateAccepted
    /\ ValidatePostState
    /\ StepTrace

UpdateStateRejectedIfLogged ==
    /\ IsEvent("UpdateStateRejected")
    /\ UpdateStateRejected
    /\ ValidatePostState
    /\ StepTrace

CommitAppIfLogged ==
    /\ IsEvent("CommitApp")
    /\ CommitApp
    /\ ValidatePostState
    /\ StepTrace

SaveStateIfLogged ==
    /\ IsEvent("SaveState")
    /\ SaveState
    /\ ValidatePostState
    /\ StepTrace

HandshakeStartIfLogged ==
    /\ IsEvent("HandshakeStart")
    /\ BeginHandshake
    /\ ValidatePostState
    /\ StepTrace

ReplayAppBlockIfLogged ==
    /\ IsEvent("ReplayAppBlock")
    /\ ReplayAppBlock
    /\ ValidatePostState
    /\ StepTrace

ReplayStateBlockStartIfLogged ==
    /\ IsEvent("ReplayStateBlockStart")
    /\ IF logline.event.msg.mode = "real"
       THEN SelectRealReplay
       ELSE /\ logline.event.msg.mode = "mock"
            /\ SelectMockReplay
    /\ ValidatePostState
    /\ StepTrace

HandshakeCompleteIfLogged ==
    /\ IsEvent("HandshakeComplete")
    /\ CompleteHandshake
    /\ ValidatePostState
    /\ StepTrace

TraceStep ==
    \/ BlockStoredIfLogged
    \/ ApplyBlockStartIfLogged
    \/ FinalizeBlockIfLogged
    \/ SaveFinalizeBlockResponseIfLogged
    \/ UpdateStateAcceptedIfLogged
    \/ UpdateStateRejectedIfLogged
    \/ CommitAppIfLogged
    \/ SaveStateIfLogged
    \/ HandshakeStartIfLogged
    \/ ReplayAppBlockIfLogged
    \/ ReplayStateBlockStartIfLogged
    \/ HandshakeCompleteIfLogged

TraceNext ==
    \/ TraceStep
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceVars
    /\ WF_traceVars(TraceStep)

TraceMatched == <>(l > Len(TraceLog))

=============================================================================
