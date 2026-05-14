---- MODULE MC ----
(***************************************************************************)
(* Model-checking spec for DPDK rte_ring (Round 2).                        *)
(*                                                                         *)
(* Wraps the base spec with counter-bounded fault-injection actions:       *)
(*   - MCStaleHeadRTS        (Family A)                                    *)
(*   - MCMisuseAPI           (Family B)                                    *)
(*   - MCStaleConsTail       (Family C)                                    *)
(*   - MCStaleHeadSORing     (Family D.1)                                  *)
(*   - MCStaleTailSORing     (Family D.2)                                  *)
(*   - MCWrongReleaseN       (Family D.3)                                  *)
(*   - MCFtokenWrap          (Family D.4)                                  *)
(*   - MCMisuseFinishN       (Family E)                                    *)
(*                                                                         *)
(* Fault model coverage (concurrent-analysis.md § 5):                      *)
(*   5.1 Interleaving:    via per-step actions in base.tla (PC phases)     *)
(*   5.2 Cancellation:    n/a (synchronous API)                            *)
(*   5.3 OOM:             skipped (alloc on data path is rare; library     *)
(*                        documents abort on alloc failure)                 *)
(*   5.4 CAS_weak:        via CAS-failure branches in base.tla; no         *)
(*                        spurious-fail variant added (DPDK uses           *)
(*                        compare_exchange_strong)                          *)
(*   5.5 MemOrder:        MCStaleHeadRTS, MCStaleConsTail,                 *)
(*                        MCStaleHeadSORing, MCStaleTailSORing             *)
(*   5.6 ABA:             via RTS .cnt counter wrap (CntWrap small) +      *)
(*                        SORING ftoken wrap (PosWrap small)               *)
(*   5.7 Caller misuse:   MCMisuseAPI, MCWrongReleaseN, MCMisuseFinishN    *)
(*   5.8 Lost wakeup:     n/a (no wait/notify primitives)                  *)
(***************************************************************************)

EXTENDS base, Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Fault counters
\* ========================================================================

VARIABLES
    cStaleHeadRTS,      \* Family A
    cStaleConsTail,     \* Family C
    cStaleHeadSORing,   \* Family D.1
    cStaleTailSORing,   \* Family D.2
    cWrongReleaseN,     \* Family D.3
    cFtokenWrap,        \* Family D.4
    cMisuseAPI,         \* Family B
    cMisuseFinishN      \* Family E

faultVars == <<cStaleHeadRTS, cStaleConsTail, cStaleHeadSORing,
               cStaleTailSORing, cWrongReleaseN, cFtokenWrap,
               cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Bounds
\* ========================================================================

CONSTANTS
    MaxStaleHeadRTS,
    MaxStaleConsTail,
    MaxStaleHeadSORing,
    MaxStaleTailSORing,
    MaxWrongReleaseN,
    MaxFtokenWrap,
    MaxMisuseAPI,
    MaxMisuseFinishN

\* ========================================================================
\* MCInit
\* ========================================================================

MCInit ==
    /\ Init
    /\ cStaleHeadRTS = 0
    /\ cStaleConsTail = 0
    /\ cStaleHeadSORing = 0
    /\ cStaleTailSORing = 0
    /\ cWrongReleaseN = 0
    /\ cFtokenWrap = 0
    /\ cMisuseAPI = 0
    /\ cMisuseFinishN = 0

\* ========================================================================
\* Family A: MCStaleHeadRTS
\* Replaces RTSProdUpdateTail_LoadHead default with a stale snapshot.
\* The stale value is any (cnt,pos) previously observed by *some* thread
\* before the current rtsProdHeadPos (modeling missing acquire).
\* ========================================================================
MCStaleHeadRTS(t) ==
    /\ cStaleHeadRTS < MaxStaleHeadRTS
    /\ Mode = "RTS"
    /\ phase[t] = "RTSUpdateTail.LoadTail"
    /\ role[t] = "prod"
    \* Observe a possibly-stale view: any prior visibleProdHead that some
    \* thread captured.  In the simplest case, this is any thread's
    \* visibleProdHeadCnt/Pos pair.  We pick non-deterministically.
    /\ \E t2 \in Thread :
         locStaleHead' = [locStaleHead EXCEPT ![t] =
            [valid|->TRUE,
             cnt|->visibleProdHeadCnt[t2],
             pos|->visibleProdHeadPos[t2]]]
    /\ phase' = [phase EXCEPT ![t] = "RTSUpdateTail.Compute"]
    /\ cStaleHeadRTS' = cStaleHeadRTS + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars,
                   cStaleConsTail, cStaleHeadSORing, cStaleTailSORing,
                   cWrongReleaseN, cFtokenWrap, cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Family C: MCStaleConsTail
\* Producer load of consTail returns a stale prior value (line 104) in
\* default-mode move_head. Models the partial-order chain regression.
\* ========================================================================
MCStaleConsTail(t) ==
    /\ cStaleConsTail < MaxStaleConsTail
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.LoadHead"
    /\ role[t] = "prod"
    /\ \E v \in 0..(consTail) :   \* any prior tail value <= current
         visibleConsTail' = [visibleConsTail EXCEPT ![t] = v]
    /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadTail"]
    /\ cStaleConsTail' = cStaleConsTail + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleProdTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars,
                   cStaleHeadRTS, cStaleHeadSORing, cStaleTailSORing,
                   cWrongReleaseN, cFtokenWrap, cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Family D.1: MCStaleHeadSORing
\* SORING stage_move_head loads head with relaxed (soring.c:228); under
\* memory reordering, the value may be stale.  We model by capturing an
\* old head value and rolling it back relative to the current head.
\* ========================================================================
MCStaleHeadSORing(t, s, n) ==
    /\ cStaleHeadSORing < MaxStaleHeadSORing
    /\ Mode = "SORING"
    /\ phase[t] = "Idle"
    /\ s \in 0..(NbStage-1)
    /\ n \in 1..MaxBatch
    \* Use a stale (smaller) old_head than current sStageHead[s].
    /\ \E stale_head \in 0..sStageHead[s] :
         /\ stale_head < sStageHead[s]   \* truly stale
         /\ LET prev_tail ==
                 IF s = 0 THEN prodTail
                 ELSE sStageTailPos[s-1]
                avail == (0 + prev_tail - stale_head) % PosWrap
                actual_n == IF n > avail THEN 0 ELSE n
            IN
            /\ actual_n > 0
            \* Note: head CAS uses stale_head as the *expected* value, so
            \* if real head moved, the CAS would fail.  The bug is that
            \* the relaxed load lets us see a stale value at all.
            /\ sStageHead' = [sStageHead EXCEPT ![s] = WrapPos(stale_head + actual_n)]
            /\ phase' = [phase EXCEPT ![t] = "SORingAcquire.UpdateState"]
            /\ op' = [op EXCEPT ![t] = "acq"]
            /\ role' = [role EXCEPT ![t] = "cons"]
            /\ callMode' = [callMode EXCEPT ![t] = Mode]
            /\ stage' = [stage EXCEPT ![t] = s]
            /\ locOldHead' = [locOldHead EXCEPT ![t] = stale_head]
            /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(stale_head + actual_n)]
            /\ locReqN' = [locReqN EXCEPT ![t] = n]
            /\ locActualN' = [locActualN EXCEPT ![t] = actual_n]
            /\ locFtoken' = [locFtoken EXCEPT ![t] = (stale_head + s) % PosWrap]
            /\ locReleaseN' = [locReleaseN EXCEPT ![t] = actual_n]
            /\ locReservedSlots' = [locReservedSlots EXCEPT ![t] =
                 { SlotOf(stale_head + i - 1) : i \in 1..actual_n }]
    /\ cStaleHeadSORing' = cStaleHeadSORing + 1
    /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring, rtsVars,
                   historyVars, locVals, locStaleHead, sStageTailPos,
                   sStageTailSync, sStateFtoken, sStateStnum, sStateN,
                   visibleVars, staleVars, extVars,
                   cStaleHeadRTS, cStaleConsTail, cStaleTailSORing,
                   cWrongReleaseN, cFtokenWrap, cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Family D.2: MCStaleTailSORing
\* In SORingRelease_LoadTail (soring.c:483), the relaxed load of
\* stage tail.pos may return a stale prior value that equals "pos",
\* causing the thread to skip the finalize-from-release path even when
\* the slot is at the tail.
\* ========================================================================
MCStaleTailSORing(t) ==
    /\ cStaleTailSORing < MaxStaleTailSORing
    /\ Mode = "SORING"
    /\ phase[t] = "SORingRelease.LoadTail"
    /\ op[t] = "rel"
    \* Force the "tail /= pos" branch (skip finalize) even when tail = pos.
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ cStaleTailSORing' = cStaleTailSORing + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars,
                   cStaleHeadRTS, cStaleConsTail, cStaleHeadSORing,
                   cWrongReleaseN, cFtokenWrap, cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Family D.3: MCWrongReleaseN
\* Caller invokes soring_release with n != n_acquired.
\* Replaces the default SORingRelease_LoadState with a wrong-n choice.
\* ========================================================================
MCWrongReleaseN(t, delta) ==
    /\ cWrongReleaseN < MaxWrongReleaseN
    /\ Mode = "SORING"
    /\ phase[t] = "Idle"
    /\ delta \in {-1, 1}    \* off-by-one; widen if needed
    /\ \E s \in 0..(NbStage-1), idx \in 0..(Capacity-1) :
        /\ sStateStnum[s][idx] = "START"
        /\ stage' = [stage EXCEPT ![t] = s]
        /\ locFtoken' = [locFtoken EXCEPT ![t] = sStateFtoken[s][idx]]
        /\ locActualN' = [locActualN EXCEPT ![t] = sStateN[s][idx]]
        /\ locOldHead' = [locOldHead EXCEPT ![t] = sStateFtoken[s][idx] - s]
        /\ LET wrong_n == sStateN[s][idx] + delta IN
           locReleaseN' = [locReleaseN EXCEPT ![t] =
              IF wrong_n < 0 THEN 0 ELSE wrong_n]
    /\ phase' = [phase EXCEPT ![t] = "SORingRelease.Verify"]
    /\ op' = [op EXCEPT ![t] = "rel"]
    /\ role' = [role EXCEPT ![t] = "prod"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    /\ cWrongReleaseN' = cWrongReleaseN + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, locNewHead, locReqN,
                   locVals, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars,
                   cStaleHeadRTS, cStaleConsTail, cStaleHeadSORing,
                   cStaleTailSORing, cFtokenWrap, cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Family D.4: MCFtokenWrap
\* Force a position wrap so two acquires share the same (stage, ftoken).
\* This is enabled by setting PosWrap small in MC.cfg; this action just
\* ticks the wrap counter and signals that we entered the wrap regime.
\* ========================================================================
MCFtokenWrap ==
    /\ cFtokenWrap < MaxFtokenWrap
    /\ posWrapCount' = posWrapCount + 1
    /\ cFtokenWrap' = cFtokenWrap + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, threadVars, soringVars,
                   visibleVars, staleVars, misuseDetected, finalizeStuck,
                   overCommitted,
                   cStaleHeadRTS, cStaleConsTail, cStaleHeadSORing,
                   cStaleTailSORing, cWrongReleaseN, cMisuseAPI, cMisuseFinishN>>

\* ========================================================================
\* Family B: MCMisuseAPI
\* Caller invokes a mode-specific API (callMode=X) on a ring whose actual
\* sync_type is Mode != X.  We model by entering an enq path with
\* callMode[t] != Mode, then continuing through the same atomic actions.
\* This sets misuseDetected and triggers APIContractConsistent invariant.
\* ========================================================================
MCMisuseAPI(t, intended_mode) ==
    /\ cMisuseAPI < MaxMisuseAPI
    /\ Mode \in {"ST","MT","RTS","HTS"}
    /\ intended_mode \in {"ST","MT","RTS","HTS"} \ {Mode}
    /\ phase[t] = "Idle"
    /\ misuseDetected' = TRUE
    /\ callMode' = [callMode EXCEPT ![t] = intended_mode]
    /\ cMisuseAPI' = cMisuseAPI + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, phase, op, role, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars,
                   posWrapCount, finalizeStuck, overCommitted,
                   cStaleHeadRTS, cStaleConsTail, cStaleHeadSORing,
                   cStaleTailSORing, cWrongReleaseN, cFtokenWrap, cMisuseFinishN>>

\* ========================================================================
\* Family E: MCMisuseFinishN
\* Caller passes commit_n > reserved_n to peek finish.
\* ========================================================================
MCMisuseFinishN(t, commit) ==
    /\ cMisuseFinishN < MaxMisuseFinishN
    /\ Mode \in {"ST","HTS"}
    /\ phase[t] = "Peek.Start"
    /\ op[t] = "enq"
    /\ commit \in 0..(locActualN[t] + 1)
    /\ commit /= locActualN[t]
    /\ locReleaseN' = [locReleaseN EXCEPT ![t] = commit]
    /\ cMisuseFinishN' = cMisuseFinishN + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, phase, op, role, callMode,
                   stage, locOldHead, locNewHead, locReqN, locActualN,
                   locFtoken, locVals, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars, extVars,
                   cStaleHeadRTS, cStaleConsTail, cStaleHeadSORing,
                   cStaleTailSORing, cWrongReleaseN, cFtokenWrap, cMisuseAPI>>

\* ========================================================================
\* Wrap base actions to carry counter state UNCHANGED.
\* All non-fault actions pass through with faultVars unchanged.
\* ========================================================================

WrapNonFault(action) ==
    /\ action
    /\ UNCHANGED faultVars

\* ========================================================================
\* MCNext
\* ========================================================================

MCNext ==
    \/ \E t \in Thread, n \in 1..MaxBatch :
         WrapNonFault(\/ ProdMoveHead_LoadHead(t, n)
                      \/ ConsMoveHead_LoadHead(t, n)
                      \/ HTSProdHeadWait(t, n)
                      \/ HTSConsHeadWait(t, n)
                      \/ RTSProdHeadWait(t, n)
                      \/ RTSConsHeadWait(t, n)
                      \/ SORingAcquire_MoveHead(t, 0, n)
                      \/ (NbStage > 1 /\ SORingAcquire_MoveHead(t, 1, n))
                      \/ SORingRelease_LoadState(t, n)
                      \/ PeekStart(t, n))
    \/ \E t \in Thread :
         WrapNonFault(SORingProdEnqueue(t))
    \/ \E t \in Thread :
         WrapNonFault(\/ ProdMoveHead_LoadTail(t)
                      \/ ProdMoveHead_CAS(t)
                      \/ ProdWriteRing(t)
                      \/ ProdUpdateTail(t)
                      \/ ConsMoveHead_LoadTail(t)
                      \/ ConsMoveHead_CAS(t)
                      \/ ConsUpdateTail(t)
                      \/ HTSProdLoadStail(t) \/ HTSProdCAS(t) \/ HTSProdUpdateTail(t)
                      \/ HTSConsLoadStail(t) \/ HTSConsCAS(t) \/ HTSConsUpdateTail(t)
                      \/ RTSProdLoadStail(t) \/ RTSProdCAS(t)
                      \/ RTSProdUpdateTail_LoadTail(t)
                      \/ RTSProdUpdateTail_LoadHead(t)
                      \/ RTSProdUpdateTail_Compute(t)
                      \/ RTSProdUpdateTail_CAS(t)
                      \/ RTSConsLoadStail(t) \/ RTSConsCAS(t) \/ RTSConsUpdateTail(t)
                      \/ SORingAcquire_UpdateState(t)
                      \/ SORingRelease_Verify(t)
                      \/ SORingRelease_WriteRing(t)
                      \/ SORingRelease_StoreFinish(t)
                      \/ SORingRelease_LoadTail(t)
                      \/ SORingRelease_MaybeFinalize(t)
                      \/ SORingFinalize_LoadTail(t)
                      \/ SORingFinalize_CAS(t)
                      \/ SORingFinalize_LoadHead(t)
                      \/ SORingFinalize_WalkStates(t)
                      \/ SORingFinalize_StoreTail(t)
                      \/ PeekFinish(t))
    \* --- Fault-injection actions (counter-bounded) ---
    \/ \E t \in Thread :
         \/ MCStaleHeadRTS(t)
         \/ MCStaleConsTail(t)
         \/ MCStaleTailSORing(t)
    \/ \E t \in Thread, s \in 0..(NbStage-1), n \in 1..MaxBatch :
         MCStaleHeadSORing(t, s, n)
    \/ \E t \in Thread, delta \in {-1, 1} :
         MCWrongReleaseN(t, delta)
    \/ \E t \in Thread, im \in {"ST","MT","RTS","HTS"} \ {Mode} :
         MCMisuseAPI(t, im)
    \/ \E t \in Thread, c \in 0..(MaxBatch + 1) :
         MCMisuseFinishN(t, c)
    \/ MCFtokenWrap

MCSpec == MCInit /\ [][MCNext]_<<allVars, faultVars>>

\* ========================================================================
\* State constraint — bound the run so the 32-bit counter wrap (which is
\* impractical to model under bounded MC) does not become a counter-example
\* source during convergence.  Real DPDK uses a 32-bit counter with the
\* documented `in_flight < 2^31` invariant; we mimic that here by capping
\* nextVal so prodHead/consHead stay well below PosWrap.
\* ========================================================================
BoundedRun ==
    /\ nextVal <= Capacity + 2
    /\ posWrapCount <= 1

\* ========================================================================
\* Symmetry
\* ========================================================================

Symmetry == Permutations(Thread)

\* View — exclude counters so symmetric states with different counter
\* values still merge.  (This is conservative for hunting but keeps
\* convergence states small.)
View == <<allVars>>

\* ========================================================================
\* Temporal properties
\* ========================================================================

\* Eventually the system returns to all-Idle (no thread permanently stuck).
EventuallyQuiescent ==
    <>(\A t \in Thread : phase[t] = "Idle")

\* No FINISH at the tail of any stage forever (Family D.2 liveness).
EventuallyFinalized ==
    \A s \in 0..(NbStage-1) :
        []((sStageTailSync[s] = 0
            /\ sStateStnum[s][SlotOf(sStageTailPos[s])] = "FINISH")
           => <>(sStateStnum[s][SlotOf(sStageTailPos[s])] /= "FINISH"))

\* ========================================================================
\* MC-level invariants (alias to base ones)
\* ========================================================================

MC_RTSPosCntConsistent  == RTSPosCntConsistent
MC_APIContractConsistent == APIContractConsistent
MC_DefaultPartialOrder  == DefaultPartialOrder
MC_SORingStageOrdered   == SORingStageOrdered
MC_SORingNoStuckFinalize == SORingNoStuckFinalize
MC_SORingReleaseExact   == SORingReleaseExact
MC_SORingFtokenUnique   == SORingFtokenUnique
MC_PeekRollbackAtomic   == PeekRollbackAtomic
MC_ConsumedWasPushed    == ConsumedWasPushed
MC_NoDoublePop          == NoDoublePop

====
