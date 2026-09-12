---------------------------- MODULE MCContract ----------------------------
EXTENDS MC

ActiveCall(a) == calls[a].pc # "done"
    \/ (\E o \in Owners : writer[o].pc # "idle" /\ writer[o].call = a)
    \/ (\E p \in Pollers : dispatch[p].pc # "idle" /\ dispatch[p].call = a)

\* Forget only retired frame values and monotone, non-controlling audit journals.
\* Retired RequestIds are no longer compared; pending/accepted RequestIds remain live.
\* The invariant truth vector preserves all current safety observations.
ContractView ==
    <<durable, catalog,
      [o \in Owners |-> [owner[o] EXCEPT
          !.cachePoller = IF owner[o].readerLock = "free" THEN 0 ELSE @,
          !.gcCount = IF owner[o].gcPC = "result" THEN @ ELSE 0,
          !.gcBound = IF owner[o].gcPC = "idle" THEN 0 ELSE @,
          !.stopStep = IF owner[o].life = "stopping" THEN @ ELSE "none"]],
      writer,
      [o \in Owners |-> IF reader[o].pc = "idle" THEN IdleReader ELSE reader[o]],
      metadata,
      [p \in Pollers |-> IF dispatch[p].pc = "idle"
          THEN IdleDispatch ELSE dispatch[p]],
      [a \in CallIds |-> IF ActiveCall(a) THEN calls[a]
          ELSE [IdleCall EXCEPT !.pc = "done"]],
      history,
      [audit EXCEPT !.uncertain = {}, !.deleted = {}, !.fences = {}],
      cursor, faults,
      <<TypeOK, RecordIdentity, ReaderAccounting, CursorOrder,
        AcceptedWorkCovered, AckPrefixSound, DeletionSound,
        RangeConditionalWrite, ReplacementBeforeRelease, PerOwnerCursorMonotonic>>>>
\* UUID values are opaque. Choose one fresh alias while preserving live comparisons.
CanonicalRequestChoice == \A p \in Pollers :
    (dispatch[p].pc = "matched" /\ dispatch'[p].pc = "history") =>
       dispatch'[p].request = (CHOOSE q \in StartIds \ UsedStarts : TRUE)
ContractNext == Track(MCRawNext /\ CanonicalRequestChoice)
ContractSpec == MCInit /\ [][ContractNext]_mcvars
ContractLiveSpec == ContractSpec /\ ProcessingFairness
=============================================================================
