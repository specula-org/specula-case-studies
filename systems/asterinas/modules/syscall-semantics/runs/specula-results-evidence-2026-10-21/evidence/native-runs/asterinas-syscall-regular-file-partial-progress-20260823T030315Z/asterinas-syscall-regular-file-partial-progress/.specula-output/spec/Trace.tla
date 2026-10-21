------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category B timebox replay.  The harness emits one event for every base
\* action into per-execution-actor NDJSON streams; preprocessing may
\* concatenate them without imposing a cross-actor order.  start/end intervals
\* recover the real-time partial order.  Device completion actors remain
\* separate from the logical syscall owners carried in args.owner.

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

TaggedIndexes ==
    {i \in DOMAIN TraceLog : TraceLog[i].tag = "trace"}

\* Timebox actors are execution contexts.  Most events execute in their
\* logical syscall owner, but asynchronous BIO completion keeps its driver /
\* bottom-half actor and carries the submitting task separately in args.owner.
TraceActors == {TraceLog[i].tid : i \in TaggedIndexes}
TraceOwners == {TraceLog[i].args.owner : i \in TaggedIndexes}

EventIndexes(actor) ==
    {i \in TaggedIndexes : TraceLog[i].tid = actor}

NthIndex(indexes, n) ==
    CHOOSE i \in indexes :
        Cardinality({j \in indexes : j <= i}) = n

ThreadTrace(actor) ==
    [n \in 1..Cardinality(EventIndexes(actor)) |->
        TraceLog[NthIndex(EventIndexes(actor), n)]]

traces == [actor \in TraceActors |-> ThreadTrace(actor)]

VARIABLE tracePc

traceVars == <<tracePc>>
allTraceVars == <<vars, tracePc>>

ThreadsWithEvents ==
    {actor \in TraceActors : tracePc[actor] <= Len(traces[actor])}

\* An event can run only when no other pending event completed before it
\* started.  Overlapping intervals remain unordered and TLC explores both.
ViablePIDs ==
    {actor \in ThreadsWithEvents :
        ~\E other \in ThreadsWithEvents :
            /\ other # actor
            /\ traces[other][tracePc[other]].end
                < traces[actor][tracePc[actor]].start}

SeqToSet(sequence) == {sequence[i] : i \in DOMAIN sequence}

CapturedCommitCount(entries, effect) ==
    IF \E i \in DOMAIN entries : entries[i].key = effect
    THEN LET matching ==
            CHOOSE i \in DOMAIN entries : entries[i].key = effect
         IN entries[matching].count
    ELSE 0

TraceInputWellFormed ==
    \* A validation run must contain semantic events for every configured
    \* cooperating thread.  Empty, wholly untagged, or partial inputs cannot
    \* satisfy TraceMatched at initialization.
    /\ TaggedIndexes # {}
    /\ TraceActors # {}
    /\ TraceOwners = Threads
    /\ \A i \in TaggedIndexes :
        /\ TraceLog[i].start <= TraceLog[i].end
        /\ TraceLog[i].shadow_order \in Nat
        /\ TraceLog[i].args.owner \in Threads
        /\ (TraceLog[i].event = "SubmittedBioComplete"
            \/ TraceLog[i].args.owner = TraceLog[i].tid)
    \* The postprocessor reconstructs ghost snapshots in a unique semantic
    \* transition order.  That order must respect nonoverlapping timeboxes and
    \* the preserved order within each actor stream.
    /\ \A i, j \in TaggedIndexes :
        /\ (i # j =>
            TraceLog[i].shadow_order # TraceLog[j].shadow_order)
        /\ (TraceLog[i].end < TraceLog[j].start =>
            TraceLog[i].shadow_order < TraceLog[j].shadow_order)
        /\ (i < j /\ TraceLog[i].tid = TraceLog[j].tid =>
            TraceLog[i].shadow_order < TraceLog[j].shadow_order)

\* Strong post-state validation.  `instrumentation-spec.md` reconstructs this
\* complete snapshot from observed deltas ordered at each semantic boundary.
ValidatePostState(t, event) ==
    \* Per-thread control path and operation parameters.
    /\ pc'[t] = event.state.pc
    /\ opKind'[t] = event.state.op_kind
    /\ backendMode'[t] = event.state.backend_mode
    /\ requested'[t] = event.state.requested
    /\ copied'[t] = event.state.copied
    /\ committed'[t] = event.state.committed
    /\ reported'[t] = event.state.reported
    /\ copiedTotal'[t] = event.state.copied_total
    /\ committedTotal'[t] = event.state.committed_total
    /\ visibleTotal'[t] = event.state.visible_total
    /\ reportedTotal'[t] = event.state.reported_total
    /\ result'[t] = event.state.result
    /\ entryResult'[t] = event.state.entry_result
    /\ copyFault'[t] = event.state.copy_fault
    /\ ioOffset'[t] = event.state.io_offset
    /\ explicitOffset'[t] = event.state.explicit_offset
    /\ appendMode'[t] = event.state.append_mode
    /\ oldFileSize'[t] = event.state.old_file_size
    /\ plannedEnd'[t] = event.state.planned_end
    /\ pageState'[t] = event.state.page_state
    /\ rangeClass'[t] = event.state.range_class
    /\ fileSizeSnapshot'[t] = event.state.file_size_snapshot
    /\ entryDataEpoch'[t] = event.state.entry_data_epoch
    /\ bufferEpochs'[t] = event.state.buffer_epochs
    /\ vectorIndex'[t] = event.state.vector_index
    \* These ghost functions can change entries for threads other than the
    \* logical owner, so the event captures and validates the whole function.
    /\ vectorIntervened' = event.state.vector_intervened_all
    /\ attemptId'[t] = event.state.attempt_id
    /\ effectToken'[t] = event.state.effect_token
    /\ directPart'[t] = event.state.direct_part
    /\ saRestart'[t] = event.state.sa_restart
    /\ restartPending'[t] = event.state.restart_pending
    /\ interruptibleBackend'[t] = event.state.interruptible_backend
    \* Shared OFD/backend state and contract shadow state.
    /\ ofdOffset' = event.state.ofd_offset
    /\ expectedOffset' = event.state.expected_offset
    /\ offsetOwner' = event.state.offset_owner
    /\ dataOwner' = event.state.data_owner
    /\ fileSize' = event.state.file_size
    /\ expectedFileSize' = event.state.expected_file_size
    /\ sizePublicationOwners' =
        SeqToSet(event.state.size_publication_owners)
    /\ dataEpoch' = event.state.data_epoch
    /\ pendingBios' = SeqToSet(event.state.pending_bios)
    /\ completedBios' = SeqToSet(event.state.completed_bios)
    /\ positionalOFDExpected' = event.state.positional_ofd_expected_all
    \* The harness emits sparse nonzero commit-count entries.  Reconstruct and
    \* compare the complete ghost function so replay cannot hide duplicates.
    /\ \A effect \in EffectDomain :
        commitCount'[effect] =
            CapturedCommitCount(event.state.commit_counts, effect)

TraceInit ==
    /\ Init
    \* TLC treats a false Init with zero initial states as a successful empty
    \* model.  Assert makes malformed/empty validation input fail explicitly.
    /\ Assert(TraceInputWellFormed,
              "trace must contain well-formed tagged events for every logical owner")
    /\ tracePc = [actor \in TraceActors |-> 1]

MatchEvent(actor, event) ==
    LET t == event.args.owner IN
    /\ t \in Threads
    \* Only completion may execute outside its submitting task's context.
    /\ (event.event = "SubmittedBioComplete" \/ t = actor)
    /\ CASE event.event = "SysReadStart" ->
                /\ SysReadStart(t, event.args.backend,
                                event.args.restartable)
                /\ ValidatePostState(t, event)
          [] event.event = "SysWriteStart" ->
                /\ SysWriteStart(t, event.args.backend,
                    event.args.requested, event.args.append_mode,
                    event.args.restartable, event.args.page_state)
                /\ ValidatePostState(t, event)
          [] event.event = "SysPread64Start" ->
                /\ SysPread64Start(t, event.args.backend,
                                   event.args.explicit_offset)
                /\ ValidatePostState(t, event)
          [] event.event = "SysPwrite64Start" ->
                /\ SysPwrite64Start(t, event.args.backend,
                    event.args.requested, event.args.explicit_offset,
                    event.args.page_state)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysReadvStart" ->
                /\ DoSysReadvStart(t, event.args.backend)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysWritevStart" ->
                /\ DoSysWritevStart(t, event.args.backend,
                                    event.args.page_state)
                /\ ValidatePostState(t, event)

          [] event.event = "InodeHandleReadAcquireOffset" ->
                /\ InodeHandleReadAcquireOffset(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleWriteAcquireOffset" ->
                /\ InodeHandleWriteAcquireOffset(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleReadAtBegin" ->
                /\ InodeHandleReadAtBegin(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleWriteAtBegin" ->
                /\ InodeHandleWriteAtBegin(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleWriteChooseAppendStart" ->
                /\ InodeHandleWriteChooseAppendStart(t)
                /\ ValidatePostState(t, event)
          [] event.event = "RamInodeReadAtSnapshotSize" ->
                /\ RamInodeReadAtSnapshotSize(t)
                /\ ValidatePostState(t, event)
          [] event.event = "Ext2InodeWriteAtZeroLengthReturn" ->
                /\ Ext2InodeWriteAtZeroLengthReturn(t)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsAcquireData" ->
                /\ FileOpsAcquireData(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeInnerPrepareWrite" ->
                /\ InodeInnerPrepareWrite(t)
                /\ ValidatePostState(t, event)
          [] event.event = "RamInodeWriteAtPublishMetadata" ->
                /\ RamInodeWriteAtPublishMetadata(t)
                /\ ValidatePostState(t, event)

          [] event.event = "FileOpsReadAtCopyComplete" ->
                /\ FileOpsReadAtCopyComplete(t)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsReadAtCopyFaultZero" ->
                /\ FileOpsReadAtCopyFaultZero(t)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsReadAtCopyFaultPositive" ->
                /\ FileOpsReadAtCopyFaultPositive(t)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsWriteAtCopyComplete" ->
                /\ FileOpsWriteAtCopyComplete(t)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsWriteAtCopyFaultZero" ->
                /\ FileOpsWriteAtCopyFaultZero(t, event.state.page_state)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsWriteAtCopyFaultPositive" ->
                /\ FileOpsWriteAtCopyFaultPositive(
                    t, event.state.page_state, event.args.retained_prefix)
                /\ ValidatePostState(t, event)
          [] event.event = "BioSegmentWriteFallibleComplete" ->
                /\ BioSegmentWriteFallibleComplete(t)
                /\ ValidatePostState(t, event)
          [] event.event = "BioSegmentWriteFallibleFaultZero" ->
                /\ BioSegmentWriteFallibleFaultZero(t)
                /\ ValidatePostState(t, event)
          [] event.event = "BioSegmentWriteFallibleFaultPositive" ->
                /\ BioSegmentWriteFallibleFaultPositive(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InterruptibleBackendReturnEintr" ->
                /\ InterruptibleBackendReturnEintr(t)
                /\ ValidatePostState(t, event)

          [] event.event = "FileOpsReadAtFinish" ->
                /\ FileOpsReadAtFinish(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeInnerReadDirectAtFinish" ->
                /\ InodeInnerReadDirectAtFinish(t)
                /\ ValidatePostState(t, event)
          [] event.event = "VmoWritePagesWithBackendFinishSuccess" ->
                /\ VmoWritePagesWithBackendFinishSuccess(t)
                /\ ValidatePostState(t, event)
          [] event.event = "VmoWritePagesWithBackendFaultRetain" ->
                /\ VmoWritePagesWithBackendFaultRetain(t)
                /\ ValidatePostState(t, event)
          [] event.event = "VmoWritePagesWithBackendFaultDiscard" ->
                /\ VmoWritePagesWithBackendFaultDiscard(t)
                /\ ValidatePostState(t, event)
          [] event.event = "VmoWriteAnonymousPagesFinishSuccess" ->
                /\ VmoWriteAnonymousPagesFinishSuccess(t)
                /\ ValidatePostState(t, event)
          [] event.event = "VmoWriteAnonymousPagesFinishFault" ->
                /\ VmoWriteAnonymousPagesFinishFault(t)
                /\ ValidatePostState(t, event)
          [] event.event = "BioSubmit" ->
                /\ BioSubmit(t)
                /\ ValidatePostState(t, event)
          [] event.event = "SubmittedBioComplete" ->
                /\ SubmittedBioComplete(event.args.bio)
                /\ event.args.bio[1] = t
                /\ ValidatePostState(t, event)
          [] event.event = "IoBatchWaitAll" ->
                /\ IoBatchWaitAll(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeInnerWriteDirectAtCommit" ->
                /\ InodeInnerWriteDirectAtCommit(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeInnerWriteDirectAtRollback" ->
                /\ InodeInnerWriteDirectAtRollback(t)
                /\ ValidatePostState(t, event)
          [] event.event = "FileOpsReleaseData" ->
                /\ FileOpsReleaseData(t)
                /\ ValidatePostState(t, event)

          [] event.event = "InodeHandleReadReturnOk" ->
                /\ InodeHandleReadReturnOk(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleReadReturnError" ->
                /\ InodeHandleReadReturnError(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleWriteReturnOk" ->
                /\ InodeHandleWriteReturnOk(t)
                /\ ValidatePostState(t, event)
          [] event.event = "InodeHandleWriteReturnError" ->
                /\ InodeHandleWriteReturnError(t)
                /\ ValidatePostState(t, event)

          [] event.event = "DoSysReadvEntryOkContinue" ->
                /\ DoSysReadvEntryOkContinue(t)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysReadvEntryOkReturn" ->
                /\ DoSysReadvEntryOkReturn(t)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysReadvEntryFaultReturn" ->
                /\ DoSysReadvEntryFaultReturn(t)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysWritevEntryOkContinue" ->
                /\ DoSysWritevEntryOkContinue(t)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysWritevEntryOkReturn" ->
                /\ DoSysWritevEntryOkReturn(t)
                /\ ValidatePostState(t, event)
          [] event.event = "DoSysWritevEntryFaultReturn" ->
                /\ DoSysWritevEntryFaultReturn(t)
                /\ ValidatePostState(t, event)

          [] event.event = "SysReadReturn" ->
                /\ SysReadReturn(t)
                /\ ValidatePostState(t, event)
          [] event.event = "SysWriteReturn" ->
                /\ SysWriteReturn(t)
                /\ ValidatePostState(t, event)
          [] event.event = "SysPread64Return" ->
                /\ SysPread64Return(t)
                /\ ValidatePostState(t, event)
          [] event.event = "SysPwrite64Return" ->
                /\ SysPwrite64Return(t)
                /\ ValidatePostState(t, event)
          [] event.event = "SysReadTranslateEintr" ->
                /\ SysReadTranslateEintr(t)
                /\ ValidatePostState(t, event)
          [] event.event = "SysWriteTranslateEintr" ->
                /\ SysWriteTranslateEintr(t)
                /\ ValidatePostState(t, event)
          [] event.event = "HandlePendingSignalClassify" ->
                /\ HandlePendingSignalClassify(t)
                /\ ValidatePostState(t, event)
          [] event.event = "HandlePendingSignalRestart" ->
                /\ HandlePendingSignalRestart(t)
                /\ ValidatePostState(t, event)
          [] event.event = "HandlePendingSignalNoRestart" ->
                /\ HandlePendingSignalNoRestart(t)
                /\ ValidatePostState(t, event)
          [] event.event = "TaskRestartSyscall" ->
                /\ TaskRestartSyscall(t)
                /\ ValidatePostState(t, event)

          [] OTHER -> FALSE

\* Every semantic boundary is instrumented 1:1, so no base action is permitted
\* to fire silently between events.  This avoids unconstrained silent replay.
TraceNext ==
    \/ /\ ThreadsWithEvents # {}
       /\ \E actor \in ViablePIDs :
            LET event == traces[actor][tracePc[actor]] IN
            /\ MatchEvent(actor, event)
            /\ tracePc' = [tracePc EXCEPT ![actor] = @ + 1]
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allTraceVars

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_allTraceVars
    /\ WF_allTraceVars(TraceNext)

TraceMatched == <>(ThreadsWithEvents = {})

TraceTypeOK ==
    /\ TypeOK
    /\ tracePc \in [TraceActors -> Nat \ {0}]

=============================================================================
