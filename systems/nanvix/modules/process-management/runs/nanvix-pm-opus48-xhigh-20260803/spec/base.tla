-------------------------------- MODULE base --------------------------------
(*****************************************************************************)
(* Base specification for the Nanvix process-management (PM) subsystem.      *)
(* Source of truth: nanvix/nanvix  src/kernel/src/pm/**                       *)
(*                                                                            *)
(* Category B (concurrent / runtime).  The kernel is single-core and runs    *)
(* interrupts-disabled with all atomics Relaxed (pm/mod.rs:46), so memory     *)
(* ordering is out of scope and events are totally ordered.  A whole kernel   *)
(* call runs atomically; the only interleaving points are (a) preemption of   *)
(* a user-mode thread and (b) a kcall that sleeps/blocks and yields.  Actions *)
(* are therefore split exactly at those blocking/yield points, per            *)
(* base-spec-methodology.md.                                                  *)
(*                                                                            *)
(* Model records (one variable per record family to keep UNCHANGED small):    *)
(*   th[t] : thread control block                                             *)
(*   pr[p] : process control block                                           *)
(*   mu[m] : mutex                                                            *)
(*   co[c] : condition variable                                               *)
(*   tlive : thread_live_count      (thread/mod.rs:227,261,272)               *)
(*   plive : proc_live_count                                                  *)
(*   deferred : detached-zombie deferred-reap set (running.rs:367; mod.rs)    *)
(*   g     : ghost witnesses for the model-checkable findings MC1..MC10       *)
(*****************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Proc,           \* set of process slots
    Thread,         \* set of thread slots
    Mutex,          \* set of kernel mutexes
    Cond,           \* set of kernel condition variables
    MaxThreads,     \* cap enforced on thread_live_count (thread/mod.rs:227)
    MaxProcs,       \* cap enforced on proc_live_count
    InitProc,       \* the process alive at boot
    InitThread,     \* the thread running at boot
    Sig,            \* the modelled signal universe (subset per cfg for scoping)
    Unblockable,    \* signals that cannot be masked/caught (SIGKILL/SIGSTOP)
    StopSig,        \* the SIGSTOP-like signal whose default action is Stop
    NULL            \* absence value

VARIABLES th, pr, mu, co, tlive, plive, deferred, g

vars == <<th, pr, mu, co, tlive, plive, deferred, g>>

-----------------------------------------------------------------------------
(* Signal universe and fixed POSIX-like semantics (state/signal.rs).  Sig,      *)
(* Unblockable and StopSig are CONSTANTS so each cfg can restrict the signal      *)
(* set to just what a scenario needs (this is the main state-space lever).        *)
(* Reference instantiation (full model): Sig = {1,9,15,19},                       *)
(* Unblockable = {9,19}, StopSig = 19.                                            *)
(*   1  : catchable, maskable, default = Terminate  (generic caught signal)      *)
(*   9  : SIGKILL   uncatchable, unblockable, default = Terminate                *)
(*   15 : SIGTERM   catchable, maskable, default = Terminate                     *)
(*   19 : SIGSTOP   uncatchable, unblockable, default = Stop                     *)
Maskable    == Sig \ Unblockable                            \* state/signal.rs:52
CanCatch(s)     == s \notin Unblockable
DefaultAct(s)   == IF s = StopSig THEN "stop" ELSE "term"   \* state/signal.rs:217-228

Disp == {"default", "ignore", "handler"}

TSt == {"none", "ready", "running", "sleeping", "interrupted", "zombie", "reaped"}
PSt == {"none", "alive", "zombie", "buried"}
BK  == {"none", "mutex", "condreacq", "cond", "join", "sigsuspend", "sleep"}

Min(S)   == CHOOSE x \in S : \A y \in S : x <= y
Last(s)  == s[Len(s)]
Front(s) == SubSeq(s, 1, Len(s) - 1)
NoMask   == [has |-> FALSE, mask |-> {}]

-----------------------------------------------------------------------------
(* Derived helpers.                                                           *)
LiveT(t)     == th[t].st \notin {"none", "reaped"}
ThreadsOf(p) == {t \in Thread : th[t].pr = p /\ LiveT(t)}
NoneRunning  == \A t \in Thread : th[t].st # "running"
CountLive    == Cardinality({t \in Thread : LiveT(t)})
CountLiveP   == Cardinality({p \in Proc : pr[p].st \in {"alive", "zombie"}})

(* Nested precedence: a process's PM location is derived from its threads'     *)
(* sub-states (manager/mod.rs:199-255; process/state/*.rs precedence).         *)
DerivedPLoc(p) ==
    IF pr[p].st = "none" THEN "none"
    ELSE IF \E t \in ThreadsOf(p) : th[t].st = "running"     THEN "running"
    ELSE IF \E t \in ThreadsOf(p) : th[t].st = "ready"       THEN "ready"
    ELSE IF \E t \in ThreadsOf(p) : th[t].st = "interrupted" THEN "interrupted"
    ELSE IF \E t \in ThreadsOf(p) : th[t].st = "sleeping"    THEN "sleeping"
    ELSE IF pr[p].st = "zombie" THEN "zombie"
    ELSE "buried"

(* interrupt_signal_candidate scans ONLY suspended processes (mod.rs:1000-1014)*)
Suspended == {p \in Proc : DerivedPLoc(p) = "sleeping"}

-----------------------------------------------------------------------------
(* Type invariant.                                                            *)
TypeOK ==
    /\ th \in [Thread -> [st: TSt, pr: Proc \cup {NULL}, det: BOOLEAN,
                          bk: BK, bo: Mutex \cup Cond \cup Thread \cup {NULL},
                          bl: SUBSET Maskable, fr: Seq(SUBSET Maskable),
                          sv: [has: BOOLEAN, mask: SUBSET Maskable],
                          ps: [has: BOOLEAN, mask: SUBSET Maskable],
                          hd: SUBSET Mutex, wm: Mutex \cup {NULL}, rp: 0..3]]
    /\ pr \in [Proc -> [st: PSt, sp: BOOLEAN,
                        dp: [Sig -> Disp], pd: SUBSET Sig]]
    /\ mu \in [Mutex -> [ex: BOOLEAN, ow: Thread \cup {NULL}, q: Seq(Thread)]]
    /\ co \in [Cond -> [ex: BOOLEAN, q: Seq(Thread)]]
    /\ tlive \in 0..(Cardinality(Thread) + 1)
    /\ plive \in 0..(Cardinality(Proc) + 1)
    /\ deferred \in SUBSET Thread
    /\ g \in [execRefused: BOOLEAN, maskedActed: BOOLEAN, joinLost: BOOLEAN,
              sigToZombie: BOOLEAN, maskRestoreBad: BOOLEAN, destroyWaiter: BOOLEAN,
              condNoReacq: BOOLEAN, selfstopwin: BOOLEAN, rollbackLeak: BOOLEAN]

-----------------------------------------------------------------------------
Init ==
    /\ th = [t \in Thread |->
                IF t = InitThread
                THEN [st|->"running", pr|->InitProc, det|->FALSE, bk|->"none",
                      bo|->NULL, bl|->{}, fr|-><<>>, sv|->NoMask, ps|->NoMask,
                      hd|->{}, wm|->NULL, rp|->0]
                ELSE [st|->"none", pr|->NULL, det|->FALSE, bk|->"none",
                      bo|->NULL, bl|->{}, fr|-><<>>, sv|->NoMask, ps|->NoMask,
                      hd|->{}, wm|->NULL, rp|->0]]
    /\ pr = [p \in Proc |->
                IF p = InitProc
                THEN [st|->"alive", sp|->FALSE, dp|->[s \in Sig|->"default"], pd|->{}]
                ELSE [st|->"none",  sp|->FALSE, dp|->[s \in Sig|->"default"], pd|->{}]]
    /\ mu = [m \in Mutex |-> [ex|->TRUE, ow|->NULL, q|-><<>>]]
    /\ co = [c \in Cond  |-> [ex|->TRUE, q|-><<>>]]
    /\ tlive = 1
    /\ plive = 1
    /\ deferred = {}
    /\ g = [execRefused|->FALSE, maskedActed|->FALSE, joinLost|->FALSE,
            sigToZombie|->FALSE, maskRestoreBad|->FALSE, destroyWaiter|->FALSE,
            condNoReacq|->FALSE, selfstopwin|->FALSE, rollbackLeak|->FALSE]

-----------------------------------------------------------------------------
(* State-space bound: cap signal-frame nesting depth (already enforced by the  *)
(* AsyncDeliver guard) so the model is small and finite for exhaustive checks.  *)
StateBound == \A t \in Thread : Len(th[t].fr) <= 2

-----------------------------------------------------------------------------
(* Reaping a thread harvests it (drops its ThreadState), which releases every       *)
(* mutex guard it still held and wakes the next waiter.  ALL reap paths (join,       *)
(* detach, deferred, harvest, healing reap) call harvest_zombie_thread ->            *)
(* ZombieThread::harvest, so the guard drop is unconditional; only live_count         *)
(* accounting can diverge (MC1).  The guard drop runs unlock_unchecked (mutex.rs:78- *)
(* 81): it clears ownership (locked.store(false) => ow=NULL) and notify_first wakes   *)
(* ONE waiter, which then RE-COMPETES via try_lock in Mutex::lock's loop.  This is    *)
(* the same wake-and-recompete protocol as the ordinary Unlock action: release does   *)
(* NOT hand ownership directly to the head, it drops the head from the wait queue and *)
(* wakes it so its LockResume sees ow=NULL and re-acquires.                            *)
ReleaseOwnedBy(R) ==   \* new mutex map after reaping thread-set R (release+wake head)
    [m \in Mutex |->
        IF mu[m].ow \in R
           THEN IF mu[m].q # <<>> THEN [mu[m] EXCEPT !.ow=NULL, !.q=Tail(mu[m].q)]
                                  ELSE [mu[m] EXCEPT !.ow=NULL]
           ELSE mu[m]]
WokenByRelease(R) ==   \* head waiter woken to re-compete (notify_first) on release
    {mu[m].q[1] : m \in {mm \in Mutex : mu[mm].ow \in R /\ mu[mm].q # <<>>}}

-----------------------------------------------------------------------------
(* ===========================  SCHEDULING  =============================== *)

(* schedule (mod.rs:1658-1936): pick a ready, non-stopped thread when the     *)
(* CPU is idle.  Single-core => at most one running thread.                   *)
Schedule(t) ==
    /\ NoneRunning
    /\ th[t].st = "ready"
    /\ ~pr[th[t].pr].sp
    /\ th' = [th EXCEPT ![t].st = "running"]
    /\ g' = [g EXCEPT !.selfstopwin = FALSE]            \* scheduling point: window closes
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred>>

(* Timer preemption of a user-mode thread (tick->giveup->schedule): the        *)
(* running thread yields so a sibling can run.  This is the second, generic    *)
(* interleaving point named in the brief (mod.rs concurrency model).           *)
Preempt(t) ==
    /\ th[t].st = "running"
    /\ \E u \in Thread : th[u].st = "ready"
    /\ th' = [th EXCEPT ![t].st = "ready"]
    /\ g' = [g EXCEPT !.selfstopwin = FALSE]            \* scheduling point: window closes
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred>>

-----------------------------------------------------------------------------
(* ======================  THREAD/PROCESS CREATION  ====================== *)

(* create_thread (mod.rs:402-467) admits via try_next_tid_reaping             *)
(* (mod.rs:3410-3425): it first SAFELY reaps every deferred zombie (healing),  *)
(* then checks live_count < MAX (thread/mod.rs:227).  We fold the healing reap *)
(* of all deferred into this atomic kcall, then commit (commit_next_tid,       *)
(* thread/mod.rs:261, bumps live_count).                                       *)
CreateThread(caller, nt, det) ==
    /\ th[caller].st = "running"
    /\ LET p == th[caller].pr
           woken == WokenByRelease(deferred) IN
         /\ pr[p].st = "alive"
         /\ th[nt].st = "none"
         \* healing: all deferred are reclaimable and would be reaped first
         /\ tlive - Cardinality(deferred) < MaxThreads   \* thread/mod.rs:227
         /\ th' = [x \in Thread |->
                     IF x = nt
                        THEN [th[x] EXCEPT !.st="ready", !.pr=p, !.det=det, !.bk="none"]
                     ELSE IF x \in deferred
                        THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]   \* safe healing reap (releases guard)
                     ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                        ELSE th[x]]
         /\ mu' = ReleaseOwnedBy(deferred)
         /\ tlive' = (tlive - Cardinality(deferred)) + 1
         /\ deferred' = {}
    /\ UNCHANGED <<pr, co, plive, g>>

(* duplicate_process / fork (mod.rs:1485-1642): reserve child pid+tid, copy     *)
(* signal disposition and blocked mask (inherited_for_fork), then commit        *)
(* (mod.rs:1621-1638).  Atomic reserve->commit; ID accounting is the property.  *)
Fork(caller, cp, ctid) ==
    /\ th[caller].st = "running"
    /\ LET pp == th[caller].pr
           woken == WokenByRelease(deferred) IN
         /\ pr[pp].st = "alive"
         /\ pr[cp].st = "none"
         /\ th[ctid].st = "none"
         /\ plive < MaxProcs
         /\ tlive - Cardinality(deferred) < MaxThreads
         /\ pr' = [pr EXCEPT ![cp].st="alive", ![cp].sp=FALSE,
                             ![cp].dp=pr[pp].dp, ![cp].pd={}]
         /\ th' = [x \in Thread |->
                     IF x = ctid
                        THEN [th[x] EXCEPT !.st="ready", !.pr=cp, !.det=FALSE,
                                           !.bk="none", !.bl=th[caller].bl]
                     ELSE IF x \in deferred
                        THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]
                     ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                        ELSE th[x]]
         /\ mu' = ReleaseOwnedBy(deferred)
         /\ tlive' = (tlive - Cardinality(deferred)) + 1
         /\ plive' = plive + 1
         /\ deferred' = {}
    /\ UNCHANGED <<co, g>>

(* do_execv (mod.rs:1973-2083).  The execv kcall UNCONDITIONALLY drains the deferred *)
(* zombies first (reap_deferred at unsafe.rs:361, before do_execv), each drain calling *)
(* on_thread_reaped (unsafe.rs:708) so live_count drops by |deferred|.  Only then does  *)
(* the NON-healing try_next_tid (mod.rs:2022-2023) refuse, and only when the POST-reap   *)
(* live_count still hits MAX_THREADS.  So a refusal requires no reclaimable slot:          *)
(* tlive - |deferred| >= MaxThreads (equivalently deferred = {} at this scope, since        *)
(* tlive <= |Thread| <= MaxThreads).  Refusing while deferred # {} (finding MC9) is a spec   *)
(* artifact -- the entry-point reap would have reclaimed the slot and admitted.              *)
ExecRefuse(caller) ==
    /\ th[caller].st = "running"
    /\ pr[th[caller].pr].st = "alive"
    /\ tlive - Cardinality(deferred) >= MaxThreads   \* entry-point reap drains deferred first
    /\ th' = th                            \* refused; image untouched
    /\ g' = [g EXCEPT !.execRefused = @ \/ (deferred # {})]  \* MC9 witness: slot was reclaimable
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred>>

(* do_execv success path (admission passed): replace image -- reset all signal  *)
(* dispositions to default and clear pending (reset_for_exec), keep the caller   *)
(* as the sole thread of the process.  Other threads of the process terminate.   *)
ExecReplace(caller, nt) ==
    /\ th[caller].st = "running"
    /\ LET p == th[caller].pr IN
         /\ pr[p].st = "alive"
         /\ tlive < MaxThreads
         /\ th[nt].st = "none"
         /\ th' = [x \in Thread |->
                     IF x = nt
                        THEN [th[x] EXCEPT !.st="running", !.pr=p, !.det=FALSE,
                                           !.bk="none", !.bl={}, !.fr= <<>>,
                                           !.sv=NoMask, !.ps=NoMask]
                     ELSE IF x = caller
                        THEN [th[x] EXCEPT !.st="zombie", !.bk="none", !.bo=NULL]
                     ELSE IF th[x].pr = p /\ LiveT(x) /\ th[x].st # "zombie"
                        THEN [th[x] EXCEPT !.st="zombie", !.bk="none", !.bo=NULL]
                        ELSE th[x]]
         /\ tlive' = tlive + 1
         /\ pr' = [pr EXCEPT ![p].dp=[s \in Sig|->"default"], ![p].pd={}]
    /\ UNCHANGED <<mu, co, plive, deferred, g>>

-----------------------------------------------------------------------------
(* =========================  EXIT / TERMINATE  ========================== *)

(* do_exit_thread (unsafe.rs, running.rs:367-382): the running thread exits.    *)
(* Non-detached -> zombie awaiting join/harvest; detached -> zombie enqueued on  *)
(* the deferred-reap set (#2345).  Any waiting joiner is woken.  The mutex guard *)
(* is NOT released here -- release happens only at harvest (Scenario 3).         *)
ExitThread(t) ==
    /\ th[t].st = "running"
    /\ LET p          == th[t].pr
           othersLive == {u \in Thread : u # t /\ th[u].pr = p /\ LiveT(u)
                                          /\ th[u].st # "zombie"}
       IN /\ th' = [u \in Thread |->
                      IF u = t
                         THEN [th[u] EXCEPT !.st="zombie", !.bk="none", !.bo=NULL]
                      ELSE IF th[u].bk = "join" /\ th[u].bo = t
                              /\ th[u].st \in {"sleeping","interrupted"}
                         THEN [th[u] EXCEPT !.st="ready"]     \* wake joiner
                         ELSE th[u]]
          /\ pr' = [pr EXCEPT ![p].st = IF othersLive = {} THEN "zombie" ELSE @]
          \* running.rs:371-393: a detached zombie is deferred ONLY when a *live*
          \* (ready/interrupted/sleeping) sibling remains (`is_detached && has_other_threads`,
          \* :377).  has_other_threads excludes zombies, so with no live sibling the detached
          \* zombie is folded into the ZombieProcess (reaped by HarvestZombies), never deferred.
          /\ deferred' = IF th[t].det /\ othersLive # {} THEN deferred \cup {t} ELSE deferred
    /\ UNCHANGED <<mu, co, tlive, plive, g>>

-----------------------------------------------------------------------------
(* ======================  JOIN / DETACH  ================================ *)

(* try_join_thread (running.rs:541-621).  Atomic dispositions plus the parking   *)
(* case.  The reap-on-join path claims the status; there is no reap-claim lock    *)
(* so a concurrent detach / second joiner can steal the target (MC2).            *)
JoinThread(caller, u) ==
    /\ th[caller].st = "running"
    /\ caller # u
    /\ CASE th[u].st \in {"running", "ready"} ->            \* alive: park (wait)
              /\ th' = [th EXCEPT ![caller].st="sleeping",
                                  ![caller].bk="join", ![caller].bo=u]
              /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>
         [] th[u].st \in {"sleeping", "interrupted"} ->     \* alive: park (wait)
              /\ th' = [th EXCEPT ![caller].st="sleeping",
                                  ![caller].bk="join", ![caller].bo=u]
              /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>
         [] th[u].st = "zombie" /\ ~th[u].det ->            \* reap, return status; harvest drops the guard (unsafe.rs:758)
              /\ LET woken == WokenByRelease({u}) IN
                   th' = [x \in Thread |->
                            IF x = u THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]
                            ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                            ELSE th[x]]
              /\ mu' = ReleaseOwnedBy({u})
              /\ tlive' = tlive - 1
              /\ UNCHANGED <<pr, co, plive, deferred, g>>
         [] OTHER ->                                        \* zombie+detached / reaped: error
              /\ UNCHANGED vars

(* Resume of a parked joiner after it is scheduled again (running.rs re-check).   *)
(* If the target was reaped by another path, the joiner gets ThreadNotFound        *)
(* instead of the exit status -- finding MC2.                                       *)
JoinResume(caller) ==
    /\ th[caller].st = "running"
    /\ th[caller].bk = "join"
    /\ LET u == th[caller].bo IN
         CASE th[u].st = "zombie" /\ ~th[u].det ->          \* got status; harvest drops the guard (unsafe.rs:758)
                /\ LET woken == WokenByRelease({u}) IN
                     th' = [x \in Thread |->
                              IF x = caller THEN [th[caller] EXCEPT !.bk="none", !.bo=NULL]
                              ELSE IF x = u THEN [th[u] EXCEPT !.st="reaped", !.rp=@+1]
                              ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                              ELSE th[x]]
                /\ mu' = ReleaseOwnedBy({u})
                /\ tlive' = tlive - 1
                /\ UNCHANGED <<pr, co, plive, deferred, g>>
           [] th[u].st \in {"reaped", "none"} ->            \* target stolen -> MC2
                /\ th' = [th EXCEPT ![caller].bk="none", ![caller].bo=NULL]
                /\ g' = [g EXCEPT !.joinLost = TRUE]
                /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred>>
           [] th[u].st = "zombie" /\ th[u].det ->           \* detached out from under: error
                /\ th' = [th EXCEPT ![caller].bk="none", ![caller].bo=NULL]
                /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>
           [] OTHER ->                                      \* spurious wake: re-park
                /\ th' = [th EXCEPT ![caller].st="sleeping"]
                /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>

(* do_detach_thread (mod.rs:2513): detaching a live thread just marks it.         *)
(* Detaching a non-detached zombie reaps it immediately -- which can steal a       *)
(* target from a parked joiner (MC2 driver).                                        *)
DetachThread(caller, u) ==
    /\ th[caller].st = "running"
    /\ LiveT(u)
    /\ IF th[u].st = "zombie" /\ ~th[u].det
          THEN /\ LET woken == WokenByRelease({u}) IN       \* reap+harvest releases the guard (unsafe.rs:809)
                    th' = [x \in Thread |->
                             IF x = u THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]
                             ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                             ELSE th[x]]
               /\ mu' = ReleaseOwnedBy({u})
               /\ tlive' = tlive - 1
               /\ UNCHANGED <<pr, co, plive, deferred, g>>
          ELSE /\ th' = [th EXCEPT ![u].det=TRUE]
               /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>

-----------------------------------------------------------------------------
(* =========================  REAPING / HARVEST  ========================= *)

(* harvest_zombies (mod.rs:3430): reaps the NON-deferred zombie threads of a       *)
(* zombie process (on_thread_reaped each, releasing their mutex guards) and then    *)
(* BURIES the process.  Deferred detached zombies of the process are NOT reaped     *)
(* here -- they remain queued.  This burial-before-deferred-drain ordering is the   *)
(* precondition for MC1.                                                            *)
HarvestZombies(p) ==
    /\ pr[p].st = "zombie"
    /\ LET reapSet == {t \in Thread : th[t].pr = p /\ th[t].st = "zombie"
                                       /\ t \notin deferred}
           woken   == WokenByRelease(reapSet)
       IN /\ reapSet # {}
          /\ th' = [x \in Thread |->
                      IF x \in reapSet THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]
                      ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                      ELSE th[x]]
          /\ mu' = ReleaseOwnedBy(reapSet)
          /\ tlive' = tlive - Cardinality(reapSet)
          /\ pr' = [pr EXCEPT ![p].st = "buried"]
          /\ plive' = plive - 1
    /\ UNCHANGED <<co, deferred, g>>

(* reap_deferred_zombie_threads (mod.rs:3330-3391): the SAFE deferred drain used    *)
(* by the admission path.  Even when the owning process is gone it FALLS THROUGH    *)
(* and always calls on_thread_reaped (mod.rs:3387) -- live_count is decremented,    *)
(* mutex released.  No leak.                                                         *)
ReapDeferredSafe(t) ==
    /\ t \in deferred
    /\ th[t].st = "zombie"
    /\ LET woken == WokenByRelease({t}) IN
         /\ th' = [x \in Thread |->
                     IF x = t THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]
                     ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                     ELSE th[x]]
         /\ mu' = ReleaseOwnedBy({t})
         /\ tlive' = tlive - 1
         /\ deferred' = deferred \ {t}
    /\ UNCHANGED <<pr, co, plive, g>>

(* reap_deferred -> harvest_zombie_thread (unsafe.rs:610-709): the UNSAFE deferred   *)
(* drain used at kernel-call entry points.  reap_deferred() runs FIRST at every        *)
(* yield / PM entry (exit_thread unsafe.rs:535, giveup :939, and 5 more sites) and a    *)
(* deferred zombie exists only while its process still has a live sibling (running.rs    *)
(* :371-393), so the process is NEVER buried while a deferred zombie of it is pending.   *)
(* find_process_mut (mod.rs:2851) also resolves a process while it sits in self.zombies  *)
(* (pre-burial), so harvest_zombie_thread always reaches on_thread_reaped (unsafe.rs      *)
(* :708) and decrements live_count.  The buried-owner early-return at unsafe.rs:668       *)
(* (skipping the decrement) is therefore UNREACHABLE (finding MC1 is a spec artifact);    *)
(* the admission-path twin reap_deferred_zombie_threads always decrements anyway          *)
(* (mod.rs:3387).  We model the reachable behaviour: guard on a still-present owner and    *)
(* always decrement.                                                                       *)
ReapDeferredUnsafe(t) ==
    /\ t \in deferred
    /\ th[t].st = "zombie"
    /\ pr[th[t].pr].st # "buried"      \* reap_deferred runs before burial; owner still findable
    /\ LET woken == WokenByRelease({t}) IN
         /\ th' = [x \in Thread |->
                     IF x = t THEN [th[x] EXCEPT !.st="reaped", !.rp=@+1]
                     ELSE IF x \in woken THEN [th[x] EXCEPT !.st="ready"]
                     ELSE th[x]]
         /\ mu' = ReleaseOwnedBy({t})
         /\ tlive' = tlive - 1                        \* on_thread_reaped (unsafe.rs:708)
         /\ deferred' = deferred \ {t}
    /\ UNCHANGED <<pr, co, plive, g>>

-----------------------------------------------------------------------------
(* ============================  MUTEX  ================================== *)

(* Mutex::lock fast path (mutex.rs): free lock -> acquire, store guard in the      *)
(* owner thread's ThreadState (thread/state.rs:82).                                 *)
LockAcquire(t, m) ==
    /\ th[t].st = "running"
    /\ th[t].bk = "none"                \* a mid-wait waiter (bk="mutex") resumes via LockResume, not a fresh lock
    /\ mu[m].ex
    /\ mu[m].ow = NULL
    /\ mu' = [mu EXCEPT ![m].ow = t]
    /\ th' = [th EXCEPT ![t].hd = @ \cup {m}]
    /\ UNCHANGED <<pr, co, tlive, plive, deferred, g>>

(* Mutex::lock contended path: enqueue and sleep (yield point).                     *)
LockBlock(t, m) ==
    /\ th[t].st = "running"
    /\ th[t].bk = "none"                \* fresh contended lock; a woken waiter re-checks via LockResume
    /\ mu[m].ex
    /\ mu[m].ow # NULL
    /\ mu[m].ow # t
    /\ mu' = [mu EXCEPT ![m].q = Append(@, t)]
    /\ th' = [th EXCEPT ![t].st="sleeping", ![t].bk="mutex", ![t].bo=m]
    /\ UNCHANGED <<pr, co, tlive, plive, deferred, g>>

(* Resume after being woken by an unlock/release: re-check the lock.                *)
LockResume(t, m) ==
    /\ th[t].st = "running"
    /\ th[t].bk = "mutex"
    /\ th[t].bo = m
    /\ IF mu[m].ex /\ mu[m].ow = NULL
          THEN /\ mu' = [mu EXCEPT ![m].ow = t]
               /\ th' = [th EXCEPT ![t].hd=@ \cup {m}, ![t].bk="none", ![t].bo=NULL]
          ELSE /\ mu' = [mu EXCEPT ![m].q = Append(@, t)]     \* still held: re-block
               /\ th' = [th EXCEPT ![t].st="sleeping"]
    /\ UNCHANGED <<pr, co, tlive, plive, deferred, g>>

(* MutexGuard::drop / unlock_unchecked (mutex.rs:200-206): release and wake head.    *)
Unlock(t, m) ==
    /\ th[t].st = "running"
    /\ mu[m].ow = t
    /\ IF mu[m].q # <<>>
          THEN /\ mu' = [mu EXCEPT ![m].ow=NULL, ![m].q=Tail(@)]
               /\ th' = [th EXCEPT ![t].hd=@ \ {m},
                                   ![Head(mu[m].q)].st = "ready"]
          ELSE /\ mu' = [mu EXCEPT ![m].ow=NULL]
               /\ th' = [th EXCEPT ![t].hd=@ \ {m}]
    /\ UNCHANGED <<pr, co, tlive, plive, deferred, g>>

(* get_mutex/put_mutex refcount-threshold destroy (state/mod.rs:608-713).            *)
(* put_mutex has exactly one caller, remove_mutex_guard (mod.rs:2616-2637), which     *)
(* take_mutex_guard's the owner's guard out of locked_mutexes FIRST (thread/state.rs   *)
(* :241; the Unlock event already cleared ow and hd) and destroys the slot only when   *)
(* reference_count() <= 2 (state/mod.rs:651).  A blocked waiter holds an extra Arc      *)
(* clone (mutex.rs:174-186; reference_count = Arc::strong_count, mutex.rs:120-122), so   *)
(* a destroy is admissible only for a free, unwaited mutex.  Destroy-while-owned         *)
(* (MC10) and destroy-with-waiter (MC11) are spec artifacts.                             *)
PutMutex(caller, m) ==
    /\ th[caller].st = "running"
    /\ mu[m].ex
    /\ mu[m].ow = NULL                 \* owner's guard already dropped (take_mutex_guard / Unlock)
    /\ mu[m].q = <<>>                  \* reference_count() <= 2: no blocked waiter's Arc clone
    /\ mu' = [mu EXCEPT ![m].ex = FALSE]
    /\ g' = [g EXCEPT !.destroyWaiter = @ \/ (mu[m].q # <<>>) \/ (mu[m].ow # NULL)]
    /\ UNCHANGED <<th, pr, co, tlive, plive, deferred>>

-----------------------------------------------------------------------------
(* ========================  CONDITION VARIABLE  ========================= *)

(* wait_cond (kcall/wait_cond.rs:65-131): release the held mutex (take_mutex_guard,   *)
(* wakes a mutex waiter), enqueue on the condvar, sleep.  twcm remembers the mutex     *)
(* to reacquire on resume.                                                             *)
WaitCondPark(t, c, m) ==
    /\ th[t].st = "running"
    /\ co[c].ex
    /\ mu[m].ow = t
    /\ mu' = IF mu[m].q # <<>>
                THEN [mu EXCEPT ![m].ow=Head(mu[m].q), ![m].q=Tail(@)]
                ELSE [mu EXCEPT ![m].ow=NULL]
    /\ co' = [co EXCEPT ![c].q = Append(@, t)]
    /\ th' = [x \in Thread |->
                IF x = t
                   THEN [th[x] EXCEPT !.st="sleeping", !.bk="cond", !.bo=c,
                                      !.wm=m, !.hd=@ \ {m}]
                ELSE IF mu[m].q # <<>> /\ x = Head(mu[m].q)
                   THEN [th[x] EXCEPT !.st="ready"]         \* woken mutex waiter
                ELSE th[x]]
    /\ UNCHANGED <<pr, tlive, plive, deferred, g>>

(* Condvar::notify_first (condvar.rs; 387a1a6ae): move one waiter to the reacquire     *)
(* phase.  It must relock its mutex before returning (wait_cond.rs:125-130).            *)
SignalCond(caller, c) ==
    /\ th[caller].st = "running"
    /\ co[c].ex
    /\ co[c].q # <<>>
    /\ LET h == Head(co[c].q) IN
         /\ co' = [co EXCEPT ![c].q = Tail(@)]
         /\ th' = [th EXCEPT ![h].st="ready", ![h].bk="condreacq", ![h].bo=NULL]
    /\ UNCHANGED <<pr, mu, tlive, plive, deferred, g>>

(* wait_cond reacquire (wait_cond.rs:125-130): mutex.lock(None) -- NO timeout.  If the  *)
(* mutex owner has died and its guard was never released, this blocks forever (MC10).   *)
CondResumeReacquire(t) ==
    /\ th[t].st = "running"
    /\ th[t].bk = "condreacq"
    /\ LET m == th[t].wm IN
         IF mu[m].ex /\ mu[m].ow = NULL
            THEN /\ mu' = [mu EXCEPT ![m].ow = t]
                 /\ th' = [th EXCEPT ![t].hd=@ \cup {m}, ![t].bk="none", ![t].wm=NULL]
            ELSE /\ mu' = [mu EXCEPT ![m].q = Append(@, t)]
                 /\ th' = [th EXCEPT ![t].st="sleeping", ![t].bk="mutex", ![t].bo=m]
    /\ UNCHANGED <<pr, co, tlive, plive, deferred, g>>

(* Interruption of a cond-waiter by a signal (skip-stale-condvar-waiters 6055a7366):    *)
(* remove from the condvar queue and route to the reacquire phase.                       *)
CondInterrupt(t) ==
    /\ th[t].st \in {"sleeping"}
    /\ th[t].bk = "cond"
    /\ LET c == th[t].bo IN
         /\ co[c].q # <<>>
         /\ \E i \in 1..Len(co[c].q) : co[c].q[i] = t
         /\ co' = [co EXCEPT ![c].q = SelectSeq(@, LAMBDA e : e # t)]
         /\ th' = [th EXCEPT ![t].st="interrupted", ![t].bk="condreacq", ![t].bo=NULL]
    /\ UNCHANGED <<pr, mu, tlive, plive, deferred, g>>

(* get_cond/put_cond (state/mod.rs:638-713) + Condvar::drop panic on non-empty queue     *)
(* (condvar.rs:286).  put_cond destroys a condvar slot only when reference_count() <= 1    *)
(* (state/mod.rs:712).  A queued waiter keeps a live Condvar clone for the whole park       *)
(* (wait(&self,..) enqueues the tid, condvar.rs:232-257; reference_count = Arc::strong_count *)
(* condvar.rs:93-95), so refcount <= 1 implies an empty queue and CondvarInner::drop never    *)
(* sees a waiter.  Destroy-with-waiter (MC11) is a spec artifact.                              *)
PutCond(caller, c) ==
    /\ th[caller].st = "running"
    /\ co[c].ex
    /\ co[c].q = <<>>                  \* reference_count() <= 1: no queued waiter's Condvar clone
    /\ co' = [co EXCEPT ![c].ex = FALSE]
    /\ g' = [g EXCEPT !.destroyWaiter = @ \/ (co[c].q # <<>>)]
    /\ UNCHANGED <<th, pr, mu, tlive, plive, deferred>>

-----------------------------------------------------------------------------
(* ============================  SLEEP  ================================== *)

Sleep(t) ==
    /\ th[t].st = "running"
    /\ th' = [th EXCEPT ![t].st="sleeping", ![t].bk="sleep"]
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>

Wake(t) ==
    /\ th[t].st = "sleeping"
    /\ th[t].bk = "sleep"
    /\ th' = [th EXCEPT ![t].st="ready", ![t].bk="none"]
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>

-----------------------------------------------------------------------------
(* ============================  SIGNALS  ================================ *)

(* Terminate a whole process by a fatal signal / SIGKILL: all live threads become  *)
(* zombie; detached ones join the deferred set; joiners are woken; process->zombie.  *)
(* Mutex guards are NOT released (release only at harvest).                           *)
TermSet(p)      == {t \in Thread : th[t].pr = p /\ LiveT(t) /\ th[t].st # "zombie"}
DropSet(sq, S)  == SelectSeq(sq, LAMBDA x : x \notin S)
PurgeMu(S)      == [m \in Mutex |-> [mu[m] EXCEPT !.q = DropSet(@, S)]]
PurgeCo(S)      == [c \in Cond  |-> [co[c] EXCEPT !.q = DropSet(@, S)]]
TerminateEffectTh(p) ==
    LET termSet == TermSet(p)
    IN [u \in Thread |->
          IF u \in termSet THEN [th[u] EXCEPT !.st="zombie", !.bk="none", !.bo=NULL]
          ELSE IF th[u].bk = "join" /\ th[u].bo \in termSet
                  /\ th[u].st \in {"sleeping","interrupted"}
               THEN [th[u] EXCEPT !.st="ready"]
               ELSE th[u]]
TerminateDefer(p) ==
    deferred \cup {t \in Thread : th[t].pr = p /\ LiveT(t)
                                  /\ th[t].st # "zombie" /\ th[t].det}

(* kill / signal-post (mod.rs:810-899).  find_process includes zombies                *)
(* (mod.rs:2824-2852).  Disposition-directed:                                          *)
(*   - SIGKILL(9): bypass mask -> terminate.                                            *)
(*   - Ignore: drop.                                                                    *)
(*   - Handler (catchable): post to proc pending, interrupt a suspended thread.         *)
(*     Posting onto a zombie (MC8) is recorded.                                         *)
(*   - Default: apply default_action WITHOUT checking the mask (mod.rs:858-897) ->       *)
(*     a masked SIGTERM still terminates/stops (MC4).                                    *)
Kill(caller, p, s) ==
    /\ th[caller].st = "running"
    /\ pr[p].st \in {"alive", "zombie"}
    /\ LET d      == pr[p].dp[s]
           masked == /\ s \in Maskable
                     /\ ThreadsOf(p) # {}
                     /\ \A t \in ThreadsOf(p) : s \in th[t].bl
       IN CASE ~CanCatch(s) /\ DefaultAct(s) = "term" -> \* SIGKILL-like: bypass mask
                /\ th' = TerminateEffectTh(p)
                /\ pr' = [pr EXCEPT ![p].st="zombie"]
                /\ deferred' = TerminateDefer(p)
                /\ mu' = PurgeMu(TermSet(p))
                /\ co' = PurgeCo(TermSet(p))
                /\ UNCHANGED <<tlive, plive, g>>
            [] d = "ignore" ->                              \* dropped
                /\ UNCHANGED vars
            [] d = "handler" /\ CanCatch(s) ->              \* post + interrupt a sleeper
                /\ pr' = [pr EXCEPT ![p].pd = @ \cup {s}]
                /\ th' = [t \in Thread |->
                            IF p \in Suspended /\ th[t].pr = p
                               /\ th[t].st = "sleeping" /\ s \notin th[t].bl
                               /\ t = (CHOOSE tt \in {u \in Thread : th[u].pr=p
                                            /\ th[u].st="sleeping" /\ s \notin th[u].bl} : TRUE)
                            THEN [th[t] EXCEPT !.st="interrupted"]
                            ELSE th[t]]
                /\ g' = [g EXCEPT !.sigToZombie = @ \/ (pr[p].st = "zombie")]  \* MC8
                /\ UNCHANGED <<mu, co, tlive, plive, deferred>>
            [] d = "default" /\ DefaultAct(s) = "term" ->   \* default terminate, no mask check
                /\ th' = TerminateEffectTh(p)
                /\ pr' = [pr EXCEPT ![p].st="zombie"]
                /\ deferred' = TerminateDefer(p)
                /\ mu' = PurgeMu(TermSet(p))
                /\ co' = PurgeCo(TermSet(p))
                /\ g' = [g EXCEPT !.maskedActed = @ \/ masked]                 \* MC4
                /\ UNCHANGED <<tlive, plive>>
            [] OTHER ->                                     \* default stop (SIGSTOP etc.)
                /\ pr' = [pr EXCEPT ![p].sp = TRUE]
                /\ g' = [g EXCEPT !.maskedActed = @ \/ masked,                 \* MC4 (stop)
                                  !.selfstopwin = @ \/ (\E t \in ThreadsOf(p) : th[t].st = "running")]
                /\ UNCHANGED <<th, mu, co, tlive, plive, deferred>>

(* continue_process: SIGCONT clears the stopped flag and re-enables scheduling.        *)
ContinueProcess(caller, p) ==
    /\ th[caller].st = "running"
    /\ pr[p].st \in {"alive", "zombie"}
    /\ pr[p].sp
    /\ pr' = [pr EXCEPT ![p].sp = FALSE]
    /\ UNCHANGED <<th, mu, co, tlive, plive, deferred, g>>

(* sigaction (mod.rs:583-614): change disposition.  It does NOT clear already-pending    *)
(* signals (mod.rs:603-611); the stale pending entry is the seed for MC7.                 *)
Sigaction(caller, p, s, nd) ==
    /\ th[caller].st = "running"
    /\ pr[p].st = "alive"
    /\ CanCatch(s)                                         \* 9/19 cannot change disposition
    /\ pr' = [pr EXCEPT ![p].dp = [@ EXCEPT ![s] = nd]]
    /\ UNCHANGED <<th, mu, co, tlive, plive, deferred, g>>

(* sigprocmask (mod.rs:642-668): set the blocked mask; unblockable signals are stripped.  *)
Sigprocmask(t, nm) ==
    /\ th[t].st = "running"
    /\ th' = [th EXCEPT ![t].bl = nm]                      \* nm already SUBSET Maskable
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>

(* async delivery at kcall return (dispatcher.rs:240-247; state/signal.rs:240-268).      *)
(* Selects the lowest-numbered deliverable HANDLER signal that is unmasked; pushes a       *)
(* signal frame saving the current mask, masks the signal for the handler.  Non-handler     *)
(* pending signals are NOT delivered here (state/signal.rs:252) -- the seed for MC7.         *)
AsyncDeliver(t) ==
    /\ th[t].st = "running"
    /\ Len(th[t].fr) < 2
    /\ LET p           == th[t].pr
           deliverable == {s \in pr[p].pd : pr[p].dp[s] = "handler" /\ s \notin th[t].bl}
       IN /\ deliverable # {}
          /\ LET s == Min(deliverable) IN
               /\ pr' = [pr EXCEPT ![p].pd = @ \ {s}]
               /\ th' = [th EXCEPT ![t].fr = Append(@, th[t].bl),
                                   ![t].bl = (th[t].bl \cup {s}) \cap Maskable]
    /\ UNCHANGED <<mu, co, tlive, plive, deferred, g>>

(* install_sigsuspend_mask (mod.rs:722-749): save the current mask into the SINGLE          *)
(* saved_blocked slot and install a temporary mask.  ps is a ghost recording the true       *)
(* pre-suspend mask so SigsuspendMaskRestored can be checked.                                *)
Sigsuspend(t, tempmask) ==
    /\ th[t].st = "running"
    /\ ~th[t].sv.has                                       \* not already suspended
    /\ th' = [th EXCEPT ![t].sv = [has|->TRUE, mask|->th[t].bl],
                        ![t].ps = [has|->TRUE, mask|->th[t].bl],
                        ![t].bl = tempmask]
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred, g>>

(* sigreturn_restore (signal.rs:546-618).  take_saved_blocked() (line 607-610) takes         *)
(* PRECEDENCE over the frame's saved mask.  With nested delivery during sigsuspend, the        *)
(* inner sigreturn consumes the single saved slot and the outer sigreturn falls back to the     *)
(* frame mask (= temp mask) -> the final mask is wrong (MC6).                                    *)
Sigreturn(t) ==
    /\ th[t].st = "running"
    /\ (th[t].fr # <<>> \/ th[t].sv.has)
    /\ LET restoreMask == IF th[t].sv.has THEN th[t].sv.mask
                          ELSE IF th[t].fr # <<>> THEN Last(th[t].fr) ELSE th[t].bl
           newFr        == IF th[t].fr # <<>> THEN Front(th[t].fr) ELSE th[t].fr
           newSv        == IF th[t].sv.has THEN NoMask ELSE th[t].sv
           suspendDone  == (newFr = <<>>) /\ (~newSv.has) /\ th[t].ps.has
           badRestore   == suspendDone /\ (restoreMask # th[t].ps.mask)
       IN /\ th' = [th EXCEPT ![t].bl = restoreMask, ![t].fr = newFr, ![t].sv = newSv,
                              ![t].ps = IF suspendDone THEN NoMask ELSE @]
          /\ g' = [g EXCEPT !.maskRestoreBad = @ \/ badRestore]      \* MC6 witness
    /\ UNCHANGED <<pr, mu, co, tlive, plive, deferred>>

-----------------------------------------------------------------------------
(* =============================  NEXT  ================================== *)

Next ==
    \/ \E t \in Thread : Schedule(t)
    \/ \E t \in Thread : Preempt(t)
    \/ \E caller, nt \in Thread, det \in BOOLEAN : CreateThread(caller, nt, det)
    \/ \E caller, ctid \in Thread, cp \in Proc : Fork(caller, cp, ctid)
    \/ \E caller \in Thread : ExecRefuse(caller)
    \/ \E caller, nt \in Thread : ExecReplace(caller, nt)
    \/ \E t \in Thread : ExitThread(t)
    \/ \E caller, u \in Thread : JoinThread(caller, u)
    \/ \E caller \in Thread : JoinResume(caller)
    \/ \E caller, u \in Thread : DetachThread(caller, u)
    \/ \E p \in Proc : HarvestZombies(p)
    \/ \E t \in Thread : ReapDeferredSafe(t)
    \/ \E t \in Thread : ReapDeferredUnsafe(t)
    \/ \E t \in Thread, m \in Mutex : LockAcquire(t, m)
    \/ \E t \in Thread, m \in Mutex : LockBlock(t, m)
    \/ \E t \in Thread, m \in Mutex : LockResume(t, m)
    \/ \E t \in Thread, m \in Mutex : Unlock(t, m)
    \/ \E caller \in Thread, m \in Mutex : PutMutex(caller, m)
    \/ \E t \in Thread, c \in Cond, m \in Mutex : WaitCondPark(t, c, m)
    \/ \E caller \in Thread, c \in Cond : SignalCond(caller, c)
    \/ \E t \in Thread : CondResumeReacquire(t)
    \/ \E t \in Thread : CondInterrupt(t)
    \/ \E caller \in Thread, c \in Cond : PutCond(caller, c)
    \/ \E t \in Thread : Sleep(t)
    \/ \E t \in Thread : Wake(t)
    \/ \E caller \in Thread, p \in Proc, s \in Sig : Kill(caller, p, s)
    \/ \E caller \in Thread, p \in Proc : ContinueProcess(caller, p)
    \/ \E caller \in Thread, p \in Proc, s \in Sig, nd \in Disp : Sigaction(caller, p, s, nd)
    \/ \E t \in Thread, nm \in SUBSET Maskable : Sigprocmask(t, nm)
    \/ \E t \in Thread : AsyncDeliver(t)
    \/ \E t \in Thread, tm \in SUBSET Maskable : Sigsuspend(t, tm)
    \/ \E t \in Thread : Sigreturn(t)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* ======================  STRUCTURAL INVARIANTS  ======================= *)
(* Hold in every reachable state; checked by base.cfg and MC.cfg.            *)

(* At most one running thread (single core); a thread is in at most one wait   *)
(* queue.  (ExactlyOneLocation, brief §5 / Scenario 1.)                        *)
ExactlyOneLocation ==
    /\ Cardinality({t \in Thread : th[t].st = "running"}) <= 1
    /\ \A t \in Thread :
         Cardinality({m \in Mutex : \E i \in 1..Len(mu[m].q) : mu[m].q[i] = t})
       + Cardinality({c \in Cond  : \E i \in 1..Len(co[c].q) : co[c].q[i] = t}) <= 1

(* pstate agrees with the derived precedence of its threads.                   *)
NestedStateConsistent ==
    \A p \in Proc :
       /\ (pr[p].st = "alive"  => ThreadsOf(p) # {})
       /\ (pr[p].st = "none"   => \A t \in Thread : th[t].pr # p \/ ~LiveT(t))
       /\ (pr[p].st = "buried" =>
              \A t \in Thread : (th[t].pr = p /\ LiveT(t)) => th[t].st = "zombie")

(* Nothing runs after it becomes a zombie / after its process is a zombie.     *)
NoRunAfterZombie ==
    \A t \in Thread :
       th[t].st = "running" => pr[th[t].pr].st \in {"alive"}

(* A stopped process is not dispatched (self-stop one-quantum window allowed).  *)
NoStoppedDispatch ==
    \A t \in Thread :
       (th[t].st = "running" /\ pr[th[t].pr].sp) => g.selfstopwin

(* Each zombie is reaped at most once; on_thread_reaped is not double-counted.  *)
ReapedExactlyOnce ==
    \A t \in Thread : th[t].rp <= 1

StructuralOK ==
    /\ TypeOK
    /\ ExactlyOneLocation
    /\ NestedStateConsistent
    /\ NoRunAfterZombie
    /\ NoStoppedDispatch
    /\ ReapedExactlyOnce

-----------------------------------------------------------------------------
(* =======================  EXTENSION INVARIANTS  ======================= *)
(* Bug detectors.  Commented out in MC.cfg; each enabled in its hunt cfg.    *)

(* MC1: live_count equals the number of not-yet-reaped threads.  The unsafe    *)
(* deferred drain over a buried process leaks a live_count -> violation.        *)
LiveCountAccurate == tlive = CountLive

(* MC9: a net-zero-delta exec must not be refused while a reclaimable slot      *)
(* (a deferred zombie) exists.                                                  *)
ExecAdmission == ~g.execRefused

(* MC2: a waiting joiner must not receive ThreadNotFound instead of the status. *)
JoinGetsStatus == ~g.joinLost

(* MC3/MC10: a mutex whose owner has been fully reaped must have been released;  *)
(* otherwise a waiter blocks forever (release-only-at-harvest failure).          *)
MutexReleasedOnDeath ==
    \A m \in Mutex : mu[m].ow # NULL => th[mu[m].ow].st # "reaped"

(* Scenario 3: no mutex/cond destroyed while a thread is parked on it.          *)
NoDestroyWithWaiter == ~g.destroyWaiter

(* Scenario 3 / §6.2 T1: wait_cond returns holding the mutex on every modelled   *)
(* path (the error path that skips reacquire is a test concern, T1).             *)
CondWaitReacquires == ~g.condNoReacq

(* MC4: a blockable signal (including a default-action signal) does not act      *)
(* while it is masked in all eligible threads.                                   *)
MaskedSignalDeferred == ~g.maskedActed

(* MC6: after nested delivery during sigsuspend, blocked returns to pre-suspend.  *)
SigsuspendMaskRestored == ~g.maskRestoreBad

(* MC8: no caught signal is posted onto a zombie process.                        *)
NoSignalToZombie == ~g.sigToZombie

(* MC7 (part of SignalEventuallyDelivered): a proc-pending signal is deliverable, *)
(* i.e. still has a handler disposition; a disposition change to DFL/IGN that      *)
(* strands a pending signal violates this.                                         *)
NoStrandedProcPending ==
    \A p \in Proc : \A s \in pr[p].pd : pr[p].dp[s] = "handler"

(* MC5 (part of SignalEventuallyDelivered): a caught pending signal whose only     *)
(* unmasked recipient is a sleeping thread of a NON-suspended (runnable) process    *)
(* is never interrupted -> undeliverable.                                           *)
NoUndeliverableCaught ==
    ~ \E p \in Proc : \E s \in pr[p].pd :
         /\ pr[p].dp[s] = "handler"
         /\ DerivedPLoc(p) # "sleeping"
         /\ (\A t \in ThreadsOf(p) : th[t].st \in {"running","ready"} => s \in th[t].bl)
         /\ (\E t \in ThreadsOf(p) : th[t].st = "sleeping" /\ s \notin th[t].bl)

(* Scenario 5: failed create/fork/exec restores every reserved id and live_count. *)
RollbackComplete == ~g.rollbackLeak

-----------------------------------------------------------------------------
(* =========================  LIVENESS  ================================= *)
(* Temporal properties; checked with fairness in the hunt cfgs.              *)

Reaped(t)   == th[t].st = "reaped"
IsZombie(t) == th[t].st = "zombie"

(* NoUnreapableZombie: the kernel's auto-reclaim guarantee.  A DETACHED zombie   *)
(* thread (and, by HarvestZombies, any zombie whose process is buried) is         *)
(* eventually reaped by the deferred-reap machinery.  A JOINABLE (non-detached)   *)
(* thread whose process is still alive is deliberately retained until an explicit *)
(* pthread_join -- that retention is the POSIX contract, not a leak -- so it is   *)
(* excluded from the guarantee (join / joinres are intentionally NOT in the       *)
(* fairness set).                                                                 *)
NoUnreapableZombie ==
    \A t \in Thread : (IsZombie(t) /\ th[t].det) ~> Reaped(t)

(* MutexReleasedOnDeath (liveness): a thread parked on a mutex eventually        *)
(* stops being parked on it.                                                     *)
ParkedOn(t, m) == th[t].st = "sleeping" /\ th[t].bk \in {"mutex"} /\ th[t].bo = m
MutexProgress ==
    \A t \in Thread, m \in Mutex : ParkedOn(t, m) ~> (~ParkedOn(t, m))

(* SignalEventuallyDelivered: a deliverable proc-pending handler signal is         *)
(* eventually taken (proc pending drains).                                          *)
SignalEventuallyDelivered ==
    \A p \in Proc, s \in Sig :
       (s \in pr[p].pd /\ pr[p].dp[s] = "handler") ~> (s \notin pr[p].pd)

=============================================================================
