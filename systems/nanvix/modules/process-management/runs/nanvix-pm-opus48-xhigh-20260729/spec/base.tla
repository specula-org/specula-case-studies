------------------------------- MODULE base -------------------------------
(***************************************************************************)
(* TLA+ base specification of the Nanvix microkernel process-management    *)
(* subsystem (src/kernel/src/pm).                                          *)
(*                                                                         *)
(* Category B (concurrent / runtime).  Nanvix PM is single-core with       *)
(* interrupts disabled in the kernel and all atomics Relaxed (mod.rs:43),  *)
(* so there is NO weak-memory behavior.  The entire concurrency surface is *)
(* logical interleaving at explicit scheduling points: timer preemption    *)
(* (tick -> giveup -> schedule), voluntary blocking (sleep / join /        *)
(* Mutex::lock / Condvar::wait), and cross-process kill run by the procd    *)
(* daemon that mutates OTHER processes' state.  This spec models the        *)
(* two-level state machine (process-list membership x per-thread subset)    *)
(* and the sync / signal sub-state, splitting actions at real block /       *)
(* preempt / kcall-return boundaries so interleaving bugs are observable.   *)
(*                                                                         *)
(* Scenarios (modeling-brief.md section 2) and the findings they target:   *)
(*   S1  Incomplete "where a blocked thread lives" wakeup search set        *)
(*       (try_wakeup / interrupt_signal_candidate scan a subset of lists)   *)
(*       -> MC-1 NoLostNotify, MC-2 SignalReaches/SingleOwner               *)
(*   S2  Terminate/exit does not force-kill already-interrupted threads     *)
(*       -> MC-3 TerminatedThreadsDie                                       *)
(*   S3  running == None reentrancy in do_exit -> kernel panic              *)
(*       -> MC-4 RunningValidAtWakeup                                       *)
(*   S4  Reclaimable slots not reaped before cap rejection                  *)
(*       -> MC-5 AdmissionLiveness / NoSpuriousOOM                          *)
(*   S5  Blocking-sync cancellation half-releases ownership                 *)
(*       -> MC-6 CondWaitReturnsLocked, MC-7 SyncSlotConservation           *)
(*   S6  Signal pending/mask/disposition/lifecycle consistency              *)
(*       -> MC-8 MaskHonored, MC-9 NoImmortalPending                        *)
(*   S7  sigsuspend/sigreturn/SA_RESTART reentrancy corruption              *)
(*       -> MC-10a SavedMaskRestored (RestartAttribution removed: artifact)  *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Proc,           \* Universe of process slots (finite; "free" = not a live process)
    Thread,         \* Universe of thread slots
    Signal,         \* Modeled signal numbers (all blockable, default action = Terminate)
    MutexAddr,      \* Modeled mutex addresses
    CondAddr,       \* Modeled condition-variable addresses
    MaxProc,        \* Live-process cap  (config MAX_PROCESSES; small model value)
    MaxThread,      \* Live-thread cap   (config MAX_THREADS)
    MutexOpenMax,   \* Mutex-map cap     (config MUTEX_OPEN_MAX; get_mutex, state/mod.rs:612)
    NoProc,         \* Sentinel: no process (running slot empty during exit window)
    NoThread,       \* Sentinel: no thread
    NoCond,         \* Sentinel: no condition variable
    NoMask          \* Sentinel: Option<u64>::None for saved_blocked / restart record

ASSUME MaxProc \in Nat \ {0}
ASSUME MaxThread \in Nat \ {0}
ASSUME MutexOpenMax \in Nat \ {0}
ASSUME NoProc \notin Proc
ASSUME NoThread \notin Thread
ASSUME NoCond \notin CondAddr

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Core two-level lifecycle state (process-list x thread-subset) ---
\* ProcessManager holds five lists (manager/mod.rs:199-215):
\*   running: Option<RunningProcess>, ready, suspended, interrupted, zombies.
\* Each process holds thread subsets (running/ready/sleeping/interrupted/zombie).
\* A Runnable OR Interrupted process may still hold sleeping threads
\* (runnable.rs:60-62, interrupted.rs:41) -- the S1/S2 root cause.
VARIABLES
    procState,      \* [Proc -> {"free","running","ready","suspended","interrupted","zombie"}]
    running,        \* Proc \cup {NoProc}: occupant of the single running slot
    threadState,    \* [Thread -> {"free","running","ready","sleeping","interrupted","zombie"}]
    threadOwner,    \* [Thread -> Proc \cup {NoProc}]
    threadReason    \* [Thread -> {"none","killed","timedout","signaled"}]  (InterruptReason)

\* --- Exit / rendezvous window (Scenario 3) ---
VARIABLES
    exitPhase,      \* {"none","taken","cleaned"}: do_exit split (take_running->cleanup->reinsert)
    exiting,        \* Proc \cup {NoProc}: process currently in the do_exit window
    rvWaiter        \* [Thread -> Proc \cup {NoProc}]: t is a rendezvous counterpart blocked on rvWaiter[t]

\* --- Condvar notify/wake split (Scenario 1) ---
VARIABLES
    condWaiters,    \* [CondAddr -> Seq(Thread)]: FIFO waiter tids (condvar.rs:43)
    notifyReg,      \* Thread \cup {NoThread}: a dequeued-but-not-yet-woken waiter in flight
    notifyCond      \* CondAddr \cup {NoCond}: which condvar the in-flight notify came from

\* --- Sync ownership + refcount (Scenario 5) ---
VARIABLES
    mutexInMap,     \* [MutexAddr -> BOOLEAN]: entry present in process mutex map
    mutexExtraRef,  \* [MutexAddr -> BOOLEAN]: a failed lock_mutex left an unreclaimed reference
                    \* (refcount inflated above the put_mutex <=2 destroy threshold)
    mutexLocked,    \* [MutexAddr -> BOOLEAN]
    mutexOwner,     \* [MutexAddr -> Thread \cup {NoThread}]
    condInMap,      \* [CondAddr -> BOOLEAN]: entry present in process cond map
    held,           \* [Thread -> SUBSET MutexAddr]: mutexes owned by thread (guard held)
    syncPc,         \* [Thread -> {"idle","cw_wait","cw_woken"}]: cond_wait protocol PC
    cwCond,         \* [Thread -> CondAddr \cup {NoCond}]: condvar a cond_wait is parked on
    cwMutex         \* [Thread -> MutexAddr \cup {NoThread}]: mutex a cond_wait must reacquire

\* --- Signal control (Scenarios 6, 7) ---
\* SignalControl per process: dispositions[64], pending:u64, restorer (state/signal.rs:101).
\* ThreadState per thread: blocked:u64, saved_blocked:Option<u64>, restart:Option<KcallRestart>
\* (thread/state.rs:93,105,110).
VARIABLES
    pending,        \* [Proc -> SUBSET Signal]: process-directed pending set
    blocked,        \* [Thread -> SUBSET Signal]: per-thread blocked mask
    disposition,    \* [Proc -> [Signal -> {"default","ignore","handler"}]]
    saRestart,      \* [Proc -> [Signal -> BOOLEAN]]: SA_RESTART flag of an installed handler
    stopped,        \* [Proc -> BOOLEAN]: job-control stopped
    restorerSet,    \* [Proc -> BOOLEAN]: a restorer trampoline is registered
    savedBlocked,   \* [Thread -> (SUBSET Signal) \cup {NoMask}]: sigsuspend saved mask (Option)
    restart,        \* [Thread -> BOOLEAN]: a KcallRestart record is pending (signum-less)
    intrSig         \* [Thread -> Signal \cup {NoMask}]: signal that actually interrupted the call

\* --- Ghost bug-detection flags (each reflects a concrete buggy control-flow outcome) ---
VARIABLES
    panicked,               \* S3: a wakeup path read running while it was NoProc (get_running().expect)
    lostNotify,             \* S1: a still-sleeping waiter was consumed by notify but never woken
    signalDeliveryFailed,   \* S1/S6: interrupt_signal_candidate missed the sole eligible sleeper
    resumedAfterTerminate,  \* S2: a terminated process's thread resumed user code (reason != killed)
    condWaitBad,            \* S5: a wait_cond completed without holding the mutex
    maskViolated,           \* S6: a masked blockable signal took effect
    immortalPending,        \* S6: a pending caught signal became undeliverable after a disposition change
    savedMaskViolated,      \* S7: sigreturn restored the wrong pre-suspend mask
    restartMisattributed,   \* S7: SA_RESTART applied per a signal other than the interrupting one
    spuriousOOM,            \* S4: admission rejected while a reclaimable zombie awaited burial
    procTerminated          \* [Proc -> BOOLEAN]: terminate()/exit() was invoked on this process

\* Variable groups for UNCHANGED clauses.
coreVars   == <<procState, running, threadState, threadOwner, threadReason>>
exitVars   == <<exitPhase, exiting, rvWaiter>>
notifyVars == <<condWaiters, notifyReg, notifyCond>>
syncVars   == <<mutexInMap, mutexExtraRef, mutexLocked, mutexOwner, condInMap, held, syncPc, cwCond, cwMutex>>
sigVars    == <<pending, blocked, disposition, saRestart, stopped, restorerSet,
                savedBlocked, restart, intrSig>>
ghostVars  == <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate, condWaitBad,
                maskViolated, immortalPending, savedMaskViolated, restartMisattributed,
                spuriousOOM, procTerminated>>

vars == <<coreVars, exitVars, notifyVars, syncVars, sigVars, ghostVars>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Live processes: any slot that is not free (occupied from creation until the
\* corresponding zombie is buried -- manager/mod.rs live_count semantics).
LiveProcs   == { p \in Proc : procState[p] # "free" }
ZombieProcs == { p \in Proc : procState[p] = "zombie" }
LiveProcCount   == Cardinality(LiveProcs)
ZombieProcCount == Cardinality(ZombieProcs)

LiveThreads   == { t \in Thread : threadState[t] # "free" }
ZombieThreads == { t \in Thread : threadState[t] = "zombie" }
LiveThreadCount   == Cardinality(LiveThreads)

\* Thread slots that a zombie harvest would reclaim (on_thread_reaped drops the thread
\* live_count -- thread/mod.rs:272,281): the threads of a harvestable zombie process
\* (harvest_zombies -> pop_zombie_process, manager/mod.rs:3430,2441).  A zombie process
\* holds only zombie threads, so these are exactly the reclaimable-but-not-yet-reaped
\* thread slots that the reaping try_next_tid_reaping (fix #2495) would free on demand.
ReclaimableThreads     == { t \in Thread : threadOwner[t] \in Proc /\ procState[threadOwner[t]] = "zombie" }
ReclaimableThreadCount == Cardinality(ReclaimableThreads)

\* Threads belonging to a process, restricted to a given subset.
ThreadsOf(p)          == { t \in Thread : threadOwner[t] = p /\ threadState[t] # "free" }
ThreadsOfIn(p, subs)  == { t \in Thread : threadOwner[t] = p /\ threadState[t] \in subs }

\* Number of mutex-map entries currently present (bounded by MutexOpenMax on get_mutex).
MutexMapSize == Cardinality({ a \in MutexAddr : mutexInMap[a] })

\* A running process has exactly one thread in the "running" subset.
FreeThreadExists  == \E t \in Thread : threadState[t] = "free"
FreeProcExists    == \E p \in Proc : procState[p] = "free"

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    \* Start with a single running process p0 owning one running thread t0.
    /\ \E p0 \in Proc, t0 \in Thread :
         /\ procState = [p \in Proc |-> IF p = p0 THEN "running" ELSE "free"]
         /\ running = p0
         /\ threadState = [t \in Thread |-> IF t = t0 THEN "running" ELSE "free"]
         /\ threadOwner = [t \in Thread |-> IF t = t0 THEN p0 ELSE NoProc]
    /\ threadReason = [t \in Thread |-> "none"]
    /\ exitPhase = "none"
    /\ exiting = NoProc
    /\ rvWaiter = [t \in Thread |-> NoProc]
    /\ condWaiters = [c \in CondAddr |-> <<>>]
    /\ notifyReg = NoThread
    /\ notifyCond = NoCond
    /\ mutexInMap = [a \in MutexAddr |-> FALSE]
    /\ mutexExtraRef = [a \in MutexAddr |-> FALSE]
    /\ mutexLocked = [a \in MutexAddr |-> FALSE]
    /\ mutexOwner = [a \in MutexAddr |-> NoThread]
    /\ condInMap = [c \in CondAddr |-> FALSE]
    /\ held = [t \in Thread |-> {}]
    /\ syncPc = [t \in Thread |-> "idle"]
    /\ cwCond = [t \in Thread |-> NoCond]
    /\ cwMutex = [t \in Thread |-> NoThread]
    /\ pending = [p \in Proc |-> {}]
    /\ blocked = [t \in Thread |-> {}]
    /\ disposition = [p \in Proc |-> [s \in Signal |-> "default"]]
    /\ saRestart = [p \in Proc |-> [s \in Signal |-> FALSE]]
    /\ stopped = [p \in Proc |-> FALSE]
    /\ restorerSet = [p \in Proc |-> TRUE]   \* the loaded image registers a restorer at startup
    /\ savedBlocked = [t \in Thread |-> NoMask]
    /\ restart = [t \in Thread |-> FALSE]
    /\ intrSig = [t \in Thread |-> NoMask]
    /\ panicked = FALSE
    /\ lostNotify = FALSE
    /\ signalDeliveryFailed = FALSE
    /\ resumedAfterTerminate = FALSE
    /\ condWaitBad = FALSE
    /\ maskViolated = FALSE
    /\ immortalPending = FALSE
    /\ savedMaskViolated = FALSE
    /\ restartMisattributed = FALSE
    /\ spuriousOOM = FALSE
    /\ procTerminated = [p \in Proc |-> FALSE]

\* ========================================================================
\* Scheduling (tick / giveup / schedule and run())
\* ========================================================================

\* Schedule: pick a ready process and dispatch one of its ready threads.
\* Models take_earliest_ready() -> RunnableProcess::run() (runnable.rs:134-163)
\* wiring self.running = Some(next_process) (manager/mod.rs:1697,1803,2159).
\* Enabled only when the running slot is empty and no exit is mid-flight.
Schedule ==
    /\ running = NoProc
    /\ exitPhase = "none"
    /\ \E p \in Proc :
         /\ procState[p] = "ready"
         /\ \E t \in Thread :
              /\ threadOwner[t] = p
              /\ threadState[t] = "ready"
              /\ procState' = [procState EXCEPT ![p] = "running"]
              /\ running' = p
              /\ threadState' = [threadState EXCEPT ![t] = "running"]
              \* run() carries the resumed thread's interrupt reason to the dispatcher.
              /\ UNCHANGED threadOwner
              /\ threadReason' = threadReason
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars, ghostVars>>

\* Preempt: timer tick preempts the running thread (tick -> giveup -> schedule,
\* unsafe.rs). The running thread returns to its process's ready subset and the
\* process moves to the ready list, freeing the running slot for Schedule.
Preempt ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ threadState' = [threadState EXCEPT ![t] = "ready"]
    /\ procState' = [procState EXCEPT ![running] = "ready"]
    /\ running' = NoProc
    /\ UNCHANGED <<threadOwner, threadReason>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars, ghostVars>>

\* ========================================================================
\* Admission (Scenario 4): cap-before-reap vs reap-then-retry
\* ========================================================================

\* CreateProcess (create_process, manager/mod.rs:1129-1216).  The process-cap
\* check at :1139 rejects with OutOfMemory BEFORE any zombie harvest; live_count
\* drops only at burial.  A fresh process enters the ready list with one ready
\* thread.  Also consumes a thread slot (try_next_tid at :1164, not the reaping
\* variant) so the thread cap is likewise checked without a preceding reap.
CreateProcess ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ LiveProcCount < MaxProc                 \* :1139 cap gate (no harvest first)
    /\ LiveThreadCount < MaxThread             \* :1164 try_next_tid (no reaping)
    /\ FreeProcExists
    /\ FreeThreadExists
    /\ \E p \in Proc, t \in Thread :
         /\ procState[p] = "free"
         /\ threadState[t] = "free"
         /\ procState' = [procState EXCEPT ![p] = "ready"]
         /\ threadState' = [threadState EXCEPT ![t] = "ready"]
         /\ threadOwner' = [threadOwner EXCEPT ![t] = p]
         /\ threadReason' = [threadReason EXCEPT ![t] = "none"]
         \* fresh SignalControl::default (state/signal.rs:501): defaults, no pending, restorer set by image
         /\ pending' = [pending EXCEPT ![p] = {}]
         /\ disposition' = [disposition EXCEPT ![p] = [s \in Signal |-> "default"]]
         /\ saRestart' = [saRestart EXCEPT ![p] = [s \in Signal |-> FALSE]]
         /\ stopped' = [stopped EXCEPT ![p] = FALSE]
         /\ restorerSet' = [restorerSet EXCEPT ![p] = TRUE]
         /\ blocked' = [blocked EXCEPT ![t] = {}]
         /\ savedBlocked' = [savedBlocked EXCEPT ![t] = NoMask]
         /\ restart' = [restart EXCEPT ![t] = FALSE]
         /\ intrSig' = [intrSig EXCEPT ![t] = NoMask]
         /\ procTerminated' = [procTerminated EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<running>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM>>

\* CreateProcessSpuriousOOM (Scenario 4 bug, MC-5).  The reachable spurious-OOM is at
\* the THREAD-slot reservation, not the process-count cap.  create_process reserves its
\* main-thread slot with the NON-reaping try_next_tid (manager/mod.rs:1164), as does
\* do_execv (:2023); both differ from create_thread (:421) and duplicate_process (:1558),
\* which use the reap-then-retry try_next_tid_reaping added by fix #2495 (commit a85226542,
\* mod.rs:3410).  So when the thread cap is held partly by a terminated-but-unharvested
\* zombie thread, admission fails with a spurious OutOfMemory even though reaping that
\* zombie would free a slot ((live - reclaimable) < MaxThread).
\*
\* The process-count cap (:1139) is deliberately NOT modeled as the trigger: MAX_THREADS
\* (32) < MAX_PROCESSES (255) in kernel_config.toml (:111,:120) and every live process
\* owns >= 1 live thread, so thread_count >= proc_count and the process cap can never bind
\* first.  The guard LiveProcCount < MaxProc keeps this faithful -- the process-cap gate at
\* :1139 has already passed when the non-reaping thread reservation at :1164 refuses.
CreateProcessSpuriousOOM ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ LiveProcCount < MaxProc                              \* :1139 process cap passed (not the limiter)
    /\ LiveThreadCount >= MaxThread                         \* :1164/:2023 thread cap reached (no reaping) ...
    /\ ReclaimableThreadCount > 0                           \* ... but a zombie thread is reclaimable ...
    /\ (LiveThreadCount - ReclaimableThreadCount) < MaxThread \* ... and reaping it would free a slot
    /\ spuriousOOM' = TRUE
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, procTerminated>>

\* CreateThread (create_thread kcall, manager/mod.rs:~417): the running process
\* spawns an additional ready thread in itself.  This path uses the reaping
\* thread-slot reservation (try_next_tid_reaping, the fix #2495 site), so it does
\* NOT exhibit the S4 spurious-OOM (that is on the process cap / execv only).
\* Needed to build multi-threaded processes (sleepers embedded among siblings).
CreateThread ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ LiveThreadCount < MaxThread
    /\ FreeThreadExists
    /\ \E u \in Thread :
         /\ threadState[u] = "free"
         /\ threadState' = [threadState EXCEPT ![u] = "ready"]
         /\ threadOwner' = [threadOwner EXCEPT ![u] = running]
         /\ threadReason' = [threadReason EXCEPT ![u] = "none"]
         /\ blocked' = [blocked EXCEPT ![u] = {}]
         /\ savedBlocked' = [savedBlocked EXCEPT ![u] = NoMask]
         /\ restart' = [restart EXCEPT ![u] = FALSE]
         /\ intrSig' = [intrSig EXCEPT ![u] = NoMask]
    /\ UNCHANGED <<procState, running>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, disposition, saRestart, stopped, restorerSet>>
    /\ UNCHANGED ghostVars

\* Harvest a buried zombie process: frees its slot and its threads (harvest_zombies
\* -> pop_zombie_process decrements live_count, manager/mod.rs:3430,2460).
HarvestZombieProc ==
    /\ \E p \in Proc :
         /\ procState[p] = "zombie"
         /\ procState' = [procState EXCEPT ![p] = "free"]
         /\ threadState' = [t \in Thread |-> IF threadOwner[t] = p THEN "free" ELSE threadState[t]]
         /\ threadOwner' = [t \in Thread |-> IF threadOwner[t] = p THEN NoProc ELSE threadOwner[t]]
         /\ threadReason' = [t \in Thread |-> IF threadOwner[t] = p THEN "none" ELSE threadReason[t]]
         /\ pending' = [pending EXCEPT ![p] = {}]
         \* Released threads drop any mutex guards they still held (MutexGuard::drop
         \* fires at harvest -- thread/running.rs:195, sync/mutex.rs:200).
         /\ held' = [t \in Thread |-> IF threadOwner[t] = p THEN {} ELSE held[t]]
         /\ mutexLocked' = [a \in MutexAddr |->
              IF mutexOwner[a] # NoThread /\ threadOwner[mutexOwner[a]] = p
              THEN FALSE ELSE mutexLocked[a]]
         /\ mutexOwner' = [a \in MutexAddr |->
              IF mutexOwner[a] # NoThread /\ threadOwner[mutexOwner[a]] = p
              THEN NoThread ELSE mutexOwner[a]]
         \* Burial drops the process's whole ProcessState, including its `mutexes`
         \* BTreeMap (harvest_zombies takes the Box<ProcessState> from pop_zombie_process
         \* and drops it at end of scope, manager/mod.rs:3430,2449).  So every mutex-map
         \* entry that belonged to the harvested process is freed -- model that by clearing
         \* mutexInMap/mutexExtraRef for the mutexes it owned.  (Without this, HarvestZombieProc
         \* left mutexInMap=TRUE after a process that held a mutex exited and was reaped, a
         \* spec-fidelity gap that spuriously tripped SyncSlotConservation.)
         /\ mutexInMap' = [a \in MutexAddr |->
              IF mutexOwner[a] # NoThread /\ threadOwner[mutexOwner[a]] = p
              THEN FALSE ELSE mutexInMap[a]]
         /\ mutexExtraRef' = [a \in MutexAddr |->
              IF mutexOwner[a] # NoThread /\ threadOwner[mutexOwner[a]] = p
              THEN FALSE ELSE mutexExtraRef[a]]
    /\ UNCHANGED <<running>>
    /\ UNCHANGED <<exitVars, notifyVars>>
    /\ UNCHANGED <<condInMap, syncPc, cwCond, cwMutex>>
    /\ UNCHANGED <<blocked, disposition, saRestart, stopped, restorerSet,
                   savedBlocked, restart, intrSig>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM, procTerminated>>

\* ========================================================================
\* Blocking: Sleep and the alarm/wakeup search (Scenario 1)
\* ========================================================================

\* Sleep: the running thread of the running process voluntarily blocks
\* (do_sleep, manager/mod.rs:1756-1806).  The thread joins the "sleeping"
\* subset.  If the process still has ready threads it stays runnable (-> ready
\* list); otherwise, if all remaining threads sleep it becomes suspended.
\* Either way the running slot is freed for Schedule.  A Runnable process thus
\* legitimately retains sleeping threads (runnable.rs:60).
Sleep(c) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ threadState' = [threadState EXCEPT ![t] = "sleeping"]
         \* enqueue as a condvar waiter (Condvar::wait push_back, condvar.rs:257)
         /\ condWaiters' = [condWaiters EXCEPT ![c] = Append(@, t)]
         /\ LET others == ThreadsOfIn(running, {"ready"}) \ {t}
            IN IF others # {}
               THEN procState' = [procState EXCEPT ![running] = "ready"]
               ELSE procState' = [procState EXCEPT ![running] = "suspended"]
    /\ running' = NoProc
    /\ UNCHANGED <<threadOwner, threadReason>>
    /\ UNCHANGED <<notifyReg, notifyCond>>
    /\ UNCHANGED <<exitVars, syncVars, sigVars, ghostVars>>

\* AlarmFire (Scenario 1 enabling fault): a sleeping thread's per-thread alarm
\* expires (check_alarm, manager/mod.rs:1704-1735).
\*  - If its process is SUSPENDED: SleepingProcess::wakeup_alarm moves the whole
\*    process to the interrupted list while OTHER sleepers remain sleeping inside
\*    the now-Interrupted process (from_sleeping, interrupted.rs:60; the fired
\*    thread becomes interrupted/TimedOut).
\*  - If its process is RUNNABLE (ready): wakeup_expired_alarms wakes the thread
\*    to the ready subset (TimedOut) but the process stays ready (runnable.rs:252).
\* Both create the "sleeper embedded in a non-suspended process" state.
AlarmFire ==
    /\ \E t \in Thread :
         /\ threadState[t] = "sleeping"
         /\ LET p == threadOwner[t] IN
            /\ p # NoProc
            /\ \/ /\ procState[p] = "suspended"
                  /\ procState' = [procState EXCEPT ![p] = "interrupted"]
                  /\ threadState' = [threadState EXCEPT ![t] = "interrupted"]
                  /\ threadReason' = [threadReason EXCEPT ![t] = "timedout"]
               \/ /\ procState[p] = "ready"
                  /\ threadState' = [threadState EXCEPT ![t] = "ready"]
                  /\ threadReason' = [threadReason EXCEPT ![t] = "timedout"]
                  /\ UNCHANGED procState
            \* Remove the fired thread from any condvar waiter queue it parked on.
            /\ condWaiters' = [c \in CondAddr |->
                 SelectSeq(condWaiters[c], LAMBDA x : x # t)]
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<notifyReg, notifyCond>>
    /\ UNCHANGED <<exitVars, syncVars, sigVars, ghostVars>>

\* --- The buggy wakeup search set: try_wakeup / try_wakeup_thread ---
\* wakeup_waiter(tid) -> try_wakeup_thread (unsafe.rs:1142; manager/mod.rs:1852).
\* Step 1 always reads get_running() (:1854) -- this is where the S3 panic lives.
\* Step 2 (try_wakeup, :1880) scans ONLY the suspended then ready lists, NEVER
\* the interrupted list.  A sleeping thread embedded in an interrupted process is
\* therefore unreachable.  Returns TRUE if woken, FALSE otherwise.
CanReachSleeper(t) ==
    LET p == threadOwner[t] IN
    /\ threadState[t] = "sleeping"
    /\ p # NoProc
    /\ procState[p] \in {"running", "suspended", "ready"}   \* interrupted excluded (bug)

\* NotifyDequeue (Scenario 1, step 1): notify_first pops the front waiter tid from
\* the condvar queue (condvar.rs:123).  Kept separate from the wake so the
\* "consumed-but-not-woken" gap is an observable state.
NotifyDequeue(c) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ notifyReg = NoThread
    /\ Len(condWaiters[c]) > 0
    /\ notifyReg' = Head(condWaiters[c])
    /\ notifyCond' = c
    /\ condWaiters' = [condWaiters EXCEPT ![c] = Tail(@)]
    /\ UNCHANGED <<coreVars, exitVars, syncVars, sigVars, ghostVars>>

\* WakeDequeued (Scenario 1, step 2): try to wake the popped waiter via the buggy
\* search (wakeup_waiter -> try_wakeup_thread).  Reading get_running() first
\* panics if running is NoProc (S3).  If the waiter is a sleeper in a non-searched
\* (interrupted) process it is NOT woken; notify_first discards it and returns 0,
\* so the notification is consumed but the still-waiting thread is stranded
\* (NoLostNotify violation, MC-1).
WakeDequeued ==
    /\ notifyReg # NoThread
    /\ LET t == notifyReg IN
       \/ /\ running = NoProc                       \* get_running().expect(..) panics (:2787)
          /\ panicked' = TRUE
          /\ notifyReg' = NoThread
          /\ notifyCond' = NoCond
          /\ UNCHANGED <<coreVars, exitVars, condWaiters, syncVars, sigVars>>
          /\ UNCHANGED <<lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                         condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                         restartMisattributed, spuriousOOM, procTerminated>>
       \/ /\ running # NoProc
          /\ CanReachSleeper(t)                      \* found & woken: sleeping -> ready
          /\ threadState' = [threadState EXCEPT ![t] = "ready"]
          /\ threadReason' = [threadReason EXCEPT ![t] = "none"]
          /\ LET p == threadOwner[t] IN
               procState' = [procState EXCEPT ![p] =
                   IF procState[p] = "suspended" THEN "ready" ELSE procState[p]]
          /\ notifyReg' = NoThread
          /\ notifyCond' = NoCond
          /\ UNCHANGED <<running, threadOwner, condWaiters>>
          /\ UNCHANGED <<exitVars, syncVars, sigVars, ghostVars>>
       \/ /\ running # NoProc
          /\ ~CanReachSleeper(t)                     \* not found: consumed but not woken
          /\ notifyReg' = NoThread
          /\ notifyCond' = NoCond
          \* If it was genuinely still waiting (a sleeper unreachable by the search),
          \* the notification is lost and the waiter is stranded off the queue.
          /\ lostNotify' = IF threadState[t] = "sleeping" THEN TRUE ELSE lostNotify
          /\ UNCHANGED <<coreVars, exitVars, condWaiters, syncVars, sigVars>>
          /\ UNCHANGED <<panicked, signalDeliveryFailed, resumedAfterTerminate,
                         condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                         restartMisattributed, spuriousOOM, procTerminated>>

\* ========================================================================
\* Termination sinks (Scenario 2) and ResumeInterrupted (dispatcher mapping)
\* ========================================================================

\* Fold a process's live thread subsets on a termination sink.  Ready threads
\* become zombie; sleeping threads become interrupted/Killed; interrupted threads
\* are handled per `killInterrupted`:
\*   - InterruptedTerminate / suspended-terminate: force every interrupted thread
\*     to Killed (interrupted.rs:110-125).  [correct path]
\*   - RunnableTerminate (runnable.rs:180-193) and ProcessExit (running.rs:292-303):
\*     carry interrupted threads forward UNCHANGED, keeping TimedOut/Signaled. [BUG]
FoldTerminate(p, killInterrupted) ==
    /\ threadState' = [t \in Thread |->
         IF threadOwner[t] = p /\ threadState[t] # "free"
         THEN CASE threadState[t] = "ready"   -> "zombie"
                [] threadState[t] = "running" -> "zombie"
                [] threadState[t] = "sleeping" -> "interrupted"
                [] OTHER -> threadState[t]     \* interrupted / zombie subsets unchanged in place
         ELSE threadState[t]]
    /\ threadReason' = [t \in Thread |->
         IF threadOwner[t] = p /\ threadState[t] = "sleeping"
         THEN "killed"                                 \* sleeper -> interrupt(Killed)
         ELSE IF threadOwner[t] = p /\ threadState[t] = "interrupted" /\ killInterrupted
              THEN "killed"                            \* set_killed on already-interrupted
              ELSE threadReason[t]]                    \* BUG path: reason carried forward

\* RunnableTerminate: procd terminates a ready process (manager/mod.rs:2294-2308
\* -> RunnableProcess::terminate).  Already-interrupted threads keep their reason.
RunnableTerminate ==
    /\ \E p \in Proc :
         /\ procState[p] = "ready"
         /\ procTerminated' = [procTerminated EXCEPT ![p] = TRUE]
         /\ FoldTerminate(p, FALSE)
         \* If any interrupted thread remains it is placed on the interrupted list
         \* (manager then resumes one via InterruptedProcess::resume -- modeled as the
         \* separate ResumeInterrupted step); else the process becomes a zombie.
         /\ IF \E t \in Thread : threadOwner[t] = p /\ threadState'[t] = "interrupted"
            THEN procState' = [procState EXCEPT ![p] = "interrupted"]
            ELSE procState' = [procState EXCEPT ![p] = "zombie"]
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM>>

\* SuspendedTerminate: procd terminates a suspended process (manager/mod.rs:2311-2315
\* -> SleepingProcess::terminate == InterruptedProcess with all sleepers Killed).
\* This is the CORRECT path -- all threads become killed-interrupted.
SuspendedTerminate ==
    /\ \E p \in Proc :
         /\ procState[p] = "suspended"
         /\ procTerminated' = [procTerminated EXCEPT ![p] = TRUE]
         /\ FoldTerminate(p, TRUE)
         /\ procState' = [procState EXCEPT ![p] = "interrupted"]
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM>>

\* InterruptedTerminate: procd terminates an already-interrupted process
\* (manager/mod.rs:2318-2320 -> InterruptedProcess::terminate).  CORRECT path:
\* set_killed on every interrupted thread, sleepers folded Killed.
InterruptedTerminate ==
    /\ \E p \in Proc :
         /\ procState[p] = "interrupted"
         /\ procTerminated' = [procTerminated EXCEPT ![p] = TRUE]
         /\ FoldTerminate(p, TRUE)
         /\ UNCHANGED procState
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM>>

\* ResumeInterrupted (InterruptedProcess::resume, interrupted.rs:82-94,115-118 and
\* the manager's interrupted-list -> ready move, manager/mod.rs:1679).  One
\* interrupted thread is resumed to a READY thread, carrying its interrupt reason;
\* the process becomes runnable.  The exit-vs-return decision happens later, when
\* the thread runs and reaches the kcall-return checkpoint (DispatcherCheckpoint).
ResumeInterrupted ==
    /\ \E t \in Thread :
         /\ threadState[t] = "interrupted"
         /\ LET p == threadOwner[t] IN
            /\ p # NoProc
            /\ procState[p] \in {"ready", "running", "interrupted"}
            /\ threadState' = [threadState EXCEPT ![t] = "ready"]  \* resume() -> ReadyThread
            /\ threadReason' = [threadReason EXCEPT ![t] = threadReason[t]]  \* reason preserved
            /\ procState' = [procState EXCEPT ![p] =
                 IF procState[p] = "interrupted" THEN "ready" ELSE procState[p]]
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars, ghostVars>>

\* DispatcherCheckpoint (kcall/dispatcher.rs:263-289): a resumed thread now running
\* reaches the point where its interrupted blocking call returns.  The recorded
\* InterruptReason drives the outcome:
\*   Killed    -> ProcessManager::exit(): the whole process exits (:264-268).
\*   TimedOut  -> ETIMEDOUT (:270-272), Signaled -> EINTR (:274-286): the call
\*                RETURNS TO USER and the thread keeps running user code.
\* When the owning process was already terminated, a TimedOut/Signaled resume means
\* a live thread runs after its process was terminated (Scenario 2, MC-3).
DispatcherCheckpoint ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ threadReason[t] # "none"
         /\ syncPc[t] = "idle"
         /\ \/ /\ threadReason[t] = "killed"          \* Killed -> exit(): the process exits
               /\ procTerminated' = [procTerminated EXCEPT ![running] = TRUE]
               /\ FoldTerminate(running, TRUE)
               /\ procState' = [procState EXCEPT ![running] =
                    IF \E u \in Thread : threadOwner[u] = running /\ threadState'[u] = "interrupted"
                    THEN "interrupted" ELSE "zombie"]
               /\ running' = NoProc
               /\ UNCHANGED resumedAfterTerminate
            \/ /\ threadReason[t] \in {"timedout", "signaled"}   \* return to user, keep running
               /\ threadReason' = [threadReason EXCEPT ![t] = "none"]
               /\ resumedAfterTerminate' =
                    IF procTerminated[running] THEN TRUE ELSE resumedAfterTerminate
               /\ UNCHANGED <<procState, threadState, running, procTerminated>>
    /\ UNCHANGED <<threadOwner>>
    /\ UNCHANGED <<exitVars, notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, condWaitBad, maskViolated,
                   immortalPending, savedMaskViolated, restartMisattributed, spuriousOOM>>

\* ========================================================================
\* Exit with blocked rendezvous counterpart (Scenario 3): do_exit split
\* ========================================================================

\* Rendezvous: a thread t in some OTHER process registers as a push/pull
\* rendezvous counterpart blocked on process p (ipc/rendezvous.rs).  t sleeps.
RegisterRendezvous ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread, p \in Proc :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ p # running
         /\ procState[p] \notin {"free", "zombie"}
         /\ rvWaiter[t] # p
         /\ rvWaiter' = [rvWaiter EXCEPT ![t] = p]
         /\ threadState' = [threadState EXCEPT ![t] = "sleeping"]
         /\ LET others == ThreadsOfIn(running, {"ready"}) \ {t}
            IN IF others # {}
               THEN procState' = [procState EXCEPT ![running] = "ready"]
               ELSE procState' = [procState EXCEPT ![running] = "suspended"]
         /\ running' = NoProc
    /\ UNCHANGED <<threadOwner, threadReason>>
    /\ UNCHANGED <<exitPhase, exiting>>
    /\ UNCHANGED <<notifyVars, syncVars, sigVars, ghostVars>>

\* ExitTakeRunning (do_exit, manager/mod.rs:2116): take_running() nulls
\* self.running.  running becomes NoProc for the rest of the exit window.
ExitTakeRunning ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
    /\ exiting' = running
    /\ running' = NoProc
    /\ exitPhase' = "taken"
    /\ procTerminated' = [procTerminated EXCEPT ![running] = TRUE]
    /\ UNCHANGED <<procState, threadState, threadOwner, threadReason>>
    /\ UNCHANGED <<rvWaiter>>
    /\ UNCHANGED <<notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM>>

\* ExitCleanupRendezvous (manager/mod.rs:2130,2766): cleanup_rendezvous wakes each
\* orphaned counterpart via do_wakeup -> try_wakeup_thread -> get_running().  Since
\* running is NoProc in this window, get_running().expect(...) PANICS whenever
\* there is at least one counterpart to wake (RunningValidAtWakeup violation, MC-4).
ExitCleanupRendezvous ==
    /\ exitPhase = "taken"
    /\ LET waiters == { t \in Thread : rvWaiter[t] = exiting /\ threadState[t] = "sleeping" }
       IN \/ /\ waiters # {}
             \* get_running() read with running = NoProc -> panic (:2787,:1854).
             /\ panicked' = TRUE
             /\ exitPhase' = "cleaned"
             /\ UNCHANGED <<coreVars, exiting, rvWaiter, notifyVars, syncVars, sigVars>>
             /\ UNCHANGED <<lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                            condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                            restartMisattributed, spuriousOOM, procTerminated>>
          \/ /\ waiters = {}
             \* No counterpart: cleanup is a no-op; the window closes safely.
             /\ exitPhase' = "cleaned"
             /\ UNCHANGED <<coreVars, exiting, rvWaiter, notifyVars, syncVars, sigVars, ghostVars>>

\* ExitReinsert (manager/mod.rs:2133-2159): running_process.exit() folds the
\* threads (interrupted carried forward -- same S2 bug via running.rs:292), and the
\* process is placed on the ready list (if runnable threads remain) or the zombie
\* list; the next ready process is scheduled.
ExitReinsert ==
    /\ exitPhase = "cleaned"
    /\ LET p == exiting IN
       /\ FoldTerminate(p, FALSE)          \* ProcessExit carries interrupted reason forward (BUG)
       /\ IF \E t \in Thread : threadOwner[t] = p /\ threadState'[t] = "interrupted"
          THEN procState' = [procState EXCEPT ![p] = "interrupted"]
          ELSE procState' = [procState EXCEPT ![p] = "zombie"]
    /\ exitPhase' = "none"
    /\ exiting' = NoProc
    /\ running' = NoProc                     \* next process chosen by Schedule
    /\ UNCHANGED <<threadOwner>>
    /\ UNCHANGED <<rvWaiter>>
    /\ UNCHANGED <<notifyVars, syncVars, sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   restartMisattributed, spuriousOOM, procTerminated>>

\* ========================================================================
\* Synchronization: mutex lock / cancellation, cond_wait unlock/relock (S5)
\* ========================================================================

\* LockMutexAcquire (lock_mutex.rs:92-94, success): get_mutex creates/looks up the
\* map entry (refcount++, present), the lock succeeds, put_mutex_guard records the
\* guard.  The running thread now owns the mutex.
LockMutexAcquire(a) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ ~mutexLocked[a]                              \* try_lock succeeds
         /\ (mutexInMap[a] \/ MutexMapSize < MutexOpenMax)  \* get_mutex cap (:612)
         /\ mutexInMap' = [mutexInMap EXCEPT ![a] = TRUE]
         /\ mutexLocked' = [mutexLocked EXCEPT ![a] = TRUE]
         /\ mutexOwner' = [mutexOwner EXCEPT ![a] = t]
         /\ held' = [held EXCEPT ![t] = @ \cup {a}]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars>>
    /\ UNCHANGED <<mutexExtraRef, condInMap, syncPc, cwCond, cwMutex>>
    /\ UNCHANGED <<sigVars, ghostVars>>

\* LockMutexCancel (Scenario 5 bug, MC-7).  get_mutex has already created the map
\* entry (or bumped its refcount), but the blocking lock is interrupted / times out
\* and returns via `?` WITHOUT ever calling put_mutex (lock_mutex.rs:93).  The map
\* entry lingers forever (never gc'd because put_mutex is the only reclaimer) with an
\* inflated reference count, so a later put_mutex on the same address (from the
\* holder's unlock) will not remove it either -- a slot leak toward MUTEX_OPEN_MAX.
LockMutexCancel(a) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ mutexLocked[a]                               \* contended: must block, then get cancelled
         /\ mutexOwner[a] # t                            \* another thread owns it
         /\ (mutexInMap[a] \/ MutexMapSize < MutexOpenMax)
         \* get_mutex inserts/keeps the entry and the failed lock leaves an extra,
         \* never-reclaimed reference (refcount pushed above the put_mutex <=2 bound).
         /\ mutexInMap' = [mutexInMap EXCEPT ![a] = TRUE]
         /\ mutexExtraRef' = [mutexExtraRef EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars>>
    /\ UNCHANGED <<mutexLocked, mutexOwner, condInMap, held, syncPc, cwCond, cwMutex>>
    /\ UNCHANGED <<sigVars, ghostVars>>

\* UnlockMutex (unlock_mutex -> remove_mutex_guard -> put_mutex, manager/mod.rs:2635):
\* release the lock (guard drop notifies the first waiter) and call put_mutex, which
\* reclaims the map entry when the reference count is within the <=2 destroy bound
\* (state/mod.rs:646-648).  If a prior failed lock inflated the count, put_mutex
\* leaves the entry in place -- the leak persists.
UnlockMutex(a) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ mutexOwner[a] = t
         /\ mutexLocked' = [mutexLocked EXCEPT ![a] = FALSE]
         /\ mutexOwner' = [mutexOwner EXCEPT ![a] = NoThread]
         /\ held' = [held EXCEPT ![t] = @ \ {a}]
         \* put_mutex removes the entry iff its refcount is not inflated by a leak.
         /\ mutexInMap' = [mutexInMap EXCEPT ![a] = IF mutexExtraRef[a] THEN TRUE ELSE FALSE]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars>>
    /\ UNCHANGED <<mutexExtraRef, condInMap, syncPc, cwCond, cwMutex>>
    /\ UNCHANGED <<sigVars, ghostVars>>

\* CondWaitUnlock (wait_cond.rs:105-107): take_mutex_guard releases the mutex
\* (guard dropped, unlock fires) before the thread parks on the condvar.  This runs
\* remove_mutex_guard -> put_mutex (manager/mod.rs:2635), the SAME reclaimer every
\* unlock uses (UnlockMutex above): when the waiter is the sole holder (the modeled
\* analogue of reference_count() <= 2, i.e. no inflated/leaked reference), put_mutex
\* removes the map entry.  A contended entry (mutexExtraRef, an inflated refcount from
\* a cancelled lock) is kept.  Modeling this is what prevents a spurious orphaned slot:
\* in the sole-holder case the entry is gone during the wait and the reacquire below
\* re-creates a fresh one via get_mutex (state/mod.rs:652-666; MutexGuard holds its own
\* Arc clone, sync/mutex.rs:142-144).
CondWaitUnlock(c, a) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ a \in held[t]
         /\ mutexOwner[a] = t
         /\ mutexLocked' = [mutexLocked EXCEPT ![a] = FALSE]
         /\ mutexOwner' = [mutexOwner EXCEPT ![a] = NoThread]
         /\ held' = [held EXCEPT ![t] = @ \ {a}]
         /\ syncPc' = [syncPc EXCEPT ![t] = "cw_wait"]
         /\ cwCond' = [cwCond EXCEPT ![t] = c]
         /\ cwMutex' = [cwMutex EXCEPT ![t] = a]
         /\ condInMap' = [condInMap EXCEPT ![c] = TRUE]
         \* put_mutex removes the entry iff its refcount is not inflated by a leak.
         /\ mutexInMap' = [mutexInMap EXCEPT ![a] = IF mutexExtraRef[a] THEN TRUE ELSE FALSE]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars>>
    /\ UNCHANGED <<mutexExtraRef>>
    /\ UNCHANGED <<sigVars, ghostVars>>

\* CondWaitSleep (wait_cond.rs:111; condvar.rs:257-259): enqueue on the condvar and
\* sleep.  The thread joins the sleeping subset; its process leaves the running slot.
CondWaitSleep ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "cw_wait"
         /\ LET c == cwCond[t] IN
              condWaiters' = [condWaiters EXCEPT ![c] = Append(@, t)]
         /\ threadState' = [threadState EXCEPT ![t] = "sleeping"]
         /\ LET others == ThreadsOfIn(running, {"ready"}) \ {t}
            IN IF others # {}
               THEN procState' = [procState EXCEPT ![running] = "ready"]
               ELSE procState' = [procState EXCEPT ![running] = "suspended"]
         /\ running' = NoProc
    /\ UNCHANGED <<threadOwner, threadReason>>
    /\ UNCHANGED <<notifyReg, notifyCond>>
    /\ UNCHANGED <<exitVars>>
    /\ UNCHANGED <<mutexInMap, mutexExtraRef, mutexLocked, mutexOwner, condInMap, held, syncPc, cwCond, cwMutex>>
    /\ UNCHANGED <<sigVars, ghostVars>>

\* CondWaitRelock (wait_cond.rs:126-128, success): after being woken and scheduled,
\* the thread reacquires the mutex and returns holding it (POSIX-correct).  The
\* reacquire calls get_mutex (:126), which re-creates / looks up the map entry, so the
\* entry is present again once the lock is held.
CondWaitRelock ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "cw_wait"          \* woken, back on CPU, about to relock
         /\ LET a == cwMutex[t] IN
            /\ ~mutexLocked[a]              \* mutex.lock(None) acquires
            /\ mutexInMap' = [mutexInMap EXCEPT ![a] = TRUE]   \* get_mutex re-inserts (:126)
            /\ mutexLocked' = [mutexLocked EXCEPT ![a] = TRUE]
            /\ mutexOwner' = [mutexOwner EXCEPT ![a] = t]
            /\ held' = [held EXCEPT ![t] = @ \cup {a}]
         /\ syncPc' = [syncPc EXCEPT ![t] = "idle"]
         /\ cwCond' = [cwCond EXCEPT ![t] = NoCond]
         /\ cwMutex' = [cwMutex EXCEPT ![t] = NoThread]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars>>
    /\ UNCHANGED <<mutexExtraRef, condInMap>>
    /\ UNCHANGED <<sigVars, ghostVars>>

\* CondWaitRelockInterrupted (Scenario 5 bug, MC-6): the reacquire
\* `mutex.lock(None)?` (wait_cond.rs:127) is itself interrupted, OR `put_cond?`
\* (:123) early-returns, so wait_cond returns EINTR WITHOUT the mutex held --
\* violating the POSIX guarantee that cond_wait returns with the mutex locked
\* (CondWaitReturnsLocked).
CondWaitRelockInterrupted ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "cw_wait"
         /\ syncPc' = [syncPc EXCEPT ![t] = "idle"]     \* returns to the kcall dispatcher
         /\ cwCond' = [cwCond EXCEPT ![t] = NoCond]
         /\ cwMutex' = [cwMutex EXCEPT ![t] = NoThread]
         \* mutex NOT reacquired: held / mutexOwner unchanged -> caller lacks the lock.
         /\ condWaitBad' = TRUE
    /\ UNCHANGED <<coreVars, exitVars, notifyVars>>
    /\ UNCHANGED <<mutexInMap, mutexExtraRef, mutexLocked, mutexOwner, condInMap, held>>
    /\ UNCHANGED <<sigVars>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   maskViolated, immortalPending, savedMaskViolated, restartMisattributed,
                   spuriousOOM, procTerminated>>

\* ========================================================================
\* Signals: post / disposition / delivery / exec / mask (Scenarios 6, 7)
\* ========================================================================

\* PostSignalHandler (kill, manager/mod.rs:849-856): disposition == Handler ->
\* post to the process pending set (later gated by the per-thread mask at delivery)
\* and interrupt a candidate.  The Interrupt candidate search is the S1 signal path.
PostSignalHandler(p, s) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ procState[p] \notin {"free", "zombie"}
    /\ disposition[p][s] = "handler"
    /\ pending' = [pending EXCEPT ![p] = @ \cup {s}]
    \* interrupt_signal_candidate scans ONLY the suspended list (manager/mod.rs:1009).
    \* If the sole eligible (unmasked handler) candidate is a sleeper in a non-suspended
    \* process, no thread is interrupted and the signal is never delivered (MC-2).
    /\ LET eligibleElsewhere ==
             \E t \in Thread :
                /\ threadOwner[t] = p
                /\ threadState[t] = "sleeping"
                /\ procState[p] \in {"ready", "interrupted"}
                /\ s \notin blocked[t]
           suspendedCandidate ==
             /\ procState[p] = "suspended"
             /\ \E t \in Thread : threadOwner[t] = p /\ threadState[t] = "sleeping" /\ s \notin blocked[t]
           \* Parallel delivery path (manager/mod.rs:1000-1002; try_deliver_signal,
           \* signal.rs:242; deliver_pending_signals checkpoint, kcall/handler.rs:189):
           \* a non-suspended process with an unmasked ready/running/interrupted thread
           \* self-delivers the posted caught signal when that thread next reaches its
           \* return-to-user checkpoint.  Only a fully-suspended process needs explicit
           \* help from interrupt_signal_candidate.  A thread that masks the signal will
           \* not deliver it, so a self-deliverer must not block s.
           selfDeliverer ==
             \E t \in Thread :
                /\ threadOwner[t] = p
                /\ threadState[t] \in {"ready", "running", "interrupted"}
                /\ s \notin blocked[t]
       IN /\ IF suspendedCandidate
             THEN \E t \in Thread :
                    /\ threadOwner[t] = p
                    /\ threadState[t] = "sleeping"
                    /\ s \notin blocked[t]
                    /\ procState' = [procState EXCEPT ![p] = "interrupted"]
                    /\ threadState' = [threadState EXCEPT ![t] = "interrupted"]
                    /\ threadReason' = [threadReason EXCEPT ![t] = "signaled"]
                    /\ condWaiters' = [c \in CondAddr |->
                         SelectSeq(condWaiters[c], LAMBDA x : x # t)]
             ELSE /\ UNCHANGED <<procState, threadState, threadReason, condWaiters>>
          \* Delivery fails to reach safety ONLY when the sole unmasked eligible thread is
          \* a sleeper in a non-suspended process (interrupt_signal_candidate scans only the
          \* suspended list, mod.rs:1009-1018) AND no unmasked ready/running/interrupted
          \* sibling will self-deliver at its own checkpoint.
          /\ signalDeliveryFailed' =
               IF eligibleElsewhere /\ ~suspendedCandidate /\ ~selfDeliverer
               THEN TRUE ELSE signalDeliveryFailed
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<notifyReg, notifyCond>>
    /\ UNCHANGED <<exitVars, syncVars>>
    /\ UNCHANGED <<blocked, disposition, saRestart, stopped, restorerSet, savedBlocked, restart, intrSig>>
    /\ UNCHANGED <<panicked, lostNotify, resumedAfterTerminate, condWaitBad, maskViolated,
                   immortalPending, savedMaskViolated, restartMisattributed, spuriousOOM,
                   procTerminated>>

\* PostSignalDefaultTerminate (Scenario 6 bug, MC-8): a blockable signal whose
\* disposition is Default with a Terminate action.  kill() applies Terminate
\* directly (manager/mod.rs:858-893, PostAction::Terminate) WITHOUT consulting any
\* per-thread blocked mask, so a signal that every thread has blocked still takes
\* effect (MaskHonored violation).
PostSignalDefaultTerminate(p, s) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ procState[p] \in {"ready", "suspended", "interrupted"}   \* procd kills another process
    /\ disposition[p][s] = "default"
    \* Whether the signal is masked by every live thread of the target.
    /\ LET maskedEverywhere ==
             \A t \in Thread : (threadOwner[t] = p /\ threadState[t] # "free") => s \in blocked[t]
       IN /\ maskViolated' = IF maskedEverywhere THEN TRUE ELSE maskViolated
          \* Terminate the target (kill_terminate): fold its threads, move to zombie.
          /\ procTerminated' = [procTerminated EXCEPT ![p] = TRUE]
          /\ FoldTerminate(p, TRUE)
          /\ procState' = [procState EXCEPT ![p] =
                IF \E t \in Thread : threadOwner[t] = p /\ threadState'[t] = "interrupted"
                THEN "interrupted" ELSE "zombie"]
          /\ condWaiters' = [c \in CondAddr |->
               SelectSeq(condWaiters[c], LAMBDA x : threadOwner[x] # p)]
    /\ UNCHANGED <<running, threadOwner>>
    /\ UNCHANGED <<notifyReg, notifyCond>>
    /\ UNCHANGED <<exitVars, syncVars>>
    /\ UNCHANGED <<pending, blocked, disposition, saRestart, stopped, restorerSet,
                   savedBlocked, restart, intrSig>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, immortalPending, savedMaskViolated, restartMisattributed,
                   spuriousOOM>>

\* SetDisposition (sigaction, manager/mod.rs:603-611): install a new disposition.
\* Crucially it does NOT clear any already-pending signal.  Changing a pending
\* handler-signal's disposition to Default/Ignore leaves the bit set while
\* try_deliver_signal will skip it forever (it is no longer a Handler) -> immortal
\* pending (MC-9).
SetDisposition(p, s, d) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ p = running                          \* sigaction changes the caller's own disposition
    /\ procState[p] \notin {"free", "zombie"}
    /\ d \in {"default", "ignore", "handler"}
    /\ disposition' = [disposition EXCEPT ![p][s] = d]
    /\ saRestart' = [saRestart EXCEPT ![p][s] = IF d = "handler" THEN @ ELSE FALSE]
    \* Pending bit is left untouched.  If s was pending & caught and now is not a
    \* handler, it can never be delivered nor cleared -> flag immortal-pending.
    /\ immortalPending' =
         IF (s \in pending[p]) /\ (d \in {"default", "ignore"})
         THEN TRUE ELSE immortalPending
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, blocked, stopped, restorerSet, savedBlocked, restart, intrSig>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, savedMaskViolated, restartMisattributed,
                   spuriousOOM, procTerminated>>

\* InstallHandler: sigaction installs a caught handler for signal s (optionally
\* with SA_RESTART).  Separated so hunt cfgs can set up handler dispositions.
InstallHandler(p, s, sar) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ p = running                          \* sigaction installs the caller's own handler
    /\ procState[p] \notin {"free", "zombie"}
    /\ sar \in BOOLEAN
    /\ disposition' = [disposition EXCEPT ![p][s] = "handler"]
    /\ saRestart' = [saRestart EXCEPT ![p][s] = sar]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, blocked, stopped, restorerSet, savedBlocked, restart, intrSig>>
    /\ UNCHANGED ghostVars

\* DeliverSignal (try_deliver_signal, manager/mod.rs/signal.rs:206-316) at the
\* kcall-return checkpoint of the running thread.  Selects the lowest pending,
\* unmasked, caught (Handler) signal; if a restorer is missing, the signal is
\* CLEARED without delivery (signal.rs:257-268).  Applies the interrupted call's
\* SA_RESTART per the DELIVERED signal (not necessarily the interrupting one).
DeliverSignal ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ LET p == running
                deliverable == { s \in pending[p] :
                                   s \notin blocked[t] /\ disposition[p][s] = "handler" }
            IN /\ deliverable # {}
               /\ \E s \in deliverable :
                    /\ \A s2 \in deliverable : s2 >= s     \* lowest-numbered first (:247)
                    /\ \/ /\ restorerSet[p]                \* restorer present: deliver
                          /\ pending' = [pending EXCEPT ![p] = @ \ {s}]
                          /\ blocked' = [blocked EXCEPT ![t] = @ \cup {s}]  \* install handler mask
                          \* SA_RESTART is applied per the DELIVERED (lowest-numbered
                          \* deliverable caught) signal's flags (signal.rs:280-283), exactly
                          \* as POSIX/Linux specify; the signum-less KcallRestart record
                          \* (thread/state.rs:57-62) is simply consumed here (take_restart,
                          \* signal.rs:220).  There is no separate "interrupting signal" to
                          \* attribute against, so no misattribution oracle is modeled.
                          /\ restart' = [restart EXCEPT ![t] = FALSE]
                          /\ intrSig' = [intrSig EXCEPT ![t] = NoMask]
                          /\ UNCHANGED <<savedBlocked, restartMisattributed>>
                       \/ /\ ~restorerSet[p]               \* no restorer: DISCARD (:259-268)
                          /\ pending' = [pending EXCEPT ![p] = @ \ {s}]
                          /\ restart' = [restart EXCEPT ![t] = FALSE]
                          /\ intrSig' = [intrSig EXCEPT ![t] = NoMask]
                          /\ UNCHANGED <<blocked, savedBlocked, restartMisattributed>>
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<disposition, saRestart, stopped, restorerSet>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, savedMaskViolated,
                   spuriousOOM, procTerminated>>

\* MaskChange (sigprocmask): update the running thread's blocked mask.
MaskChange(newmask) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ newmask \subseteq Signal
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ blocked' = [blocked EXCEPT ![t] = newmask]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, disposition, saRestart, stopped, restorerSet, savedBlocked, restart, intrSig>>
    /\ UNCHANGED ghostVars

\* Exec (do_execv -> reset_for_exec, state/signal.rs:490-497): Handler dispositions
\* reset to Default, the pending set is ZEROED, the restorer is dropped.  Modeled
\* for the S6 lifecycle interaction (execv erases pending signals).
Exec ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ LET p == running IN
       /\ disposition' = [disposition EXCEPT ![p] =
            [s \in Signal |-> IF disposition[p][s] = "handler" THEN "default" ELSE disposition[p][s]]]
       /\ pending' = [pending EXCEPT ![p] = {}]
       /\ restorerSet' = [restorerSet EXCEPT ![p] = FALSE]
       /\ saRestart' = [saRestart EXCEPT ![p] = [s \in Signal |-> FALSE]]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<blocked, stopped, savedBlocked, restart, intrSig>>
    /\ UNCHANGED ghostVars

\* ========================================================================
\* sigsuspend / sigreturn / SA_RESTART reentrancy (Scenario 7)
\* ========================================================================

\* SigSuspendInstall (install_sigsuspend_mask, manager/mod.rs:722-749): save the
\* current blocked mask into the SINGLE saved_blocked slot and install a temporary
\* mask.  A nested sigsuspend (from a handler running before the outer sigreturn)
\* OVERWRITES saved_blocked, losing the original pre-suspend mask (MC-10).
SigSuspendInstall(newmask) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ newmask \subseteq Signal
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         \* saved_blocked is a single Option<u64>: overwriting a still-live save (a
         \* nested sigsuspend before the outer sigreturn) loses the original pre-suspend
         \* mask, so the outer sigreturn will later restore the wrong value (MC-10).
         /\ savedMaskViolated' =
              IF savedBlocked[t] # NoMask THEN TRUE ELSE savedMaskViolated
         /\ savedBlocked' = [savedBlocked EXCEPT ![t] = blocked[t]]
         /\ blocked' = [blocked EXCEPT ![t] = newmask]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, disposition, saRestart, stopped, restorerSet, restart, intrSig>>
    /\ UNCHANGED <<panicked, lostNotify, signalDeliveryFailed, resumedAfterTerminate,
                   condWaitBad, maskViolated, immortalPending, restartMisattributed,
                   spuriousOOM, procTerminated>>

\* SigReturn (sigreturn_restore, signal.rs:546-611): restore the blocked mask from
\* saved_blocked (else from the frame), then clear the saved slot.  The corruption
\* that makes the restored mask wrong is detected at the nested-overwrite point in
\* SigSuspendInstall above, so here the restore simply reinstates saved_blocked.
SigReturn ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ savedBlocked[t] # NoMask
         /\ blocked' = [blocked EXCEPT ![t] = savedBlocked[t]]
         /\ savedBlocked' = [savedBlocked EXCEPT ![t] = NoMask]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, disposition, saRestart, stopped, restorerSet, restart, intrSig>>
    /\ UNCHANGED ghostVars

\* MarkInterruptedBySignal: a blocking kernel call of the running thread is
\* interrupted by a caught signal, recording a (signum-less) restart record
\* (dispatcher.rs:274-286 set_running_thread_restart).  Retained to model the restart
\* record (and matched against the "MarkInterruptedBySignal" trace event); intrSig is a
\* spec-internal witness only.  No invariant reads these values -- the removed
\* RestartAttribution oracle attributed restart to a spec-only "interrupting signal"
\* that has no implementation counterpart.
MarkInterruptedBySignal(s) ==
    /\ running # NoProc
    /\ exitPhase = "none"
    /\ \E t \in Thread :
         /\ threadOwner[t] = running
         /\ threadState[t] = "running"
         /\ syncPc[t] = "idle"
         /\ restart' = [restart EXCEPT ![t] = TRUE]
         /\ intrSig' = [intrSig EXCEPT ![t] = s]
    /\ UNCHANGED <<coreVars, exitVars, notifyVars, syncVars>>
    /\ UNCHANGED <<pending, blocked, disposition, saRestart, stopped, restorerSet, savedBlocked>>
    /\ UNCHANGED ghostVars

\* ========================================================================
\* Next-state relation
\* ========================================================================

Next ==
    \/ Schedule
    \/ Preempt
    \/ CreateProcess
    \/ CreateThread
    \/ CreateProcessSpuriousOOM
    \/ HarvestZombieProc
    \/ \E c \in CondAddr : Sleep(c)
    \/ AlarmFire
    \/ \E c \in CondAddr : NotifyDequeue(c)
    \/ WakeDequeued
    \/ RunnableTerminate
    \/ SuspendedTerminate
    \/ InterruptedTerminate
    \/ ResumeInterrupted
    \/ DispatcherCheckpoint
    \/ RegisterRendezvous
    \/ ExitTakeRunning
    \/ ExitCleanupRendezvous
    \/ ExitReinsert
    \/ \E a \in MutexAddr : LockMutexAcquire(a)
    \/ \E a \in MutexAddr : LockMutexCancel(a)
    \/ \E a \in MutexAddr : UnlockMutex(a)
    \/ \E c \in CondAddr, a \in MutexAddr : CondWaitUnlock(c, a)
    \/ CondWaitSleep
    \/ CondWaitRelock
    \/ CondWaitRelockInterrupted
    \/ \E p \in Proc, s \in Signal : PostSignalHandler(p, s)
    \/ \E p \in Proc, s \in Signal : PostSignalDefaultTerminate(p, s)
    \/ \E p \in Proc, s \in Signal, d \in {"default","ignore","handler"} : SetDisposition(p, s, d)
    \/ \E p \in Proc, s \in Signal, sar \in BOOLEAN : InstallHandler(p, s, sar)
    \/ DeliverSignal
    \/ \E m \in SUBSET Signal : MaskChange(m)
    \/ Exec
    \/ \E m \in SUBSET Signal : SigSuspendInstall(m)
    \/ SigReturn
    \/ \E s \in Signal : MarkInterruptedBySignal(s)

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Invariants
\* ========================================================================

\* --- Type / structural sanity ---
TypeOK ==
    /\ procState \in [Proc -> {"free","running","ready","suspended","interrupted","zombie"}]
    /\ running \in Proc \cup {NoProc}
    /\ threadState \in [Thread -> {"free","running","ready","sleeping","interrupted","zombie"}]
    /\ threadOwner \in [Thread -> Proc \cup {NoProc}]
    /\ threadReason \in [Thread -> {"none","killed","timedout","signaled"}]
    /\ exitPhase \in {"none","taken","cleaned"}
    /\ exiting \in Proc \cup {NoProc}
    /\ notifyReg \in Thread \cup {NoThread}

\* SingleOwner (Scenario 1,2): the two-level membership is internally consistent --
\* no thread occupies two lifecycle states or queues, and no thread is scheduled
\* after its process terminated.  (Functions give exactly-one by construction; the
\* content here is the cross-consistency between process list and thread subsets.)
SingleOwner ==
    /\ \A t \in Thread : (threadState[t] = "free") <=> (threadOwner[t] = NoProc)
    /\ \A t \in Thread : threadOwner[t] # NoProc => procState[threadOwner[t]] # "free"
    \* at most one running thread
    /\ Cardinality({ t \in Thread : threadState[t] = "running" }) <= 1
    \* a running thread belongs to the running process, OR to the process currently
    \* detached inside the do_exit window (take_running nulled `running`).
    /\ \A t \in Thread : threadState[t] = "running" =>
         \/ (running # NoProc /\ threadOwner[t] = running)
         \/ (exitPhase # "none" /\ threadOwner[t] = exiting)
    \* running slot occupied  =>  its process is marked running
    /\ (running # NoProc) => procState[running] = "running"
    \* a process marked running is the running-slot occupant, or the exiting process
    /\ \A p \in Proc : procState[p] = "running" =>
         \/ p = running
         \/ (exitPhase # "none" /\ p = exiting)
    \* a suspended process has >=1 thread and none of its threads is running/ready
    /\ \A p \in Proc : procState[p] = "suspended" =>
         ( ThreadsOf(p) # {}
           /\ \A t \in ThreadsOf(p) : threadState[t] \in {"sleeping","interrupted","zombie"} )
    \* a zombie process has only zombie threads
    /\ \A p \in Proc : procState[p] = "zombie" =>
         \A t \in ThreadsOf(p) : threadState[t] = "zombie"

\* NoLostNotify (Scenario 1, MC-1): a consumed condvar/join notification woke a
\* still-waiting thread, or no genuine waiter existed -- never silently stranded one.
NoLostNotify == lostNotify = FALSE

\* SignalReachesSafety (Scenario 1/6, MC-2): safety proxy for the SignalReaches
\* liveness property.  interrupt_signal_candidate must not miss the sole eligible
\* caught-signal candidate because it scanned only the suspended list.
SignalReachesSafety == signalDeliveryFailed = FALSE

\* TerminatedThreadsDie (Scenario 2, MC-3): after terminate()/exit() no thread of
\* the process resumes user execution; every thread reaches Zombie (or Killed-
\* interrupted en route).  Violated when a carried-forward TimedOut/Signaled thread
\* returns to user code.
TerminatedThreadsDie == resumedAfterTerminate = FALSE

\* RunningValidAtWakeup (Scenario 3, MC-4): no wakeup path ever dereferenced the
\* running slot while it was NoProc (the do_exit reentrancy panic).
RunningValidAtWakeup == panicked = FALSE

\* NoSpuriousOOM (Scenario 4, MC-5): safety proxy for AdmissionLiveness -- admission
\* is not rejected with a spurious OutOfMemory while a reclaimable zombie thread awaits
\* harvest under the thread cap (the non-reaping try_next_tid at create_process:1164 /
\* do_execv:2023, vs the reap-then-retry try_next_tid_reaping of fix #2495).
NoSpuriousOOM == spuriousOOM = FALSE

\* CondWaitReturnsLocked (Scenario 5, MC-6): a wait_cond return leaves the caller
\* owning the mutex (POSIX).  Violated on the interrupted-reacquire path.
CondWaitReturnsLocked == condWaitBad = FALSE

\* SyncSlotConservation (Scenario 5, MC-7): no mutex-map entry lingers unreclaimed
\* after a lock cancellation.  A present entry that is unlocked, unowned, has no
\* holder, and no in-flight cond_wait reacquiring it should have been freed.
SyncSlotConservation ==
    \A a \in MutexAddr :
        ( mutexInMap[a]
          /\ ~mutexLocked[a]
          /\ mutexOwner[a] = NoThread
          /\ (\A t \in Thread : a \notin held[t])
          /\ (\A t \in Thread : cwMutex[t] # a) )
        => FALSE

\* MaskHonored (Scenario 6, MC-8): a blockable signal never takes effect while it
\* is masked by every eligible thread of the target.
MaskHonored == maskViolated = FALSE

\* NoImmortalPending (Scenario 6, MC-9): a pending signal is eventually delivered or
\* discarded after a disposition change -- never stuck pending & undeliverable.
NoImmortalPending == immortalPending = FALSE

\* SavedMaskRestored (Scenario 7, MC-10a): after nested handlers/sigsuspend complete,
\* the restored thread mask equals the pre-suspend value.
SavedMaskRestored == savedMaskViolated = FALSE

\* NOTE (MC-10b, removed): a "RestartAttribution" invariant previously required
\* SA_RESTART to be applied per a separately-tracked "interrupting signal" distinct
\* from the delivered one.  Neither POSIX/Linux nor the implementation promises that:
\* try_deliver_signal applies SA_RESTART from the DELIVERED (lowest-numbered deliverable
\* caught) signal's flags (signal.rs:240-283), and the signum-less KcallRestart record
\* (thread/state.rs:57-62) carries no signal number to attribute against.  The property
\* is therefore not a real contract, so the invariant was removed rather than left as a
\* vacuous predicate (see brief-coverage.md and the scenario7 bug-report entry).  The
\* restart record itself is still modeled (consumed in DeliverSignal), and the delivered-
\* signal SA_RESTART behavior holds by construction.

=============================================================================
