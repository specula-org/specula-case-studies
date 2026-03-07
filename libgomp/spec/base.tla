--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for libgomp's flat barrier protocol (Patch 3/5).
 *
 * Derived from: gcc/libgomp/config/linux/bar.c, bar.h, futex_waitv.h, team.c, task.c
 * Bug Families: 1 (Futex_waitv Fallback), 2 (Cancellation Flag Cleanup),
 *               3 (BAR_HOLDING_SECONDARIES Lifecycle), 4 (Team ABA)
 *
 * Models the implementation's actual control flow under sequential consistency.
 * Each action annotated with source file:line references.
 *)

EXTENDS Integers, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Thread          \* Set of thread IDs {0, 1, 2, ...}; 0 is primary
CONSTANT MaxBarriers     \* Max barrier rounds to explore
CONSTANT MaxTasks        \* Max tasks that can be scheduled
CONSTANT Nil             \* Sentinel for "none"

\* Barrier type constants
CONSTANTS
    BarrierNormal,       \* Non-cancellable barrier (gomp_team_barrier_wait)
    BarrierFinal,        \* Final barrier with BAR_HOLDING_SECONDARIES (gomp_team_barrier_wait_final)
    BarrierCancel        \* Cancellable barrier (gomp_team_barrier_wait_cancel)

\* ============================================================================
\* DERIVED CONSTANTS
\* ============================================================================

Primary    == 0
Secondaries == Thread \ {Primary}
NumThreads == Cardinality(Thread)

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Global barrier state (bar.h:47-62: gomp_barrier_t) ---
VARIABLE generation      \* Nat: global generation counter (bar.h:58)
VARIABLE taskPending     \* BOOLEAN: BAR_TASK_PENDING flag (bar.h:69)
VARIABLE waitingForTask  \* BOOLEAN: BAR_WAITING_FOR_TASK flag (bar.h:74)
VARIABLE cancelled       \* BOOLEAN: BAR_CANCELLED flag (bar.h:75)
VARIABLE secondaryArrived \* BOOLEAN: BAR_SECONDARY_ARRIVED on generation (bar.h:79)
VARIABLE holding         \* BOOLEAN: BAR_HOLDING_SECONDARIES flag (bar.h:83)
VARIABLE taskCount       \* Nat: team->task_count

\* --- Per-thread local state (bar.h:41-45: thread_lock_data) ---
VARIABLE threadGen       \* [Thread -> Nat]: threadgens[i].gen
VARIABLE primaryWaiting  \* [Thread -> BOOLEAN]: PRIMARY_WAITING_TG on threadgens[i].gen (bar.h:106)

\* --- Extension 2: Cancellation (Family 2) ---
VARIABLE cancelArrived   \* BOOLEAN: BAR_SECONDARY_CANCELLABLE_ARRIVED (bar.h:80)
VARIABLE threadCGen      \* [Thread -> Nat]: threadgens[i].cgen
VARIABLE primaryWaitingC \* [Thread -> BOOLEAN]: PRIMARY_WAITING_TG on threadgens[i].cgen

\* --- Thread control flow ---
VARIABLE pc              \* [Thread -> String]: program counter per thread
VARIABLE scanIndex       \* Nat: which secondary the primary is currently checking
VARIABLE barrierRound    \* Nat: current barrier round number
VARIABLE barrierType     \* BarrierNormal | BarrierFinal | BarrierCancel

\* --- Extension 3: BAR_HOLDING_SECONDARIES lifecycle (Family 3) ---
VARIABLE prevHolding     \* BOOLEAN: secondaries held from previous barrier round

\* --- Extension 4: Team ABA (Family 4) ---
VARIABLE teamId          \* Nat: current team identity
VARIABLE threadTeamId    \* [Thread -> Nat]: team identity each thread believes it's on
VARIABLE threadBarPtr    \* [Thread -> Nat]: barrier pointer captured at handle_tasks entry

\* ============================================================================
\* VARIABLE GROUPS
\* ============================================================================

globalBarVars  == <<generation, taskPending, waitingForTask, cancelled,
                    secondaryArrived, holding, taskCount>>
threadGenVars  == <<threadGen, primaryWaiting>>
cancelVars     == <<cancelArrived, threadCGen, primaryWaitingC>>
controlVars    == <<pc, scanIndex, barrierRound, barrierType>>
holdingVars    == <<prevHolding>>
teamVars       == <<teamId, threadTeamId, threadBarPtr>>

allVars == <<globalBarVars, threadGenVars, cancelVars, controlVars, holdingVars, teamVars>>

\* ============================================================================
\* TYPE INVARIANT
\* ============================================================================

TypeOK ==
    /\ generation \in Nat
    /\ taskPending \in BOOLEAN
    /\ waitingForTask \in BOOLEAN
    /\ cancelled \in BOOLEAN
    /\ secondaryArrived \in BOOLEAN
    /\ holding \in BOOLEAN
    /\ taskCount \in Nat
    /\ threadGen \in [Thread -> Nat]
    /\ primaryWaiting \in [Thread -> BOOLEAN]
    /\ cancelArrived \in BOOLEAN
    /\ threadCGen \in [Thread -> Nat]
    /\ primaryWaitingC \in [Thread -> BOOLEAN]
    /\ pc \in [Thread -> STRING]
    /\ scanIndex \in Nat
    /\ barrierRound \in Nat
    /\ barrierType \in {BarrierNormal, BarrierFinal, BarrierCancel}
    /\ prevHolding \in BOOLEAN
    /\ teamId \in Nat
    /\ threadTeamId \in [Thread -> Nat]
    /\ threadBarPtr \in [Thread -> Nat]

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Check if thread t is the primary thread
IsPrimary(t) == t = Primary

\* Check if thread's gen is incremented past the barrier's entry generation
\* Models: bar.h:396-407 gomp_barrier_state_is_incremented
\* For non-cancel: threadGen[t] > generation means arrived
ThreadArrived(t) == threadGen[t] > generation

\* All secondaries have arrived at the current barrier
AllSecondariesArrived ==
    \A t \in Secondaries : ThreadArrived(t)

\* Models: bar.h:410-423 gomp_barrier_has_completed
\* Returns TRUE if barrier has advanced past the entry state
BarrierCompleted(entryGen) ==
    IF holding
    THEN TRUE   \* bar.h:414-421: HOLDING state means primary has completed
    ELSE generation > entryGen

\* ============================================================================
\* INIT
\* ============================================================================

Init ==
    \* Global barrier state
    /\ generation = 0
    /\ taskPending = FALSE
    /\ waitingForTask = FALSE
    /\ cancelled = FALSE
    /\ secondaryArrived = FALSE
    /\ holding = FALSE
    /\ taskCount = 0
    \* Per-thread generation
    /\ threadGen = [t \in Thread |-> 0]
    /\ primaryWaiting = [t \in Thread |-> FALSE]
    \* Cancel extensions
    /\ cancelArrived = FALSE
    /\ threadCGen = [t \in Thread |-> 0]
    /\ primaryWaitingC = [t \in Thread |-> FALSE]
    \* Control flow: all threads start approaching barrier
    /\ pc = [t \in Thread |-> "idle"]
    /\ scanIndex = 1  \* Primary starts scanning from thread 1
    /\ barrierRound = 0
    /\ barrierType = BarrierNormal
    \* Holding lifecycle
    /\ prevHolding = FALSE
    \* Team ABA
    /\ teamId = 0
    /\ threadTeamId = [t \in Thread |-> 0]
    /\ threadBarPtr = [t \in Thread |-> 0]

\* ============================================================================
\* ACTIONS: BARRIER ENTRY
\* ============================================================================

(*
 * Primary enters barrier.
 * Models: bar.h:236-259 gomp_barrier_wait_start (for id==0)
 *         bar.h:256-258: if (id == 0) ret |= BAR_WAS_LAST
 * Primary always considers itself "last" — it will scan all secondaries.
 *)
PrimaryEnterBarrier ==
    /\ pc[Primary] = "idle"
    /\ ~prevHolding  \* team.c:34-50: gomp_release_held_threads must fire first
    /\ barrierRound < MaxBarriers
    /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
    /\ scanIndex' = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
        \* Start scanning from lowest secondary ID
    \* bar.h:270-272: ALL threads (including primary) increment cgen at cancel barrier entry
    /\ IF barrierType = BarrierCancel
       THEN /\ threadCGen' = [threadCGen EXCEPT ![Primary] = threadCGen[Primary] + 1]
            /\ UNCHANGED <<globalBarVars, threadGenVars, primaryWaiting,
                           cancelArrived, primaryWaitingC>>
       ELSE /\ UNCHANGED <<globalBarVars, threadGenVars, cancelVars>>
    /\ UNCHANGED <<barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Secondary enters non-cancellable barrier.
 * Models: bar.h:236-259 gomp_barrier_wait_start (for id!=0)
 *         bar.c:103-129 gomp_assert_and_increment_flag
 * Secondary atomically increments its own threadGen.
 *)
SecondaryEnterBarrier(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "idle"
    /\ barrierType # BarrierCancel
    \* bar.c:111: __atomic_fetch_add(&arr[id].gen, BAR_INCR, MEMMODEL_RELEASE)
    /\ threadGen' = [threadGen EXCEPT ![t] = threadGen[t] + 1]
    /\ pc' = [pc EXCEPT ![t] = "sec_arrived"]
    /\ UNCHANGED <<globalBarVars, primaryWaiting, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Secondary checks if PRIMARY_WAITING_TG was set when it incremented.
 * Models: bar.c:118-128 in gomp_assert_and_increment_flag
 *         The fetch_add returned the OLD value; if PRIMARY_WAITING_TG was set,
 *         secondary must notify primary via BAR_SECONDARY_ARRIVED.
 *)
SecondaryCheckFallback(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "sec_arrived"
    /\ IF primaryWaiting[t]
       THEN \* bar.c:118-123: orig == (gen | PRIMARY_WAITING_TG)
            \* Set BAR_SECONDARY_ARRIVED on bar->generation
            /\ secondaryArrived' = TRUE
            /\ pc' = [pc EXCEPT ![t] = "waiting"]
            /\ UNCHANGED <<generation, taskPending, waitingForTask, cancelled,
                           holding, taskCount>>
       ELSE \* bar.c:126-127: normal case, no fallback needed
            /\ pc' = [pc EXCEPT ![t] = "waiting"]
            /\ UNCHANGED globalBarVars
    /\ UNCHANGED <<threadGenVars, cancelVars, scanIndex, barrierRound,
                   barrierType, holdingVars, teamVars>>

(*
 * Secondary enters cancellable barrier.
 * Models: bar.h:261-275 gomp_barrier_wait_cancel_start (for id!=0)
 *         bar.c:588-629 gomp_assert_and_increment_cancel_flag
 *)
SecondaryEnterCancelBarrier(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "idle"
    /\ barrierType = BarrierCancel
    /\ ~cancelled  \* bar.h:266: if (!(ret & BAR_CANCELLED) && id != 0)
    \* bar.c:600: __atomic_fetch_add(&arr[id].cgen, BAR_CANCEL_INCR, MEMMODEL_RELEASE)
    /\ threadCGen' = [threadCGen EXCEPT ![t] = threadCGen[t] + 1]
    \* Also mark threadGen as barrier entry counter (for completion detection).
    \* In impl, secondary waits on bar->generation which advances by BAR_CANCEL_INCR.
    /\ threadGen' = [threadGen EXCEPT ![t] = threadGen[t] + 1]
    /\ pc' = [pc EXCEPT ![t] = "sec_cancel_arrived"]
    /\ UNCHANGED <<globalBarVars, primaryWaiting,
                   cancelArrived, primaryWaitingC,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Secondary checks fallback for cancellable barrier.
 * Models: bar.c:608-628 in gomp_assert_and_increment_cancel_flag
 *)
SecondaryCheckCancelFallback(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "sec_cancel_arrived"
    /\ IF primaryWaitingC[t]
       THEN \* bar.c:608-621: PRIMARY_WAITING_TG was set
            IF cancelled
            THEN \* bar.c:617-619: cancel happened, clear the flag
                 /\ cancelArrived' = cancelArrived  \* Don't set — it would just be cleared
                 /\ pc' = [pc EXCEPT ![t] = "cancel_waiting"]
            ELSE \* bar.c:610-611: set BAR_SECONDARY_CANCELLABLE_ARRIVED
                 /\ cancelArrived' = TRUE
                 /\ pc' = [pc EXCEPT ![t] = "cancel_waiting"]
       ELSE /\ pc' = [pc EXCEPT ![t] = "cancel_waiting"]
            /\ UNCHANGED cancelArrived
    /\ UNCHANGED <<globalBarVars, threadGenVars, primaryWaiting,
                   threadCGen, primaryWaitingC,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Secondary sees BAR_CANCELLED at cancel barrier entry.
 * Models: bar.c:860-861 in gomp_team_barrier_wait_cancel
 *)
SecondarySeeCancelled(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "idle"
    /\ barrierType = BarrierCancel
    /\ cancelled
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<globalBarVars, threadGenVars, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

\* ============================================================================
\* ACTIONS: PRIMARY SCANNING (ensure_last / ensure_cancel_last)
\* ============================================================================

(*
 * Primary checks current secondary's thread-local gen.
 * Models: bar.c:315-338 in gomp_team_barrier_ensure_last
 *         bar.c:316: threadgen = __atomic_load_n(&arr[i].gen, MEMMODEL_ACQUIRE)
 *         bar.c:331-338: if threadgen != tstate && !(threadgen & PRIMARY_WAITING_TG)
 *)
PrimaryCheckThread ==
    /\ pc[Primary] = "scanning"
    /\ scanIndex \in Secondaries
    /\ barrierType # BarrierCancel
    /\ IF ThreadArrived(scanIndex) /\ ~primaryWaiting[scanIndex]
       THEN \* bar.c:331-338: threadgen != tstate && !(threadgen & PRIMARY_WAITING_TG)
            \* Thread arrived AND PRIMARY_WAITING_TG is not set — advance to next
            /\ UNCHANGED <<globalBarVars, threadGenVars>>
            /\ IF scanIndex = CHOOSE t \in Secondaries : \A s \in Secondaries : t >= s
               THEN \* All secondaries checked — all arrived
                    /\ pc' = [pc EXCEPT ![Primary] = "all_arrived"]
                    /\ UNCHANGED scanIndex
               ELSE \* Move to next secondary
                    /\ scanIndex' = scanIndex + 1
                    /\ UNCHANGED pc
       ELSE \* Thread hasn't arrived yet, OR PRIMARY_WAITING_TG still set
            \* bar.c:345-346: check bar->generation for flags
            IF taskPending
            THEN \* bar.c:350-351: handle tasks
                 /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task"]
                 /\ UNCHANGED <<scanIndex, globalBarVars, threadGenVars>>
            ELSE IF secondaryArrived
            THEN \* bar.c:352-380: BAR_SECONDARY_ARRIVED — fallback path
                 \* Clear BAR_SECONDARY_ARRIVED and PRIMARY_WAITING_TG
                 /\ secondaryArrived' = FALSE
                 /\ primaryWaiting' = [primaryWaiting EXCEPT ![scanIndex] = FALSE]
                 /\ pc' = [pc EXCEPT ![Primary] = "scanning"]  \* retry this thread
                 /\ UNCHANGED <<generation, taskPending, waitingForTask,
                                cancelled, holding, taskCount,
                                threadGen, scanIndex>>
            ELSE \* bar.c:400-401: neither changed, enter futex_waitv/fallback
                 /\ pc' = [pc EXCEPT ![Primary] = "enter_fallback"]
                 /\ UNCHANGED <<globalBarVars, threadGenVars, scanIndex>>
    /\ UNCHANGED <<cancelVars, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Primary checks current secondary's cgen (cancel barrier).
 * Models: bar.c:644-717 in gomp_team_barrier_ensure_cancel_last
 *)
PrimaryCheckCancelThread ==
    /\ pc[Primary] = "scanning"
    /\ scanIndex \in Secondaries
    /\ barrierType = BarrierCancel
    /\ IF threadCGen[scanIndex] > threadCGen[Primary] - 1
       THEN \* Thread arrived (cgen incremented past entry)
            \* Clear primaryWaitingC if it was set during fallback (bit is embedded in
            \* cgen value in impl; here we must explicitly clear the separate boolean)
            /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ UNCHANGED <<cancelArrived, threadCGen>>
            /\ IF scanIndex = CHOOSE t \in Secondaries : \A s \in Secondaries : t >= s
               THEN /\ pc' = [pc EXCEPT ![Primary] = "all_arrived"]
                    /\ UNCHANGED scanIndex
               ELSE /\ scanIndex' = scanIndex + 1
                    /\ UNCHANGED pc
       ELSE IF cancelled
       THEN \* bar.c:674-688: cancel detected during scan
            /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ pc' = [pc EXCEPT ![Primary] = "cancel_detected"]
            /\ UNCHANGED <<scanIndex, cancelArrived, threadCGen>>
       ELSE IF cancelArrived
       THEN \* bar.c:690-704: BAR_SECONDARY_CANCELLABLE_ARRIVED
            /\ cancelArrived' = FALSE
            /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]  \* retry
            /\ UNCHANGED <<scanIndex, threadCGen>>
       ELSE IF taskPending
       THEN /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task"]
            /\ UNCHANGED <<scanIndex, cancelVars>>
       ELSE \* Enter fallback for cancel
            /\ pc' = [pc EXCEPT ![Primary] = "enter_cancel_fallback"]
            /\ UNCHANGED <<scanIndex, cancelVars>>
    /\ UNCHANGED <<globalBarVars, threadGenVars, barrierRound, barrierType,
                   holdingVars, teamVars>>

\* ============================================================================
\* ACTIONS: FUTEX_WAITV FALLBACK (Family 1)
\* ============================================================================

(*
 * Primary enters fallback: sets PRIMARY_WAITING_TG on threadgens[scanIndex].gen.
 * Models: futex_waitv.h:87: __atomic_fetch_or(addr, PRIMARY_WAITING_TG, MEMMODEL_RELAXED)
 *
 * Two cases after fetch_or:
 * 1) Secondary already arrived (threadGen incremented) — detect and return
 * 2) Secondary not arrived — enter wait state
 *)
PrimaryEnterFallback ==
    /\ pc[Primary] = "enter_fallback"
    /\ IF ThreadArrived(scanIndex)
       THEN \* futex_waitv.h:102-124: secondary arrived before us
            \* Clear PRIMARY_WAITING_TG (it was just set by fetch_or)
            /\ primaryWaiting' = [primaryWaiting EXCEPT ![scanIndex] = FALSE]
            \* Return to scanning loop; PrimaryCheckThread will advance scanIndex
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
            /\ UNCHANGED scanIndex
       ELSE \* futex_waitv.h:126: futex_wait(addr2, val2) — wait on bar->generation
            /\ primaryWaiting' = [primaryWaiting EXCEPT ![scanIndex] = TRUE]
            /\ pc' = [pc EXCEPT ![Primary] = "fallback_waiting"]
            /\ UNCHANGED scanIndex
    /\ UNCHANGED <<globalBarVars, threadGen, cancelVars,
                   barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Primary wakes from fallback wait (futex_wait returned).
 * Can be woken by: BAR_TASK_PENDING, BAR_SECONDARY_ARRIVED, or spurious wakeup.
 * Models: bar.c:295-408 loop re-entry after futex_waitv
 *)
PrimaryWakeFromFallback ==
    /\ pc[Primary] = "fallback_waiting"
    \* Something must have changed in bar->generation for futex to return
    /\ \/ taskPending
       \/ secondaryArrived
       \/ ThreadArrived(scanIndex)  \* secondary arrived while we were setting up
    /\ pc' = [pc EXCEPT ![Primary] = "scanning"]  \* Go back to check loop
    /\ UNCHANGED <<globalBarVars, threadGenVars, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Primary enters cancel fallback.
 * Models: bar.c:712-714 futex_waitv for cancel path
 *)
PrimaryEnterCancelFallback ==
    /\ pc[Primary] = "enter_cancel_fallback"
    /\ IF threadCGen[scanIndex] > threadCGen[Primary] - 1
       THEN \* Secondary arrived before fallback
            /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = FALSE]
            \* Return to scanning loop; PrimaryCheckCancelThread will advance
            /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
            /\ UNCHANGED <<scanIndex, cancelArrived, threadCGen>>
       ELSE /\ primaryWaitingC' = [primaryWaitingC EXCEPT ![scanIndex] = TRUE]
            /\ pc' = [pc EXCEPT ![Primary] = "cancel_fallback_waiting"]
            /\ UNCHANGED <<scanIndex, cancelArrived, threadCGen>>
    /\ UNCHANGED <<globalBarVars, threadGenVars, primaryWaiting,
                   barrierRound, barrierType, holdingVars, teamVars>>

PrimaryWakeFromCancelFallback ==
    /\ pc[Primary] = "cancel_fallback_waiting"
    /\ \/ taskPending
       \/ cancelArrived
       \/ cancelled
       \/ threadCGen[scanIndex] > threadCGen[Primary] - 1
    /\ pc' = [pc EXCEPT ![Primary] = "scanning"]
    /\ UNCHANGED <<globalBarVars, threadGenVars, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

\* ============================================================================
\* ACTIONS: BARRIER COMPLETION
\* ============================================================================

(*
 * Primary: all secondaries arrived — complete barrier.
 * Models: bar.c:413-441 gomp_team_barrier_wait_end (for BAR_WAS_LAST)
 *
 * For BarrierNormal: increment generation, wake all.
 * For BarrierFinal: set BAR_HOLDING_SECONDARIES instead.
 * For BarrierCancel: increment cancel generation.
 *)
PrimaryCompleteBarrier ==
    /\ pc[Primary] = "all_arrived"
    /\ IF taskCount > 0
       THEN \* bar.c:429-434: tasks pending, handle them first
            /\ pc' = [pc EXCEPT ![Primary] = "primary_handle_task_last"]
            /\ waitingForTask' = TRUE
            /\ UNCHANGED <<generation, taskPending, cancelled,
                           secondaryArrived, holding, taskCount>>
       ELSE IF barrierType = BarrierFinal
       THEN \* bar.c:500-511: set BAR_HOLDING_SECONDARIES, primary continues
            /\ holding' = TRUE
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<generation, taskPending, waitingForTask,
                           cancelled, secondaryArrived, taskCount>>
       ELSE IF barrierType = BarrierCancel
       THEN IF cancelled
            THEN \* bar.c:746+: primary detects cancel after ensure_cancel_last
                 \* Undo cgen and return (same as PrimaryCancelDetected)
                 /\ pc' = [pc EXCEPT ![Primary] = "cancel_detected"]
                 /\ UNCHANGED <<generation, taskPending, waitingForTask, cancelled,
                                secondaryArrived, holding, taskCount>>
            ELSE \* bar.c:746-751: primary increments bar->generation by BAR_CANCEL_INCR
                 /\ generation' = generation + 1
                 /\ pc' = [pc EXCEPT ![Primary] = "done"]
                 /\ UNCHANGED <<taskPending, waitingForTask, cancelled,
                                secondaryArrived, holding, taskCount>>
       ELSE \* bar.c:437-439: normal barrier — increment generation
            /\ generation' = generation + 1
            /\ pc' = [pc EXCEPT ![Primary] = "done"]
            /\ UNCHANGED <<taskPending, waitingForTask, cancelled,
                           secondaryArrived, holding, taskCount>>
    /\ UNCHANGED <<threadGenVars, cancelVars, scanIndex, barrierRound,
                   barrierType, holdingVars, teamVars>>

(*
 * Primary after cancel detected during scan.
 * Models: bar.c:866: gomp_reset_cancellable_primary_threadgen
 *         Undo primary's cgen increment and return.
 *)
PrimaryCancelDetected ==
    /\ pc[Primary] = "cancel_detected"
    \* bar.h:285-286: fetch_sub to undo increment
    /\ threadCGen' = [threadCGen EXCEPT ![Primary] = threadCGen[Primary] - 1]
    /\ pc' = [pc EXCEPT ![Primary] = "done"]
    /\ UNCHANGED <<globalBarVars, threadGenVars, primaryWaiting,
                   cancelArrived, primaryWaitingC,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

\* ============================================================================
\* ACTIONS: SECONDARY WAITING
\* ============================================================================

(*
 * Secondary in wait loop sees generation incremented — barrier done.
 * Models: bar.c:468-469 in gomp_team_barrier_wait_end
 *         while (!gomp_barrier_state_is_incremented(gen, state, BAR_INCR))
 *)
SecondaryPassBarrier(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "waiting"
    \* bar.c:468-469: secondary sees generation incremented past its entry point
    \* The secondary entered with generation = G, threadGen[t] = G+1 (arrived).
    \* Barrier completes when global generation catches up: generation >= threadGen[t].
    /\ generation >= threadGen[t]
    /\ ~holding  \* If holding, secondaries must NOT proceed (bar.h:403-404)
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<globalBarVars, threadGenVars, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Secondary in cancel wait loop — either cancelled or barrier completes.
 * Models: bar.c:756-850 gomp_team_barrier_wait_cancel_end
 *
 * Implementation: secondary atomically reads bar->generation which contains
 * both the generation counter and BAR_CANCELLED bit. It checks BAR_CANCELLED
 * first (bar.c:760), but also verifies the cancel is from the CURRENT
 * generation (bar.c:762-764). If generation has advanced (barrier completed),
 * the cancel belongs to an old generation and is ignored.
 *
 * In the model: cancelled is separate from generation, so we guard the cancel
 * path with ~completed to match the implementation's generation check.
 *)
SecondaryPassCancelBarrier(t) ==
    /\ t \in Secondaries
    /\ pc[t] = "cancel_waiting"
    /\ LET completed == generation >= threadGen[t] /\ ~holding
       IN
       IF cancelled /\ ~completed
       THEN \* bar.c:828-830: cancel detected, barrier not yet completed — undo
            /\ threadCGen' = [threadCGen EXCEPT ![t] = threadCGen[t] - 1]
            /\ threadGen' = [threadGen EXCEPT ![t] = threadGen[t] - 1]
            /\ pc' = [pc EXCEPT ![t] = "done"]
       ELSE IF completed
       THEN \* Barrier completed — pass (cancel if any is from old generation)
            /\ pc' = [pc EXCEPT ![t] = "done"]
            /\ UNCHANGED <<threadCGen, threadGen>>
       ELSE FALSE  \* Neither cancelled nor completed — keep waiting
    /\ UNCHANGED <<globalBarVars, primaryWaiting,
                   cancelArrived, primaryWaitingC,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

\* Note: SecondaryTryHandleTaskWhileHeld is implicit — SecondaryPassBarrier
\* is DISABLED when holding=TRUE, and SecondaryHandleTask guards ~holding.
\* task.c:1601-1602: gomp_barrier_has_completed returns TRUE when holding,
\* so secondaries bail out of gomp_barrier_handle_tasks immediately.

\* ============================================================================
\* ACTIONS: TASK HANDLING (Family 1, 3, 4)
\* ============================================================================

(*
 * A task becomes pending (external event).
 * Models: some thread scheduling an OMP task during the parallel region.
 *)
ScheduleTask ==
    /\ taskCount < MaxTasks
    /\ taskCount' = taskCount + 1
    /\ taskPending' = TRUE
    /\ UNCHANGED <<generation, waitingForTask, cancelled, secondaryArrived,
                   holding, threadGenVars, cancelVars, controlVars,
                   holdingVars, teamVars>>

(*
 * Primary handles a task during scanning.
 * Models: bar.c:350-351: gomp_barrier_handle_tasks(gstate, bar, false)
 *         task.c:1551-1743
 *)
PrimaryHandleTask ==
    /\ pc[Primary] = "primary_handle_task"
    /\ taskPending
    \* task.c:1583: &team->barrier != bar check (Family 4)
    /\ threadTeamId[Primary] = teamId  \* No ABA — still on correct team
    /\ taskCount' = taskCount - 1
    /\ taskPending' = IF taskCount - 1 > 0 THEN TRUE ELSE FALSE
    /\ pc' = [pc EXCEPT ![Primary] = "scanning"]  \* Resume scanning
    /\ UNCHANGED <<generation, waitingForTask, cancelled, secondaryArrived,
                   holding, threadGenVars, cancelVars, scanIndex,
                   barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Primary handles task as the "last" thread (all arrived, tasks remain).
 * Models: task.c:1608-1657 — primary loop executing tasks then completing.
 *)
PrimaryHandleTaskLast ==
    /\ pc[Primary] = "primary_handle_task_last"
    /\ IF taskCount > 0 /\ taskPending
       THEN \* Execute a task
            /\ taskCount' = taskCount - 1
            /\ taskPending' = IF taskCount - 1 > 0 THEN TRUE ELSE FALSE
            /\ UNCHANGED <<generation, waitingForTask, cancelled,
                           secondaryArrived, holding, pc>>
       ELSE \* task.c:1646-1657: all tasks done, complete barrier
            IF barrierType = BarrierFinal
            THEN \* task.c:1649 with BAR_HOLDING_SECONDARIES
                 /\ holding' = TRUE
                 /\ waitingForTask' = FALSE
                 /\ pc' = [pc EXCEPT ![Primary] = "done"]
                 /\ UNCHANGED <<generation, taskPending, cancelled,
                                secondaryArrived, taskCount>>
            ELSE IF barrierType = BarrierCancel
            THEN IF cancelled
                 THEN \* Cancel detected during task handling — don't complete
                      /\ waitingForTask' = FALSE
                      /\ pc' = [pc EXCEPT ![Primary] = "cancel_detected"]
                      /\ UNCHANGED <<generation, taskPending, cancelled,
                                     secondaryArrived, holding, taskCount>>
                 ELSE /\ generation' = generation + 1
                      /\ waitingForTask' = FALSE
                      /\ pc' = [pc EXCEPT ![Primary] = "done"]
                      /\ UNCHANGED <<taskPending, cancelled,
                                     secondaryArrived, holding, taskCount>>
            ELSE \* task.c:1649: gomp_team_barrier_done + wake
                 /\ generation' = generation + 1
                 /\ waitingForTask' = FALSE
                 /\ pc' = [pc EXCEPT ![Primary] = "done"]
                 /\ UNCHANGED <<taskPending, cancelled, secondaryArrived,
                                holding, taskCount>>
    /\ UNCHANGED <<threadGenVars, cancelVars, scanIndex,
                   barrierRound, barrierType, holdingVars, teamVars>>

(*
 * Secondary handles a task while waiting.
 * Models: bar.c:453-457 in gomp_team_barrier_wait_end (task handling in wait loop)
 *         task.c:1551-1743 gomp_barrier_handle_tasks
 *)
SecondaryHandleTask(t) ==
    /\ t \in Secondaries
    /\ pc[t] \in {"waiting", "cancel_waiting"}
    /\ taskPending
    /\ ~holding  \* If holding, gomp_barrier_has_completed bails out (bar.h:414)
    \* task.c:1583: team barrier pointer check (Family 4)
    /\ threadTeamId[t] = teamId
    /\ taskCount > 0
    /\ taskCount' = taskCount - 1
    /\ taskPending' = IF taskCount - 1 > 0 THEN TRUE ELSE FALSE
    \* task.c:1608: secondaries call with wait_on_was_last=FALSE (bar.c:457)
    \* They execute tasks but CANNOT complete the barrier (goto no_task).
    \* Only the primary (wait_on_was_last=TRUE) can complete the barrier.
    /\ UNCHANGED <<generation, waitingForTask, holding,
                   cancelled, secondaryArrived, pc, threadGenVars, cancelVars,
                   scanIndex, barrierRound, barrierType, holdingVars, teamVars>>

\* ============================================================================
\* ACTIONS: CANCELLATION (Family 2)
\* ============================================================================

(*
 * Some thread cancels the barrier.
 * Models: bar.c:872-907 gomp_team_barrier_cancel
 *)
CancelBarrier ==
    /\ barrierType = BarrierCancel
    /\ ~cancelled
    \* bar.c:884: __atomic_fetch_or(&bar->generation, BAR_CANCELLED, MEMMODEL_RELAXED)
    /\ cancelled' = TRUE
    \* bar.c:902-904: if BAR_SECONDARY_CANCELLABLE_ARRIVED was set, clear it
    /\ cancelArrived' = FALSE
    /\ UNCHANGED <<generation, taskPending, waitingForTask, secondaryArrived,
                   holding, taskCount, threadGenVars, threadCGen,
                   primaryWaitingC, controlVars, holdingVars, teamVars>>

\* ============================================================================
\* ACTIONS: BAR_HOLDING_SECONDARIES LIFECYCLE (Family 3)
\* ============================================================================

(*
 * Primary releases held secondaries from PREVIOUS barrier round.
 * Models: team.c:34-50 gomp_release_held_threads
 *         team.c:47: gomp_team_barrier_done_final(pool->prev_barrier, team_id)
 *         bar.c:575-586: clears HOLDING, adds generation increment, wakes.
 *)
PrimaryReleasePrev ==
    /\ prevHolding
    /\ pc[Primary] = "idle"  \* Primary is setting up next region
    /\ generation' = generation + 1
    /\ holding' = FALSE
    /\ prevHolding' = FALSE
    /\ UNCHANGED <<taskPending, waitingForTask, cancelled, secondaryArrived,
                   taskCount, threadGenVars, cancelVars,
                   pc, scanIndex, barrierRound, barrierType, teamVars>>

(*
 * Primary completes a barrier round (was "done") — transitions to next round.
 * Models: team.c:1133-1225 gomp_team_end, then team.c:385-1126 gomp_team_start
 *)
PrimaryStartNextRound ==
    /\ pc[Primary] = "done"
    /\ \A t \in Secondaries :
         \/ pc[t] = "done"
         \/ (holding /\ pc[t] = "waiting")  \* Secondaries held from final barrier
    /\ IF holding
       THEN \* team.c:1222: pool->prev_barrier = &team->barrier
            /\ prevHolding' = TRUE
            /\ holding' = FALSE  \* Will be released in next round's PrimaryReleasePrev
       ELSE /\ prevHolding' = prevHolding
            /\ UNCHANGED holding
    /\ barrierRound' = barrierRound + 1
    \* Reset for next round
    /\ cancelled' = FALSE
    /\ secondaryArrived' = FALSE
    /\ cancelArrived' = FALSE
    /\ waitingForTask' = FALSE
    /\ taskPending' = FALSE
    /\ taskCount' = 0
    \* Family 4: new team (models team.c:753 __atomic_store_n(&nthr->ts.team,...))
    /\ teamId' = teamId + 1
    /\ threadTeamId' = [t \in Thread |-> teamId + 1]
    /\ threadBarPtr' = [t \in Thread |-> teamId + 1]
    \* Choose next barrier type non-deterministically
    /\ barrierType' \in {BarrierNormal, BarrierFinal, BarrierCancel}
    /\ pc' = [t \in Thread |-> "idle"]
    /\ scanIndex' = CHOOSE t \in Secondaries : \A s \in Secondaries : t <= s
    \* Team recreation: thread_lock_data initialized fresh (resets PRIMARY_WAITING_TG bits)
    /\ primaryWaiting' = [t \in Thread |-> FALSE]
    /\ primaryWaitingC' = [t \in Thread |-> FALSE]
    /\ UNCHANGED <<generation, threadGen, threadCGen>>

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

Next ==
    \/ PrimaryEnterBarrier
    \/ \E t \in Secondaries : SecondaryEnterBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckFallback(t)
    \/ \E t \in Secondaries : SecondaryEnterCancelBarrier(t)
    \/ \E t \in Secondaries : SecondaryCheckCancelFallback(t)
    \/ \E t \in Secondaries : SecondarySeeCancelled(t)
    \/ PrimaryCheckThread
    \/ PrimaryCheckCancelThread
    \/ PrimaryEnterFallback
    \/ PrimaryWakeFromFallback
    \/ PrimaryEnterCancelFallback
    \/ PrimaryWakeFromCancelFallback
    \/ PrimaryCompleteBarrier
    \/ PrimaryCancelDetected
    \/ \E t \in Secondaries : SecondaryPassBarrier(t)
    \/ \E t \in Secondaries : SecondaryPassCancelBarrier(t)
    \/ ScheduleTask
    \/ PrimaryHandleTask
    \/ PrimaryHandleTaskLast
    \/ \E t \in Secondaries : SecondaryHandleTask(t)
    \/ CancelBarrier
    \/ PrimaryReleasePrev
    \/ PrimaryStartNextRound

Spec == Init /\ [][Next]_allVars

\* ============================================================================
\* SAFETY INVARIANTS
\* ============================================================================

(*
 * Core: No secondary proceeds past barrier before all have arrived.
 * A secondary at "done" means it passed the barrier; at that point,
 * all secondaries must have incremented their threadGen.
 *)
BarrierSafety ==
    \A t \in Secondaries :
        pc[t] = "done" =>
            \A s \in Secondaries : threadGen[s] >= threadGen[t]

(*
 * Family 1: PRIMARY_WAITING_TG is cleared before the next barrier round starts.
 * When ALL threads are idle (round boundary), no flags should be set.
 * During a round, primary CAN set flags on secondaries that haven't entered yet.
 *)
FallbackCorrectness ==
    (\A t \in Thread : pc[t] = "idle") =>
        (\A t \in Thread : ~primaryWaiting[t] /\ ~primaryWaitingC[t])

(*
 * Family 2: BAR_SECONDARY_CANCELLABLE_ARRIVED is cleared before next cancel barrier.
 * When a new barrier round starts with BarrierCancel, cancelArrived must be FALSE.
 *)
CancelFlagCleanup ==
    (barrierType = BarrierCancel /\ \A t \in Thread : pc[t] = "idle")
        => ~cancelArrived

(*
 * Family 2: At cancellable barrier entry, thread-local cgen values are consistent.
 * All cgen values should be equal when entering a cancel barrier.
 *)
CgenConsistency ==
    (barrierType = BarrierCancel /\ \A t \in Thread : pc[t] = "idle")
        => \A s, t \in Thread : threadCGen[s] = threadCGen[t]

(*
 * Family 3: No secondary runs user code from next region while held.
 * If holding is TRUE, no secondary should be in "done" state
 * (done = ready to execute user code in next region).
 *)
HoldingCorrectness ==
    holding => \A t \in Secondaries : pc[t] # "done"

(*
 * Family 4: No secondary executes tasks from a different team.
 * In SecondaryHandleTask, the team check must match.
 * This is enforced by the action guard, but we check the invariant
 * that no thread's team pointer diverges while it's handling tasks.
 *)
TaskIsolation ==
    \A t \in Thread :
        (pc[t] \in {"waiting", "cancel_waiting"} /\ taskPending)
            => threadTeamId[t] = teamId

\* ============================================================================
\* STRENGTHENED SAFETY INVARIANTS
\* ============================================================================

(*
 * If waitingForTask is TRUE and no cancel has fired, all secondaries
 * must have already arrived. (Cancel can cause secondaries to undo
 * their arrival while primary is still handling tasks.)
 *)
WaitingForTaskImpliesAllArrived ==
    (waitingForTask /\ ~cancelled) => AllSecondariesArrived

(*
 * A secondary in waiting/cancel_waiting state must have already incremented
 * its threadGen (it arrived at the barrier).
 *)
SecondaryStateConsistency ==
    \A t \in Secondaries :
        pc[t] \in {"waiting", "cancel_waiting", "sec_arrived", "sec_cancel_arrived"}
            => threadGen[t] >= generation

(*
 * At the start of a new barrier round (all threads idle), no stale flags
 * should remain from the previous round.
 *)
NoStaleFlags ==
    (\A t \in Thread : pc[t] = "idle") =>
        /\ ~secondaryArrived
        /\ ~cancelArrived
        /\ ~waitingForTask

(*
 * BAR_HOLDING_SECONDARIES can only be set during a BarrierFinal round.
 *)
HoldingImpliesFinalType ==
    holding => barrierType = BarrierFinal

(*
 * If primaryWaiting[t] is TRUE for some secondary t, primary must be in
 * a scanning-related state (it set the flag and hasn't cleared it yet).
 *)
PrimaryFallbackConsistency ==
    \A t \in Secondaries :
        primaryWaiting[t] =>
            pc[Primary] \in {"scanning", "fallback_waiting",
                             "primary_handle_task", "enter_fallback"}

(*
 * No thread in an active barrier state (not idle, not done) should have
 * a mismatched team ID. Guards against use-after-free / team ABA.
 *)
NoUseAfterFree ==
    \A t \in Thread :
        pc[t] \notin {"idle", "done"} => threadTeamId[t] = teamId

\* ============================================================================
\* LIVENESS PROPERTIES
\* ============================================================================

(*
 * Family 1: If all secondaries eventually arrive, the barrier eventually completes.
 * Requires fairness on all actions.
 *)
DeadlockFreedom ==
    []<>(barrierRound > 0 \/ pc[Primary] = "done")

(*
 * Family 3: Held secondaries are eventually released.
 *)
HoldingRelease ==
    [](holding ~> ~holding)

===============================================================
