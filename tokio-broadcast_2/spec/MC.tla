---- MODULE MC ----
\* ========================================================================
\* Model checking spec for tokio::sync::broadcast.
\*
\* Fault model coverage:
\*   5.1 Interleaving:    via per-step actions in base.tla
\*                         (Send_/Recv_/NotifyRx_/RecvDrop_/RxDrop_/TxDrop_)
\*   5.2 Cancellation:    RecvDrop_* (Recv future drop while parked)
\*   5.3 OOM:             skipped (no allocation in normal path)
\*   5.4 CAS_weak:        skipped (no CAS-weak in modeled paths)
\*   5.5 MemOrder:        PickRelaxedSite + RecvDrop_LoadQueued_Acquire
\*   5.6 ABA:             skipped (no pointer reclaim)
\*   5.7 Caller misuse:   AdversarialClientHarness, counter-bounded
\*                         Subscribe / Send / Receiver-Drop / Sender-Drop
\*   5.8 Lost wakeup:     covered structurally via Recv_ / NotifyRx_ splits
\*                         plus CloseFn liveness checks
\* ========================================================================

EXTENDS base

\* MC counters for fault-injection actions.
VARIABLES
    cRelaxOrdering        \* Family 4: bound on PickRelaxedSite firings (1)

mcVars == << cRelaxOrdering >>

\* MCInit: base Init + counters at 0.
MCInit ==
    /\ Init
    /\ cRelaxOrdering = 0

\* ----- Wrapped fault-injection actions -----

\* Family 4: only allow one ordering downgrade per run.
MCPickRelaxedSite(site) ==
    /\ cRelaxOrdering < 1
    /\ PickRelaxedSite(site)
    /\ cRelaxOrdering' = cRelaxOrdering + 1

\* All other actions pass through unchanged from base — no counter bound on
\* Send/Subscribe/RxDrop/TxDrop because the base spec already bounds them
\* via cSubscribe, cSend, cDropRecv, cDropSend.  Add UNCHANGED mcVars.

MCNext ==
    \/ /\ \E s \in Sender :
            \/ Send_AcquireTail(s)
            \/ Send_NoReceiversReturn(s)
            \/ \E v \in Value : Send_BumpPos(s, v)
            \/ Send_LockSlot(s)
            \/ Send_WriteSlot(s)
            \/ Send_DropSlot(s)
            \/ Send_NotifyRx_Enter(s)
            \/ TxDrop_FetchSub(s)
            \/ TxDrop_CloseChannelEnter(s)
            \/ TxDrop_NotifyEnter(s)
            \/ TxDrop_Finish(s)
            \/ TxDrop_AfterClose(s)
            \/ TxClone(s)
       /\ UNCHANGED mcVars
    \/ /\ \E r \in Receiver :
            \/ Subscribe(r)
            \/ Recv_PollEnter(r)
            \/ Recv_LockSlotFirst(r)
            \/ Recv_HitFastPath(r)
            \/ Recv_DropSlotForTail(r)
            \/ Recv_LockTail(r)
            \/ Recv_RelockSlot(r)
            \/ Recv_RecheckMatch(r)
            \/ Recv_EmptyClosed(r)
            \/ Recv_ParkAsWaiter(r)
            \/ Recv_LaggedFastForward(r)
            \/ RecvDrop_Begin(r)
            \/ RecvDrop_LoadQueued_Acquire(r)
            \/ RecvDrop_LockTail_Reread(r)
            \/ RecvDrop_RereadAndUnlink(r)
            \/ RecvDrop_FinishIdle(r)
            \/ RxDrop_Begin(r)
            \/ RxDrop_LockTailDecCnt(r)
            \/ RxDrop_DropTail(r)
            \/ RxDrop_DrainStep(r)
            \/ RxDrop_Finish(r)
       /\ UNCHANGED mcVars
    \/ /\ \E r \in Receiver : NotifyRx_DrainStep_Take(r)
       /\ UNCHANGED mcVars
    \/ /\ NotifyRx_DropTail
       /\ UNCHANGED mcVars
    \/ /\ \E r \in Receiver : NotifyRx_WakeOne(r)
       /\ UNCHANGED mcVars
    \/ /\ NotifyRx_Finish
       /\ UNCHANGED mcVars
    \/ \E site \in RelaxSites : MCPickRelaxedSite(site)

MCSpec == MCInit /\ [][MCNext]_<<vars, mcVars>>

\* ----- Symmetry reduction -----
\* Receivers and Senders are interchangeable for symmetry, but only when no
\* per-id state is asymmetric.  To stay safe, we apply symmetry only to the
\* Receiver and Sender sets.
Symmetry == Permutations(Receiver) \cup Permutations(Sender)

\* View excludes counters from state hashing (so different counter values
\* with otherwise identical states are not separate states for the purpose
\* of fingerprint deduplication... but TLC requires View to include all
\* user-visible state, so we just include vars).
View == << vars >>

\* ----- Temporal properties (liveness) -----
\* Family 1: NoLostWakeup_Sender — every parked receiver eventually wakes if
\* a Send completes after parking.  Approximation: notifyExtracted always
\* eventually drains.
NotifyEventuallyDrains == [](notifyPC /= "idle" => <>(notifyPC = "idle"))

\* Family 1: NumTxZeroEventuallyClosed — once numTx hits 0, closed flips.
NumTxZeroEventuallyClosed == [](numTx = 0 => <>tailClosed)

\* Family 2: DrainTerminates — every RxDrop drain loop terminates.
DrainTerminates ==
    \A r \in Receiver :
        [](rxDropPC[r] = "draining" => <>(rxDropPC[r] = "idle"))

LivenessProperties ==
    /\ NotifyEventuallyDrains
    /\ NumTxZeroEventuallyClosed
    /\ DrainTerminates

====
