// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// TLA+ Trace Scenarios (Specula harness) — thread-centric PM lifecycle
//==================================================================================================
//
// This module drives the REAL Nanvix PM thread type-state transitions (the exact
// `run`/`schedule`/`sleep`/`exit`/`exit_for_exec`/`terminate`/`wakeup`/`interrupt`/`resume`/
// `harvest` transitions the process manager uses internally, in `pm/thread/{ready,running,sleeping,
// interrupted,zombie}.rs`) together with the REAL per-process `SignalControl` operations
// (`set_disposition`/`post`/`clear_pending`/`reset_for_exec`/`inherited_for_fork`), the REAL
// per-thread signal-mask state (`set_blocked`/`take_saved_blocked`/`set_saved_blocked`), the REAL
// per-process stopped flag (`set_stopped`), and a REAL `Mutex` guard (real `try_lock` / `Drop`
// unlock). Each resulting spec action is emitted as one NDJSON line matching `spec/Trace.tla`.
//
// It is NOT a re-implementation of the protocol: every thread lifecycle decision is taken by a real
// transition method that consumes the previous type-state object and returns the next one; the
// post-state fields validated by `Trace.tla` are then read back off the REAL objects (thread
// substate, detached flag, blocked mask, pending set, disposition, stopped flag, mutex owner).
//
// A small amount of AGGREGATE bookkeeping is world-tracked, exactly as the reference PM harness did:
//   * `tlive` / `plive` — the live-count arithmetic the base spec re-derives (the real bare
//     type-state transitions above are self-contained and never touch the manager's global
//     counters, so the counts are maintained here per the modeled arithmetic, including the modeled
//     `ReapDeferredUnsafe` leak);
//   * `deferred` — the detached-zombie deferred-reap set;
//   * the mutex/condvar WAIT QUEUES and the `ex` (slot-exists) flags — the model's `mu[m].q`/`co[c].q`
//     and `mu[m].ex`/`co[c].ex`;
//   * the per-thread signal-frame depth (`fr`) — the user-stack signal frames are unobservable in
//     the standalone UserVM, so their DEPTH is tracked here while the mask save/restore they carry is
//     driven for real on the thread's blocked state.
// These are auxiliary quantities, not state-machine transitions; see `INSTRUMENTATION.md` for the
// exact fidelity boundary.
//
// Model-value mapping (a stable bijection for the whole trace):
//   process p1,p2  <->  slot index 0,1   (real ProcessIdentifier 1,2)
//   thread  t1..t3 <->  slot index 0..2  (real ThreadIdentifier  1..3)
//   mutex   mx1    <->  the single modeled mutex
//   cond    cv1    <->  the single modeled condition variable
//   signals 1,9,15,19  <->  the same integers (bit s maps to `1 << (s-1)`, per state/signal.rs)
//   absent reference  <->  "NULL"
//
// Compiled only under the `test` feature.

#![allow(dead_code)]

use crate::{
    hal::{
        arch::{
            x86::cpu::FpuState,
            ContextInformation,
        },
        mem::VirtualAddress,
    },
    mm::{
        VirtMemoryManager,
        Vmem,
    },
    pm::{
        process::state::{
            signal::{
                SignalDisposition,
                SignalHandler,
            },
            ProcessState,
        },
        sync::mutex::{
            Mutex,
            MutexGuard,
        },
        thread::{
            InterruptReason,
            InterruptedThread,
            ReadyThread,
            RunningThread,
            SleepingThread,
            ZombieThread,
        },
        tla_trace::{
            self,
            write_str_lit,
            KlogWriter,
        },
        ProcessManager,
    },
};
use ::alloc::{
    boxed::Box,
    vec::Vec,
};
use ::core::fmt::{
    self,
    Write,
};
use ::sys::{
    pm::{
        ProcessIdentifier,
        ThreadIdentifier,
    },
    ExitStatus,
};

//==================================================================================================
// Constants
//==================================================================================================

/// Number of modeled thread slots (t1, t2, t3).
const NTHREAD: usize = 3;
/// Number of modeled process slots (p1, p2).
const NPROC: usize = 2;
/// The modeled signal universe, ascending (matches `Trace.cfg` `Sig`).
const SIG: [usize; 4] = [1, 9, 15, 19];

/// Bit for signal `s` in a blocked/pending mask (`state/signal.rs` uses `1 << (signum - 1)`).
#[inline]
fn sig_bit(s: usize) -> u64 {
    1u64 << (s - 1)
}

/// The maskable-signal bit mask (`Sig \ Unblockable` = {1, 15}).
#[inline]
fn maskable_bits() -> u64 {
    sig_bit(1) | sig_bit(15)
}

fn pid(i: usize) -> ProcessIdentifier {
    ProcessIdentifier::from(i as i32 + 1)
}

fn tid(i: usize) -> ThreadIdentifier {
    ThreadIdentifier::from(i as i32 + 1)
}

//==================================================================================================
// Fixture helpers
//==================================================================================================

/// Creates a fresh virtual memory space cloned off the current (kernel) process.
fn make_test_vmem() -> Option<Vmem> {
    // SAFETY: the process and virtual memory managers are initialized before in-kernel tests run;
    // access is synchronized because the kernel is single-threaded with interrupts disabled.
    let pm: &ProcessManager = unsafe { ProcessManager::get() };
    let mm: &VirtMemoryManager = unsafe { VirtMemoryManager::get() };
    match mm.new_vmem(pm.current_vmem()) {
        Ok(vmem) => Some(vmem),
        Err(e) => {
            error!("tla_world: new_vmem failed (error={e:?})");
            None
        },
    }
}

/// Builds a fresh ready thread with the given slot id and no stacks (a pure control-block fixture,
/// mirroring `test_detach.rs`).
fn make_ready_thread(i: usize) -> ReadyThread {
    ReadyThread::new(
        tid(i),
        None,
        None,
        None,
        ContextInformation::default(),
        // SAFETY: FpuState::new is synchronized (single-threaded kernel init).
        unsafe { FpuState::new() },
    )
}

/// Builds a fresh process control block owning no manager-tracked threads (threads are tracked as
/// bare type-state objects by [`World`]).
fn make_process_state(slot: usize, parent: usize) -> Option<ProcessState> {
    let vmem: Vmem = make_test_vmem()?;
    Some(ProcessState::new(pid(slot), pid(parent), vmem))
}

//==================================================================================================
// Thread cell
//==================================================================================================

/// The real thread type-state object currently occupying a modeled thread slot. The variant is
/// dictated by the last real transition applied to the slot, so it faithfully mirrors the thread's
/// PM substate.
enum ThreadCell {
    /// Slot is empty (`th[t].st = "none"`).
    None,
    Ready(ReadyThread),
    Running(RunningThread),
    Sleeping(SleepingThread),
    Interrupted(InterruptedThread),
    Zombie(ZombieThread),
    /// Slot was reaped (`th[t].st = "reaped"`); the real object has been consumed.
    Reaped,
}

impl ThreadCell {
    /// The `th[t].st` string for this cell.
    fn st(&self) -> &'static str {
        match self {
            ThreadCell::None => "none",
            ThreadCell::Ready(_) => "ready",
            ThreadCell::Running(_) => "running",
            ThreadCell::Sleeping(_) => "sleeping",
            ThreadCell::Interrupted(_) => "interrupted",
            ThreadCell::Zombie(_) => "zombie",
            ThreadCell::Reaped => "reaped",
        }
    }

    /// The thread's blocked-signal mask, read from the real thread state.
    fn blocked(&self) -> u64 {
        match self {
            ThreadCell::Ready(t) => t.thread_state().blocked(),
            ThreadCell::Running(t) => t.thread_state().blocked(),
            ThreadCell::Sleeping(t) => t.thread_state().blocked(),
            ThreadCell::Interrupted(t) => t.thread_state().blocked(),
            ThreadCell::Zombie(t) => t.thread_state().blocked(),
            _ => 0,
        }
    }

    fn set_blocked(&mut self, mask: u64) {
        match self {
            ThreadCell::Ready(t) => t.thread_state_mut().set_blocked(mask),
            ThreadCell::Running(t) => t.thread_state_mut().set_blocked(mask),
            ThreadCell::Sleeping(t) => t.thread_state_mut().set_blocked(mask),
            ThreadCell::Interrupted(t) => t.thread_state_mut().set_blocked(mask),
            ThreadCell::Zombie(t) => t.thread_state_mut().set_blocked(mask),
            _ => {},
        }
    }

    fn take_saved_blocked(&mut self) -> Option<u64> {
        match self {
            ThreadCell::Ready(t) => t.thread_state_mut().take_saved_blocked(),
            ThreadCell::Running(t) => t.thread_state_mut().take_saved_blocked(),
            ThreadCell::Sleeping(t) => t.thread_state_mut().take_saved_blocked(),
            ThreadCell::Interrupted(t) => t.thread_state_mut().take_saved_blocked(),
            ThreadCell::Zombie(t) => t.thread_state_mut().take_saved_blocked(),
            _ => None,
        }
    }

    fn set_saved_blocked(&mut self, mask: Option<u64>) {
        match self {
            ThreadCell::Ready(t) => t.thread_state_mut().set_saved_blocked(mask),
            ThreadCell::Running(t) => t.thread_state_mut().set_saved_blocked(mask),
            ThreadCell::Sleeping(t) => t.thread_state_mut().set_saved_blocked(mask),
            ThreadCell::Interrupted(t) => t.thread_state_mut().set_saved_blocked(mask),
            ThreadCell::Zombie(t) => t.thread_state_mut().set_saved_blocked(mask),
            _ => {},
        }
    }

    fn is_detached(&self) -> bool {
        match self {
            ThreadCell::Ready(t) => t.is_detached(),
            ThreadCell::Running(t) => t.is_detached(),
            ThreadCell::Sleeping(t) => t.is_detached(),
            ThreadCell::Interrupted(t) => t.is_detached(),
            ThreadCell::Zombie(t) => t.is_detached(),
            _ => false,
        }
    }

    fn set_detached(&mut self) {
        match self {
            ThreadCell::Ready(t) => t.set_detached(),
            ThreadCell::Running(t) => t.set_detached(),
            ThreadCell::Sleeping(t) => t.set_detached(),
            ThreadCell::Interrupted(t) => t.set_detached(),
            _ => {},
        }
    }
}

//==================================================================================================
// Process cell
//==================================================================================================

/// A modeled process slot: a world-tracked lifecycle status (`pr[p].st`) plus the REAL process
/// control block holding the signal dispositions/pending set and the stopped flag.
struct ProcCell {
    /// `pr[p].st`: one of "none", "alive", "zombie", "buried".
    status: &'static str,
    /// The real process control block (present once the process is created).
    state: Option<ProcessState>,
}

impl ProcCell {
    const fn empty() -> Self {
        ProcCell {
            status: "none",
            state: None,
        }
    }
}

//==================================================================================================
// World
//==================================================================================================

/// The trace world: real thread type-state objects and real process control blocks, plus the
/// aggregate bookkeeping the base spec re-derives (see the module header for the fidelity boundary).
struct World {
    /// threads[i] is symbolic thread t{i+1}.
    threads: [ThreadCell; NTHREAD],
    /// t_proc[i] is the process slot owning thread t{i+1} (`th[t].pr`), if any.
    t_proc: [Option<usize>; NTHREAD],
    /// t_bk[i] is the block kind of thread t{i+1} (`th[t].bk`); world-tracked to drive resumes.
    t_bk: [&'static str; NTHREAD],
    /// t_join[i] is the join target of thread t{i+1} when `bk = "join"` (`th[t].bo`).
    t_join: [Option<usize>; NTHREAD],
    /// t_fr[i] is thread t{i+1}'s signal-frame stack of saved masks (`th[t].fr`).
    t_fr: [Vec<u64>; NTHREAD],

    /// procs[i] is symbolic process p{i+1}.
    procs: [ProcCell; NPROC],

    /// `tlive` (thread_live_count).
    tlive: i64,
    /// `plive` (proc_live_count).
    plive: i64,
    /// `deferred`: the detached-zombie deferred-reap set (thread slot indices).
    deferred: Vec<usize>,

    /// `mu[mx1].ex`: whether the mutex slot exists.
    mu_ex: bool,
    /// `mu[mx1].ow`: owner thread slot, if held.
    mu_owner: Option<usize>,
    /// `mu[mx1].q`: FIFO of thread slots blocked on the mutex.
    mu_q: Vec<usize>,
    /// The single modeled real mutex.
    mutex: Mutex,
    /// The live guard keeping the real mutex locked; dropping it fires the real unlock.
    mu_guard: Option<MutexGuard>,

    /// `co[cv1].ex`: whether the condvar slot exists.
    co_ex: bool,
    /// `co[cv1].q`: FIFO of thread slots parked on the condvar.
    co_q: Vec<usize>,
}

impl World {
    /// Boots the world into `Trace.tla`'s `TraceInit`: process p1 alive owning running thread t1;
    /// all other slots empty; one free mutex mx1 and one condvar cv1; `tlive = plive = 1`.
    fn boot() -> Option<Self> {
        let (t1, _r, _c, _tda) = make_ready_thread(0).run();
        let p1: ProcessState = make_process_state(0, 0)?;
        Some(World {
            threads: [
                ThreadCell::Running(t1),
                ThreadCell::None,
                ThreadCell::None,
            ],
            t_proc: [Some(0), None, None],
            t_bk: ["none", "none", "none"],
            t_join: [None, None, None],
            t_fr: [Vec::new(), Vec::new(), Vec::new()],
            procs: [
                ProcCell {
                    status: "alive",
                    state: Some(p1),
                },
                ProcCell::empty(),
            ],
            tlive: 1,
            plive: 1,
            deferred: Vec::new(),
            mu_ex: true,
            mu_owner: None,
            mu_q: Vec::new(),
            mutex: Mutex::new(),
            mu_guard: None,
            co_ex: true,
            co_q: Vec::new(),
        })
    }

    //----------------------------------------------------------------------------------------------
    // Low-level helpers
    //----------------------------------------------------------------------------------------------

    fn take(&mut self, i: usize) -> ThreadCell {
        ::core::mem::replace(&mut self.threads[i], ThreadCell::None)
    }

    fn st(&self, i: usize) -> &'static str {
        self.threads[i].st()
    }

    fn proc_pending(&self, p: usize) -> u64 {
        self.procs[p]
            .state
            .as_ref()
            .map(|s| s.signals().pending())
            .unwrap_or(0)
    }

    fn proc_stopped(&self, p: usize) -> bool {
        self.procs[p].state.as_ref().map(|s| s.is_stopped()).unwrap_or(false)
    }

    fn disp_str(&self, p: usize, s: usize) -> &'static str {
        match self.procs[p].state.as_ref().and_then(|st| st.signals().disposition(s)) {
            Some(SignalDisposition::Ignore) => "ignore",
            Some(SignalDisposition::Handler(_)) => "handler",
            _ => "default",
        }
    }

    /// Consumes a zombie thread slot into the reaped state (the real `ZombieThread::harvest`
    /// releases its stacks); no accounting is applied here.
    fn reap_slot(&mut self, i: usize) {
        if let ThreadCell::Zombie(z) = self.take(i) {
            let _ = z.harvest();
        }
        self.threads[i] = ThreadCell::Reaped;
        self.t_bk[i] = "none";
    }

    /// Transitions any live thread slot to zombie via the appropriate real transition.
    fn force_zombie(&mut self, i: usize) {
        let cell = self.take(i);
        self.threads[i] = match cell {
            ThreadCell::Ready(t) => ThreadCell::Zombie(t.terminate()),
            ThreadCell::Running(t) => {
                let (z, _c) = t.exit(ExitStatus::from(0u32));
                ThreadCell::Zombie(z)
            },
            ThreadCell::Sleeping(t) => ThreadCell::Zombie(t.wakeup().terminate()),
            ThreadCell::Interrupted(t) => ThreadCell::Zombie(t.resume().terminate()),
            other => other,
        };
        self.t_bk[i] = "none";
    }

    /// Wakes any joiner parked on thread `target` (spec: `ExitThread`/`Kill` wake a `bk="join"`
    /// waiter), driving the real sleeping/interrupted -> ready transition.
    fn wake_joiners_of(&mut self, target: usize) {
        for j in 0..NTHREAD {
            if self.t_bk[j] == "join" && self.t_join[j] == Some(target) {
                match self.take(j) {
                    ThreadCell::Sleeping(t) => self.threads[j] = ThreadCell::Ready(t.wakeup()),
                    ThreadCell::Interrupted(t) => self.threads[j] = ThreadCell::Ready(t.resume()),
                    other => self.threads[j] = other,
                }
            }
        }
    }

    /// `othersLive` (spec): a live, non-zombie thread other than `t` belongs to process `p`.
    fn others_live(&self, p: usize, t: usize) -> bool {
        (0..NTHREAD).any(|u| {
            u != t
                && self.t_proc[u] == Some(p)
                && matches!(self.st(u), "ready" | "running" | "sleeping" | "interrupted")
        })
    }

    //----------------------------------------------------------------------------------------------
    // JSON emission
    //----------------------------------------------------------------------------------------------

    /// Emits one NDJSON trace line for `action`; `body` writes the action arguments and the
    /// implementation-observable post-state fields; the accounting counters are appended here.
    fn emit<F>(&self, action: &str, body: F)
    where
        F: FnOnce(&mut KlogWriter) -> fmt::Result,
    {
        let tlive: i64 = self.tlive;
        let plive: i64 = self.plive;
        tla_trace::emit_line(|w| {
            w.write_str("{\"action\":")?;
            write_str_lit(w, action)?;
            body(w)?;
            write!(w, ",\"tlive\":{},\"plive\":{}}}", tlive, plive)
        });
    }

    fn w_tarr(w: &mut KlogWriter, ids: &[usize]) -> fmt::Result {
        w.write_char('[')?;
        for (k, id) in ids.iter().enumerate() {
            if k > 0 {
                w.write_char(',')?;
            }
            write!(w, "\"t{}\"", id + 1)?;
        }
        w.write_char(']')
    }

    fn w_sigarr(w: &mut KlogWriter, mask: u64) -> fmt::Result {
        w.write_char('[')?;
        let mut first: bool = true;
        for &s in SIG.iter() {
            if mask & sig_bit(s) != 0 {
                if !first {
                    w.write_char(',')?;
                }
                write!(w, "{}", s)?;
                first = false;
            }
        }
        w.write_char(']')
    }

    //----------------------------------------------------------------------------------------------
    // Scheduling actions
    //----------------------------------------------------------------------------------------------

    /// Schedule(t): a ready thread is dispatched to running.
    fn schedule(&mut self, i: usize) {
        if let ThreadCell::Ready(rt) = self.take(i) {
            let (running, _r, _c, _tda) = rt.run();
            self.threads[i] = ThreadCell::Running(running);
        }
        let st: &str = self.st(i);
        self.emit("Schedule", |w| write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\"", i + 1, st));
    }

    /// Preempt(t): the running thread yields back to ready.
    fn preempt(&mut self, i: usize) {
        if let ThreadCell::Running(rt) = self.take(i) {
            let (ready, _c) = rt.schedule();
            self.threads[i] = ThreadCell::Ready(ready);
        }
        let st: &str = self.st(i);
        self.emit("Preempt", |w| write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\"", i + 1, st));
    }

    //----------------------------------------------------------------------------------------------
    // Creation actions
    //----------------------------------------------------------------------------------------------

    /// CreateThread(caller, nt, det): admit a new ready thread, healing (safely reaping) every
    /// deferred zombie first.
    fn create_thread(&mut self, caller: usize, nt: usize, det: bool) {
        let healed: usize = self.deferred.len();
        let to_reap: Vec<usize> = self.deferred.clone();
        for d in to_reap {
            self.reap_slot(d);
        }
        self.deferred.clear();
        let p: usize = self.t_proc[caller].unwrap_or(0);
        let (rt, _r, _c, _tda) = make_ready_thread(nt).run();
        // A newly-admitted thread is ready; produce it via the real ready -> (run) -> schedule path
        // by leaving it ready.
        let mut ready: ReadyThread = rt.schedule().0;
        if det {
            ready.set_detached();
        }
        self.threads[nt] = ThreadCell::Ready(ready);
        self.t_proc[nt] = Some(p);
        self.t_bk[nt] = "none";
        self.tlive = (self.tlive - healed as i64) + 1;
        let st: &str = self.st(nt);
        self.emit("CreateThread", |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"nt\":\"t{}\",\"det\":{},\"ntSt\":\"{}\",\"ntPr\":\"p{}\",\"deferred\":",
                caller + 1,
                nt + 1,
                det,
                st,
                p + 1
            )?;
            World::w_tarr(w, &[])
        });
    }

    /// Fork(caller, cp, ctid): reserve a child process and its main ready thread, inheriting the
    /// caller's dispositions and blocked mask; heal deferred zombies.
    fn fork(&mut self, caller: usize, cp: usize, ctid: usize) -> bool {
        let healed: usize = self.deferred.len();
        let to_reap: Vec<usize> = self.deferred.clone();
        for d in to_reap {
            self.reap_slot(d);
        }
        self.deferred.clear();
        let pp: usize = self.t_proc[caller].unwrap_or(0);
        // Build the child process, inheriting the parent's signal control block.
        let inherited = self.procs[pp]
            .state
            .as_ref()
            .map(|s| s.signals().inherited_for_fork());
        let mut child: ProcessState = match make_process_state(cp, pp) {
            Some(s) => s,
            None => return false,
        };
        if let Some(sig) = inherited {
            child.set_signals(sig);
        }
        self.procs[cp] = ProcCell {
            status: "alive",
            state: Some(child),
        };
        // Build the child main thread, inheriting the caller's blocked mask.
        let caller_bl: u64 = self.threads[caller].blocked();
        let mut ready: ReadyThread = make_ready_thread(ctid).run().0.schedule().0;
        ready.thread_state_mut().set_blocked(caller_bl);
        self.threads[ctid] = ThreadCell::Ready(ready);
        self.t_proc[ctid] = Some(cp);
        self.t_bk[ctid] = "none";
        self.tlive = (self.tlive - healed as i64) + 1;
        self.plive += 1;
        let cpst: &str = self.procs[cp].status;
        let ctst: &str = self.st(ctid);
        self.emit("Fork", |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"cp\":\"p{}\",\"ctid\":\"t{}\",\"cpSt\":\"{}\",\"ctidSt\":\"{}\",\"ctidPr\":\"p{}\",\"deferred\":",
                caller + 1,
                cp + 1,
                ctid + 1,
                cpst,
                ctst,
                cp + 1
            )?;
            World::w_tarr(w, &[])
        });
        true
    }

    /// ExecRefuse(caller): admission refused at MAX_THREADS (the non-healing exec path); nothing
    /// changes.
    fn exec_refuse(&mut self, caller: usize) {
        self.emit("ExecRefuse", |w| write!(w, ",\"caller\":\"t{}\"", caller + 1));
    }

    /// ExecReplace(caller, nt): replace the image — the new main thread runs, the caller and every
    /// other live thread of the process become zombie, dispositions reset and pending cleared.
    fn exec_replace(&mut self, caller: usize, nt: usize) {
        let p: usize = self.t_proc[caller].unwrap_or(0);
        // Caller exits its old image.
        if let ThreadCell::Running(rt) = self.take(caller) {
            let (z, _c) = rt.exit_for_exec();
            self.threads[caller] = ThreadCell::Zombie(z);
        }
        // Every other live, non-zombie thread of the process terminates.
        for j in 0..NTHREAD {
            if j != caller
                && j != nt
                && self.t_proc[j] == Some(p)
                && matches!(self.st(j), "ready" | "running" | "sleeping" | "interrupted")
            {
                self.force_zombie(j);
            }
        }
        // The new image's main thread starts running.
        let (running, _r, _c, _tda) = make_ready_thread(nt).run();
        self.threads[nt] = ThreadCell::Running(running);
        self.t_proc[nt] = Some(p);
        self.t_bk[nt] = "none";
        // Reset the process signal state for the new image.
        if let Some(st) = self.procs[p].state.as_mut() {
            st.signals_mut().reset_for_exec();
        }
        self.tlive += 1;
        let ntst: &str = self.st(nt);
        let cst: &str = self.st(caller);
        let pd: u64 = self.proc_pending(p);
        self.emit("ExecReplace", move |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"nt\":\"t{}\",\"ntSt\":\"{}\",\"callerSt\":\"{}\",\"pPd\":",
                caller + 1,
                nt + 1,
                ntst,
                cst
            )?;
            World::w_sigarr(w, pd)
        });
    }

    //----------------------------------------------------------------------------------------------
    // Exit / join / detach actions
    //----------------------------------------------------------------------------------------------

    /// ExitThread(t): the running thread exits to zombie; joiners are woken; the process becomes
    /// zombie if no other live thread remains; a detached exiter joins the deferred set.
    fn exit_thread(&mut self, t: usize) {
        let p: usize = self.t_proc[t].unwrap_or(0);
        let detached: bool = self.threads[t].is_detached();
        // Real running -> zombie.
        if let ThreadCell::Running(rt) = self.take(t) {
            let (z, _c) = rt.exit(ExitStatus::from(0u32));
            self.threads[t] = ThreadCell::Zombie(z);
        }
        self.t_bk[t] = "none";
        self.wake_joiners_of(t);
        if !self.others_live(p, t) {
            self.procs[p].status = "zombie";
        }
        if detached {
            self.deferred.push(t);
        }
        let tst: &str = self.st(t);
        let pst: &str = self.procs[p].status;
        let deferred: Vec<usize> = self.deferred.clone();
        self.emit("ExitThread", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\",\"pSt\":\"{}\",\"deferred\":", t + 1, tst, pst)?;
            World::w_tarr(w, &deferred)
        });
    }

    /// JoinThread(caller, u): reap `u` if it is a non-detached zombie, else park the caller.
    fn join_thread(&mut self, caller: usize, u: usize) {
        let ust: &str = self.st(u);
        if ust == "zombie" && !self.threads[u].is_detached() {
            // Reap path.
            self.reap_slot(u);
            self.tlive -= 1;
        } else if matches!(ust, "running" | "ready" | "sleeping" | "interrupted") {
            // Park path.
            if let ThreadCell::Running(rt) = self.take(caller) {
                let (sleeping, _c) = rt.sleep(None);
                self.threads[caller] = ThreadCell::Sleeping(sleeping);
            }
            self.t_bk[caller] = "join";
            self.t_join[caller] = Some(u);
        }
        let cst: &str = self.st(caller);
        let ust2: &str = self.st(u);
        self.emit("JoinThread", |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"u\":\"t{}\",\"callerSt\":\"{}\",\"uSt\":\"{}\"",
                caller + 1,
                u + 1,
                cst,
                ust2
            )
        });
    }

    /// JoinResume(caller): the parked joiner is scheduled again and claims its (still-present)
    /// zombie target's status.
    fn join_resume(&mut self, caller: usize) {
        let u: usize = self.t_join[caller].unwrap_or(0);
        if self.st(u) == "zombie" && !self.threads[u].is_detached() {
            self.reap_slot(u);
            self.tlive -= 1;
        }
        self.t_bk[caller] = "none";
        self.t_join[caller] = None;
        let cst: &str = self.st(caller);
        let ust: &str = self.st(u);
        self.emit("JoinResume", |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"callerSt\":\"{}\",\"uSt\":\"{}\"",
                caller + 1,
                cst,
                ust
            )
        });
    }

    /// DetachThread(caller, u): reap a non-detached zombie immediately, else just mark it detached.
    fn detach_thread(&mut self, caller: usize, u: usize) {
        let (ust, udet): (&'static str, bool);
        if self.st(u) == "zombie" && !self.threads[u].is_detached() {
            self.reap_slot(u);
            self.tlive -= 1;
            ust = "reaped";
            udet = false;
        } else {
            self.threads[u].set_detached();
            ust = self.st(u);
            udet = true;
        }
        self.emit("DetachThread", move |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"u\":\"t{}\",\"uSt\":\"{}\",\"uDet\":{}",
                caller + 1,
                u + 1,
                ust,
                udet
            )
        });
    }

    //----------------------------------------------------------------------------------------------
    // Reaping / harvest actions
    //----------------------------------------------------------------------------------------------

    /// HarvestZombies(p): bury a zombie process, reaping its non-deferred zombie threads.
    fn harvest_zombies(&mut self, p: usize) {
        let reap_set: Vec<usize> = (0..NTHREAD)
            .filter(|&j| self.t_proc[j] == Some(p) && self.st(j) == "zombie" && !self.deferred.contains(&j))
            .collect();
        for j in reap_set.iter() {
            self.reap_slot(*j);
        }
        self.tlive -= reap_set.len() as i64;
        self.procs[p].status = "buried";
        self.plive -= 1;
        let pst: &str = self.procs[p].status;
        self.emit("HarvestZombies", |w| {
            write!(w, ",\"p\":\"p{}\",\"pSt\":\"{}\"", p + 1, pst)
        });
    }

    /// ReapDeferredSafe(t): the healing deferred drain always reaps (no leak).
    fn reap_deferred_safe(&mut self, t: usize) {
        self.reap_slot(t);
        self.tlive -= 1;
        self.deferred.retain(|&x| x != t);
        let tst: &str = self.st(t);
        let deferred: Vec<usize> = self.deferred.clone();
        self.emit("ReapDeferredSafe", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\",\"deferred\":", t + 1, tst)?;
            World::w_tarr(w, &deferred)
        });
    }

    /// ReapDeferredUnsafe(t): the PM-entry deferred drain (reap_deferred at unsafe.rs:535/939).
    /// It runs before the owning process can be buried (a process with a pending deferred thread
    /// stays Runnable/Sleeping/Interrupted, running.rs:377), so find_process_mut always resolves
    /// (mod.rs:2851) and on_thread_reaped always runs (unsafe.rs:708): the live count is decremented.
    /// The buried-owner early-return (unsafe.rs:668) is unreachable, so there is no leak.
    fn reap_deferred_unsafe(&mut self, t: usize) {
        self.reap_slot(t);
        self.deferred.retain(|&x| x != t);
        self.tlive -= 1;
        let tst: &str = self.st(t);
        let deferred: Vec<usize> = self.deferred.clone();
        self.emit("ReapDeferredUnsafe", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\",\"deferred\":", t + 1, tst)?;
            World::w_tarr(w, &deferred)
        });
    }

    //----------------------------------------------------------------------------------------------
    // Mutex actions
    //----------------------------------------------------------------------------------------------

    /// LockAcquire(t, mx1): the free lock is taken on the fast path.
    fn lock_acquire(&mut self, t: usize) {
        self.mu_guard = self.mutex.try_lock().ok();
        self.mu_owner = Some(t);
        self.emit("LockAcquire", |w| {
            write!(w, ",\"t\":\"t{}\",\"m\":\"mx1\",\"muOw\":\"t{}\"", t + 1, t + 1)
        });
    }

    /// LockBlock(t, mx1): a contended lock enqueues the caller and puts it to sleep (yield point).
    fn lock_block(&mut self, t: usize) {
        self.mu_q.push(t);
        if let ThreadCell::Running(rt) = self.take(t) {
            let (sleeping, _c) = rt.sleep(None);
            self.threads[t] = ThreadCell::Sleeping(sleeping);
        }
        self.t_bk[t] = "mutex";
        let tst: &str = self.st(t);
        let q: Vec<usize> = self.mu_q.clone();
        self.emit("LockBlock", move |w| {
            write!(w, ",\"t\":\"t{}\",\"m\":\"mx1\",\"tSt\":\"{}\",\"muQ\":", t + 1, tst)?;
            World::w_tarr(w, &q)
        });
    }

    /// LockResume(t, mx1): a woken waiter re-checks and (here) acquires the now-free lock.
    fn lock_resume(&mut self, t: usize) {
        self.mu_guard = self.mutex.try_lock().ok();
        self.mu_owner = Some(t);
        self.t_bk[t] = "none";
        let tst: &str = self.st(t);
        self.emit("LockResume", |w| {
            write!(
                w,
                ",\"t\":\"t{}\",\"m\":\"mx1\",\"tSt\":\"{}\",\"muOw\":\"t{}\"",
                t + 1,
                tst,
                t + 1
            )
        });
    }

    /// Unlock(t, mx1): release and wake the head waiter (which must still re-acquire).
    fn unlock(&mut self, t: usize) {
        // Real unlock: drop the live guard.
        self.mu_guard = None;
        self.mu_owner = None;
        if !self.mu_q.is_empty() {
            let head: usize = self.mu_q.remove(0);
            if let ThreadCell::Sleeping(s) = self.take(head) {
                self.threads[head] = ThreadCell::Ready(s.wakeup());
            }
        }
        self.emit("Unlock", |w| {
            write!(w, ",\"t\":\"t{}\",\"m\":\"mx1\",\"muOw\":\"NULL\"", t + 1)
        });
    }

    /// PutMutex(caller, mx1): destroy the mutex slot (refcount threshold reached).
    fn put_mutex(&mut self, caller: usize) {
        self.mu_ex = false;
        self.emit("PutMutex", |w| {
            write!(w, ",\"caller\":\"t{}\",\"m\":\"mx1\",\"muEx\":{}", caller + 1, self.mu_ex)
        });
    }

    //----------------------------------------------------------------------------------------------
    // Condition-variable actions
    //----------------------------------------------------------------------------------------------

    /// WaitCondPark(t, cv1, mx1): release the held mutex, enqueue on the condvar, sleep.
    fn wait_cond_park(&mut self, t: usize) {
        // Release the mutex (real unlock); wake a mutex head waiter if present.
        self.mu_guard = None;
        if !self.mu_q.is_empty() {
            let head: usize = self.mu_q.remove(0);
            self.mu_owner = Some(head);
            if let ThreadCell::Sleeping(s) = self.take(head) {
                self.threads[head] = ThreadCell::Ready(s.wakeup());
            }
        } else {
            self.mu_owner = None;
        }
        self.co_q.push(t);
        if let ThreadCell::Running(rt) = self.take(t) {
            let (sleeping, _c) = rt.sleep(None);
            self.threads[t] = ThreadCell::Sleeping(sleeping);
        }
        self.t_bk[t] = "cond";
        let tst: &str = self.st(t);
        let owner: Option<usize> = self.mu_owner;
        let q: Vec<usize> = self.co_q.clone();
        self.emit("WaitCondPark", move |w| {
            write!(w, ",\"t\":\"t{}\",\"c\":\"cv1\",\"m\":\"mx1\",\"tSt\":\"{}\",\"coQ\":", t + 1, tst)?;
            World::w_tarr(w, &q)?;
            match owner {
                Some(o) => write!(w, ",\"muOw\":\"t{}\"", o + 1),
                None => write!(w, ",\"muOw\":\"NULL\""),
            }
        });
    }

    /// SignalCond(caller, cv1): move one waiter to the reacquire phase.
    fn signal_cond(&mut self, caller: usize) {
        if !self.co_q.is_empty() {
            let head: usize = self.co_q.remove(0);
            if let ThreadCell::Sleeping(s) = self.take(head) {
                self.threads[head] = ThreadCell::Ready(s.wakeup());
            }
            self.t_bk[head] = "condreacq";
        }
        let q: Vec<usize> = self.co_q.clone();
        self.emit("SignalCond", move |w| {
            write!(w, ",\"caller\":\"t{}\",\"c\":\"cv1\",\"coQ\":", caller + 1)?;
            World::w_tarr(w, &q)
        });
    }

    /// CondResumeReacquire(t): a resumed waiter relocks its remembered mutex (here: free -> acquire).
    fn cond_resume_reacquire(&mut self, t: usize) {
        self.mu_guard = self.mutex.try_lock().ok();
        self.mu_owner = Some(t);
        self.t_bk[t] = "none";
        let tst: &str = self.st(t);
        self.emit("CondResumeReacquire", |w| {
            write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\",\"muOw\":\"t{}\"", t + 1, tst, t + 1)
        });
    }

    /// CondInterrupt(t): a signal interrupts a cond-waiter, removing it from the condvar queue and
    /// routing it to the reacquire phase.
    fn cond_interrupt(&mut self, t: usize) {
        self.co_q.retain(|&x| x != t);
        if let ThreadCell::Sleeping(s) = self.take(t) {
            self.threads[t] = ThreadCell::Interrupted(s.interrupt(InterruptReason::Signaled));
        }
        self.t_bk[t] = "condreacq";
        let tst: &str = self.st(t);
        let q: Vec<usize> = self.co_q.clone();
        self.emit("CondInterrupt", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\",\"coQ\":", t + 1, tst)?;
            World::w_tarr(w, &q)
        });
    }

    /// PutCond(caller, cv1): destroy the condvar slot.
    fn put_cond(&mut self, caller: usize) {
        self.co_ex = false;
        self.emit("PutCond", |w| {
            write!(w, ",\"caller\":\"t{}\",\"c\":\"cv1\",\"coEx\":{}", caller + 1, self.co_ex)
        });
    }

    //----------------------------------------------------------------------------------------------
    // Sleep / wake actions
    //----------------------------------------------------------------------------------------------

    /// Sleep(t): the running thread sleeps on a generic wait.
    fn sleep(&mut self, t: usize) {
        if let ThreadCell::Running(rt) = self.take(t) {
            let (sleeping, _c) = rt.sleep(None);
            self.threads[t] = ThreadCell::Sleeping(sleeping);
        }
        self.t_bk[t] = "sleep";
        let tst: &str = self.st(t);
        self.emit("Sleep", |w| write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\"", t + 1, tst));
    }

    /// Wake(t): the generic sleeper is woken back to ready.
    fn wake(&mut self, t: usize) {
        if let ThreadCell::Sleeping(s) = self.take(t) {
            self.threads[t] = ThreadCell::Ready(s.wakeup());
        }
        self.t_bk[t] = "none";
        let tst: &str = self.st(t);
        self.emit("Wake", |w| write!(w, ",\"t\":\"t{}\",\"tSt\":\"{}\"", t + 1, tst));
    }

    //----------------------------------------------------------------------------------------------
    // Signal actions
    //----------------------------------------------------------------------------------------------

    /// Terminate every live, non-zombie thread of process `p` (SIGKILL / default-terminate).
    fn terminate_proc(&mut self, p: usize) {
        let victims: Vec<usize> = (0..NTHREAD)
            .filter(|&j| {
                self.t_proc[j] == Some(p)
                    && matches!(self.st(j), "ready" | "running" | "sleeping" | "interrupted")
            })
            .collect();
        for j in victims.iter() {
            let detached: bool = self.threads[*j].is_detached();
            self.force_zombie(*j);
            if detached {
                self.deferred.push(*j);
            }
        }
        // Wake joiners of any newly-zombie thread.
        for j in victims.iter() {
            self.wake_joiners_of(*j);
        }
        // Purge terminated threads from the mutex/condvar wait queues.
        self.mu_q.retain(|x| !victims.contains(x));
        self.co_q.retain(|x| !victims.contains(x));
        self.procs[p].status = "zombie";
    }

    /// Kill(caller, p, s): disposition-directed signal posting (see base.tla `Kill`).
    fn kill(&mut self, caller: usize, p: usize, s: usize) {
        let can_catch: bool = s != 9 && s != 19;
        let default_term: bool = s != 19; // DefaultAct == "term" unless s == StopSig(19).
        let d: &str = self.disp_str(p, s);
        if !can_catch && default_term {
            // SIGKILL-like: bypass mask, terminate.
            self.terminate_proc(p);
        } else if d == "ignore" {
            // Dropped.
        } else if d == "handler" && can_catch {
            // Post to the process pending set (a suspended sleeper would be interrupted).
            if let Some(st) = self.procs[p].state.as_mut() {
                st.signals_mut().post(s);
            }
        } else if d == "default" && default_term {
            // Default terminate, no mask check.
            self.terminate_proc(p);
        } else {
            // Default stop (SIGSTOP-like).
            if let Some(st) = self.procs[p].state.as_mut() {
                st.set_stopped(true);
            }
        }
        let pst: &str = self.procs[p].status;
        let sp: bool = self.proc_stopped(p);
        let pd: u64 = self.proc_pending(p);
        self.emit("Kill", move |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"p\":\"p{}\",\"s\":{},\"pSt\":\"{}\",\"pSp\":{},\"pPd\":",
                caller + 1,
                p + 1,
                s,
                pst,
                sp
            )?;
            World::w_sigarr(w, pd)
        });
    }

    /// ContinueProcess(caller, p): SIGCONT clears the stopped flag.
    fn continue_process(&mut self, caller: usize, p: usize) {
        if let Some(st) = self.procs[p].state.as_mut() {
            st.set_stopped(false);
        }
        let sp: bool = self.proc_stopped(p);
        self.emit("ContinueProcess", move |w| {
            write!(w, ",\"caller\":\"t{}\",\"p\":\"p{}\",\"pSp\":{}", caller + 1, p + 1, sp)
        });
    }

    /// Sigaction(caller, p, s, nd): change a catchable signal's disposition.
    fn sigaction(&mut self, caller: usize, p: usize, s: usize, nd: &'static str) {
        if let Some(st) = self.procs[p].state.as_mut() {
            let disp: SignalDisposition = match nd {
                "ignore" => SignalDisposition::Ignore,
                "handler" => SignalDisposition::Handler(Box::new(SignalHandler {
                    entry: VirtualAddress::new(0x1000),
                    mask: 0,
                    flags: 0,
                    sigaction: 0,
                })),
                _ => SignalDisposition::Default,
            };
            st.signals_mut().set_disposition(s, disp);
        }
        let dp: &str = self.disp_str(p, s);
        self.emit("Sigaction", move |w| {
            write!(
                w,
                ",\"caller\":\"t{}\",\"p\":\"p{}\",\"s\":{},\"nd\":\"{}\",\"dpS\":\"{}\"",
                caller + 1,
                p + 1,
                s,
                nd,
                dp
            )
        });
    }

    /// Sigprocmask(t, nm): install a new blocked mask (already stripped of unblockable signals).
    fn sigprocmask(&mut self, t: usize, nm_bits: u64) {
        self.threads[t].set_blocked(nm_bits);
        let bl: u64 = self.threads[t].blocked();
        self.emit("Sigprocmask", move |w| {
            write!(w, ",\"t\":\"t{}\",\"nm\":", t + 1)?;
            World::w_sigarr(w, nm_bits)?;
            write!(w, ",\"tBl\":")?;
            World::w_sigarr(w, bl)
        });
    }

    /// AsyncDeliver(t): deliver the lowest-numbered deliverable handler signal; push a frame saving
    /// the current mask and mask the signal for the handler.
    fn async_deliver(&mut self, t: usize) {
        let p: usize = self.t_proc[t].unwrap_or(0);
        let bl: u64 = self.threads[t].blocked();
        let pd: u64 = self.proc_pending(p);
        // deliverable = pending handler signals not currently blocked.
        let mut chosen: Option<usize> = None;
        for &s in SIG.iter() {
            if pd & sig_bit(s) != 0 && self.disp_str(p, s) == "handler" && bl & sig_bit(s) == 0 {
                chosen = Some(s);
                break; // SIG is ascending, so first match is the minimum.
            }
        }
        if let Some(s) = chosen {
            self.t_fr[t].push(bl); // save current mask as the frame.
            let new_bl: u64 = (bl | sig_bit(s)) & maskable_bits();
            self.threads[t].set_blocked(new_bl);
            if let Some(st) = self.procs[p].state.as_mut() {
                st.signals_mut().clear_pending(s);
            }
        }
        let bl2: u64 = self.threads[t].blocked();
        let fr_len: usize = self.t_fr[t].len();
        let pd2: u64 = self.proc_pending(p);
        self.emit("AsyncDeliver", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tBl\":", t + 1)?;
            World::w_sigarr(w, bl2)?;
            write!(w, ",\"frLen\":{},\"pPd\":", fr_len)?;
            World::w_sigarr(w, pd2)
        });
    }

    /// Sigsuspend(t, tempmask): save the current mask into the single saved slot and install a
    /// temporary mask.
    fn sigsuspend(&mut self, t: usize, temp_bits: u64) {
        let cur: u64 = self.threads[t].blocked();
        self.threads[t].set_saved_blocked(Some(cur));
        self.threads[t].set_blocked(temp_bits);
        let bl: u64 = self.threads[t].blocked();
        self.emit("Sigsuspend", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tempmask\":", t + 1)?;
            World::w_sigarr(w, temp_bits)?;
            write!(w, ",\"tBl\":")?;
            World::w_sigarr(w, bl)
        });
    }

    /// Sigreturn(t): restore the mask, preferring the sigsuspend saved slot over the frame's mask,
    /// and pop one signal frame if present.
    fn sigreturn(&mut self, t: usize) {
        let saved: Option<u64> = self.threads[t].take_saved_blocked();
        let restore: u64 = if let Some(m) = saved {
            m
        } else if let Some(m) = self.t_fr[t].last().copied() {
            m
        } else {
            self.threads[t].blocked()
        };
        if !self.t_fr[t].is_empty() {
            self.t_fr[t].pop();
        }
        self.threads[t].set_blocked(restore);
        let bl: u64 = self.threads[t].blocked();
        let fr_len: usize = self.t_fr[t].len();
        self.emit("Sigreturn", move |w| {
            write!(w, ",\"t\":\"t{}\",\"tBl\":", t + 1)?;
            World::w_sigarr(w, bl)?;
            write!(w, ",\"frLen\":{}", fr_len)
        });
    }
}

//==================================================================================================
// Scenarios
//==================================================================================================
//
// Each scenario boots a fresh `World` at `TraceInit` and drives a coherent, model-valid sequence of
// real transitions. `run.sh` splits the captured console into one `.ndjson` file per scenario at the
// `@@SCENARIO@@` markers, and each file is validated independently against `spec/Trace.tla`.

macro_rules! boot {
    () => {
        match World::boot() {
            Some(w) => w,
            None => return false,
        }
    };
}

/// Lifecycle: create + preempt/schedule + mutex acquire/release + exit + join-reap.
fn scenario_lifecycle() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, false); // CreateThread(t1, t2)
    w.preempt(0); // Preempt(t1)
    w.schedule(1); // Schedule(t2)
    w.lock_acquire(1); // LockAcquire(t2, mx1)
    w.unlock(1); // Unlock(t2, mx1)
    w.exit_thread(1); // ExitThread(t2) -> zombie, proc still alive
    w.schedule(0); // Schedule(t1)
    w.join_thread(0, 1); // JoinThread(t1, t2) -> reap
    true
}

/// Join park + resume + detach.
fn scenario_join() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, false); // t2 ready
    w.create_thread(0, 2, false); // t3 ready
    w.join_thread(0, 1); // JoinThread(t1, t2): t2 ready -> t1 parks
    w.schedule(1); // Schedule(t2)
    w.exit_thread(1); // ExitThread(t2): t2 zombie, wakes joiner t1
    w.schedule(0); // Schedule(t1)
    w.join_resume(0); // JoinResume(t1): reap t2
    w.detach_thread(0, 2); // DetachThread(t1, t3): mark t3 detached
    true
}

/// Detached exit into the deferred set + safe deferred drain.
fn scenario_defer_safe() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, true); // t2 ready, detached
    w.preempt(0); // Preempt(t1)
    w.schedule(1); // Schedule(t2)
    w.exit_thread(1); // ExitThread(t2): detached -> deferred={t2}
    w.reap_deferred_safe(1); // ReapDeferredSafe(t2)
    true
}

/// Last-thread exit buries the process on harvest.
fn scenario_proc_zombie() -> bool {
    let mut w: World = boot!();
    w.exit_thread(0); // ExitThread(t1): last live thread -> proc zombie
    w.harvest_zombies(0); // HarvestZombies(p1): reap t1, bury p1
    true
}

/// Unsafe deferred drain at a yield point, before the owning process is buried.
/// reap_deferred() runs at every PM entry (exit_thread unsafe.rs:535, giveup :939, ...)
/// while the owner is still findable (find_process_mut resolves via self.zombies,
/// mod.rs:2851), so on_thread_reaped is always reached and the live count is decremented.
/// The buried-owner early-return (unsafe.rs:668) is unreachable, so there is no leak.
fn scenario_defer_unsafe() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, true); // t2 ready, detached
    w.preempt(0); // Preempt(t1)
    w.schedule(1); // Schedule(t2)
    w.exit_thread(1); // ExitThread(t2): deferred={t2}, proc alive
    w.reap_deferred_unsafe(1); // ReapDeferredUnsafe(t2): owner findable -> on_thread_reaped (decrement)
    w.schedule(0); // Schedule(t1)
    w.exit_thread(0); // ExitThread(t1): proc zombie (t2 already reaped)
    w.harvest_zombies(0); // HarvestZombies(p1): reap t1, bury p1
    true
}

/// Mutex fast path + contended block/resume + destroy.
fn scenario_mutex() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, false); // t2 ready
    w.lock_acquire(0); // LockAcquire(t1, mx1)
    w.preempt(0); // Preempt(t1)
    w.schedule(1); // Schedule(t2)
    w.lock_block(1); // LockBlock(t2, mx1): enqueue + sleep
    w.schedule(0); // Schedule(t1)
    w.unlock(0); // Unlock(t1, mx1): wake t2 (still must reacquire)
    w.preempt(0); // Preempt(t1)
    w.schedule(1); // Schedule(t2)
    w.lock_resume(1); // LockResume(t2, mx1): acquire
    w.unlock(1); // Unlock(t2, mx1)
    w.put_mutex(1); // PutMutex(t2, mx1)
    true
}

/// Condition variable wait/signal/reacquire + interrupt + destroy.
fn scenario_condvar() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, false); // t2 ready
    w.lock_acquire(0); // LockAcquire(t1, mx1)
    w.wait_cond_park(0); // WaitCondPark(t1, cv1, mx1): release + park
    w.schedule(1); // Schedule(t2)
    w.signal_cond(1); // SignalCond(t2, cv1): wake t1 to reacquire phase
    w.preempt(1); // Preempt(t2)
    w.schedule(0); // Schedule(t1)
    w.cond_resume_reacquire(0); // CondResumeReacquire(t1): relock mx1
    w.wait_cond_park(0); // WaitCondPark(t1, cv1, mx1) again
    w.schedule(1); // Schedule(t2)
    w.cond_interrupt(0); // CondInterrupt(t1): signal interrupts the cond-wait
    w.put_cond(1); // PutCond(t2, cv1)
    true
}

/// Generic sleep + wake.
fn scenario_sleep_wake() -> bool {
    let mut w: World = boot!();
    w.sleep(0); // Sleep(t1)
    w.wake(0); // Wake(t1)
    true
}

/// Signals: disposition, mask, handler post + async delivery + sigreturn, sigsuspend + sigreturn,
/// stop + continue.
fn scenario_signals() -> bool {
    let mut w: World = boot!();
    w.sigaction(0, 0, 1, "handler"); // Sigaction(t1, p1, 1, handler)
    w.sigprocmask(0, sig_bit(15)); // Sigprocmask(t1, {15})
    w.kill(0, 0, 1); // Kill(t1, p1, 1): handler -> pending={1}
    w.async_deliver(0); // AsyncDeliver(t1): deliver 1, mask it, push frame
    w.sigreturn(0); // Sigreturn(t1): pop frame, restore {15}
    w.sigsuspend(0, 0); // Sigsuspend(t1, {}): save {15}, install {}
    w.sigreturn(0); // Sigreturn(t1): restore saved {15}
    w.kill(0, 0, 19); // Kill(t1, p1, 19): default stop -> sp=true
    w.continue_process(0, 0); // ContinueProcess(t1, p1): sp=false
    true
}

/// SIGKILL terminates the whole process (all live threads -> zombie).
fn scenario_kill_terminate() -> bool {
    let mut w: World = boot!();
    w.create_thread(0, 1, false); // t2 ready
    w.kill(0, 0, 9); // Kill(t1, p1, 9): SIGKILL -> p1 zombie, t1/t2 zombie
    true
}

/// Fork + exec replace + exec refuse at MAX_THREADS.
fn scenario_fork_exec() -> bool {
    let mut w: World = boot!();
    if !w.fork(0, 1, 1) {
        return false;
    } // Fork(t1, p2, t2)
    w.exec_replace(0, 2); // ExecReplace(t1, t3): t3 runs, t1 zombie, tlive=3
    w.exec_refuse(2); // ExecRefuse(t3): tlive>=MAX -> refused
    true
}

//==================================================================================================
// Entry point
//==================================================================================================

///
/// # Description
///
/// Runs every trace scenario, emitting a `@@SCENARIO@@` boundary marker before each so `run.sh` can
/// split the captured console into one `.ndjson` file per scenario.
///
/// # Returns
///
/// `true` if every scenario completed (all traces emitted).
///
pub(crate) fn run_all() -> bool {
    let mut ok: bool = true;

    tla_trace::emit_marker("lifecycle");
    ok &= scenario_lifecycle();
    tla_trace::emit_marker("join");
    ok &= scenario_join();
    tla_trace::emit_marker("defer_safe");
    ok &= scenario_defer_safe();
    tla_trace::emit_marker("proc_zombie");
    ok &= scenario_proc_zombie();
    tla_trace::emit_marker("defer_unsafe");
    ok &= scenario_defer_unsafe();
    tla_trace::emit_marker("mutex");
    ok &= scenario_mutex();
    tla_trace::emit_marker("condvar");
    ok &= scenario_condvar();
    tla_trace::emit_marker("sleep_wake");
    ok &= scenario_sleep_wake();
    tla_trace::emit_marker("signals");
    ok &= scenario_signals();
    tla_trace::emit_marker("kill_terminate");
    ok &= scenario_kill_terminate();
    tla_trace::emit_marker("fork_exec");
    ok &= scenario_fork_exec();

    ok
}
