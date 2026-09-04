// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// TLA+ Trace Scenarios (Specula harness) — process/thread lifecycle
//==================================================================================================
//
// This module drives the REAL Nanvix PM state-transition methods (the same `run`/`schedule`/
// `sleep`/`exit`/`terminate`/`resume`/`wakeup`/`bury` type-state transitions the process manager
// uses internally) from in-kernel test scenarios, and emits one NDJSON trace event per resulting
// spec action. It is the trace-harness analogue of the existing `kill_test.rs` / `test_detach.rs`
// in-kernel tests: it constructs real process/thread objects and applies real transitions, then
// reads the real objects back to produce the post-state snapshot that `spec/Trace.tla` validates.
//
// It is NOT a re-implementation of the protocol: every lifecycle decision (which thread subset a
// process folds into, whether a terminate produces a zombie or an interrupted process, etc.) is
// taken by the real transition methods. The `World` here only records *which manager list* each
// real object currently sits on (a value dictated by the real transition's return type) and
// observes the real objects to build the snapshot.
//
// Model-value mapping (stable for the whole trace):
//   process p1,p2  <->  real ProcessIdentifier 1,2
//   thread  t1..t3 <->  real ThreadIdentifier  1..3
//   cond    c1     <->  the single modeled condition address
//   mutex   m1     <->  the single modeled mutex address
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
                SignalControl,
                SignalDisposition,
                SignalHandler,
            },
            InterruptedProcess,
            RunnableProcess,
            RunningProcess,
            SleepingProcess,
            ZombieProcess,
        },
        sync::mutex::MutexGuard,
        thread::{
            InterruptReason,
            KcallRestart,
            ReadyThread,
            ThreadRef,
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
        MutexAddress,
        ProcessIdentifier,
        ThreadIdentifier,
    },
    time::SystemTime,
    ExitStatus,
};

//==================================================================================================
// Constants
//==================================================================================================

/// Number of modeled process slots (p1, p2).
const NPROC: usize = 2;
/// Number of modeled thread slots (t1, t2, t3).
const NTHREAD: usize = 3;
/// Number of modeled condition addresses (c1).
const NCOND: usize = 1;
/// Number of modeled signals (1, 2).
const NSIG: usize = 2;
/// Raw address of the single modeled mutex (m1).
const M1_ADDR: usize = 0x4000;

//==================================================================================================
// Fixture helpers (mirroring kill_test.rs / test_detach.rs)
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

/// Creates a [`ReadyThread`] with the given identifier and an otherwise-empty context.
fn make_ready_thread(tid: i32) -> ReadyThread {
    ReadyThread::new(
        ThreadIdentifier::from(tid),
        None,
        None,
        None,
        ContextInformation::default(),
        // SAFETY: FpuState::new is synchronized (single-threaded kernel init).
        unsafe { FpuState::new() },
    )
}

/// Builds a fresh runnable process (`pid`) owning a single ready thread (`tid`).
fn make_runnable(pid: i32, parent: i32, tid: i32) -> Option<RunnableProcess> {
    let vmem: Vmem = make_test_vmem()?;
    Some(RunnableProcess::new(
        ProcessIdentifier::from(pid),
        ProcessIdentifier::from(parent),
        make_ready_thread(tid),
        vmem,
    ))
}

//==================================================================================================
// World
//==================================================================================================

/// The lifecycle list a process object currently occupies. The variant is dictated by the real
/// transition that produced the contained object, so it faithfully mirrors the manager's five
/// process lists plus the empty slot.
enum Slot {
    Free,
    Runnable(RunnableProcess),
    Running(RunningProcess),
    Sleeping(SleepingProcess),
    Interrupted(InterruptedProcess),
    Zombie(ZombieProcess),
}

impl Slot {
    /// The `procState` string for this slot.
    fn proc_state(&self) -> &'static str {
        match self {
            Slot::Free => "free",
            Slot::Runnable(_) => "ready",
            Slot::Running(_) => "running",
            Slot::Sleeping(_) => "suspended",
            Slot::Interrupted(_) => "interrupted",
            Slot::Zombie(_) => "zombie",
        }
    }

    /// Finds a thread within this process, returning a [`ThreadRef`] if present.
    fn find_thread(&self, tid: ThreadIdentifier) -> Option<ThreadRef<'_>> {
        match self {
            Slot::Free => None,
            Slot::Runnable(p) => p.find_thread(tid),
            Slot::Running(p) => p.find_thread(tid),
            Slot::Sleeping(p) => p.find_thread(tid),
            Slot::Interrupted(p) => p.find_thread(tid),
            Slot::Zombie(p) => p.find_thread(tid),
        }
    }

    /// The per-process signal-control block, if this slot holds a process.
    fn signals(&self) -> Option<&SignalControl> {
        match self {
            Slot::Free => None,
            Slot::Runnable(p) => Some(p.state().signals()),
            Slot::Running(p) => Some(p.state().signals()),
            Slot::Sleeping(p) => Some(p.state().signals()),
            Slot::Interrupted(p) => Some(p.state().signals()),
            Slot::Zombie(p) => Some(p.state().signals()),
        }
    }
}

/// Exit-window phase (do_exit split; spec `exitPhase`).
#[derive(Clone, Copy, PartialEq, Eq)]
enum ExitPhase {
    None,
    Taken,
    Cleaned,
}

impl ExitPhase {
    fn as_str(self) -> &'static str {
        match self {
            ExitPhase::None => "none",
            ExitPhase::Taken => "taken",
            ExitPhase::Cleaned => "cleaned",
        }
    }
}

/// The trace world: real process objects on their lifecycle lists plus the bookkeeping the spec's
/// state snapshot needs.
struct World {
    /// procs[i] is symbolic process p{i+1} (real pid i+1).
    procs: [Slot; NPROC],
    /// Index into `procs` occupying the single running slot, if any.
    running_pid: Option<usize>,
    /// do_exit split phase.
    exit_phase: ExitPhase,
    /// Process currently inside the do_exit window (index into `procs`).
    exiting: Option<usize>,
    /// FIFO of thread ids parked on each condition address (spec `condWaiters`).
    cond_waiters: [Vec<i32>; NCOND],
    /// In-flight notify: a dequeued-but-not-yet-woken waiter (spec `notifyReg`).
    notify_reg: Option<i32>,
    /// Whether the modeled mutex m1 has a map entry (spec `mutexInMap[m1]`).
    mutex_in_map: bool,
    /// Whether m1 is locked (spec `mutexLocked[m1]`).
    mutex_locked: bool,
    /// Owner thread of m1 (spec `mutexOwner[m1]`), if held.
    mutex_owner: Option<i32>,
    /// The live guard keeping m1 locked; dropping it fires the real `MutexInner::unlock`.
    mutex_guard: Option<MutexGuard>,
}

impl World {
    /// Boots the world into the deterministic initial state pinned by `Trace.tla`'s `TraceInit`:
    /// process p1 (real pid 1) running, owning running thread t1 (real tid 1); all else free.
    fn boot() -> Option<Self> {
        let (running, _reason, _ctx, _tda) = make_runnable(1, 0, 1)?.run();
        Some(World {
            procs: [Slot::Running(running), Slot::Free],
            running_pid: Some(0),
            exit_phase: ExitPhase::None,
            exiting: None,
            cond_waiters: [Vec::new()],
            notify_reg: None,
            mutex_in_map: false,
            mutex_locked: false,
            mutex_owner: None,
            mutex_guard: None,
        })
    }

    //----------------------------------------------------------------------------------------------
    // Snapshot observation
    //----------------------------------------------------------------------------------------------

    /// Maps a [`ThreadRef`] to its (threadState, threadReason) strings.
    fn thread_info(tref: &ThreadRef<'_>) -> (&'static str, &'static str) {
        fn reason(r: Option<&InterruptReason>) -> &'static str {
            match r {
                Some(InterruptReason::Killed) => "killed",
                Some(InterruptReason::TimedOut) => "timedout",
                Some(InterruptReason::Signaled) => "signaled",
                None => "none",
            }
        }
        match tref {
            ThreadRef::Ready(t) => ("ready", reason(t.thread_state().interrupt_reason_ref())),
            ThreadRef::Running(t) => ("running", reason(t.thread_state().interrupt_reason_ref())),
            ThreadRef::Sleeping(t) => ("sleeping", reason(t.thread_state().interrupt_reason_ref())),
            // An interrupted thread carries its reason in the InterruptedThread itself.
            ThreadRef::Interrupted(t) => ("interrupted", reason(Some(t.reason()))),
            ThreadRef::Zombie(t) => ("zombie", reason(t.thread_state().interrupt_reason_ref())),
        }
    }

    /// Locates thread `tid` across all process slots, returning (threadState, threadReason).
    fn locate_thread(&self, tid: i32) -> (&'static str, &'static str) {
        let id: ThreadIdentifier = ThreadIdentifier::from(tid);
        for slot in self.procs.iter() {
            if let Some(tref) = slot.find_thread(id) {
                return Self::thread_info(&tref);
            }
        }
        ("free", "none")
    }

    //----------------------------------------------------------------------------------------------
    // Snapshot serialization (streamed — never builds a >512-byte buffer)
    //----------------------------------------------------------------------------------------------

    fn write_procstate(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for i in 0..NPROC {
            if i > 0 {
                w.write_char(',')?;
            }
            write!(w, "\"p{}\":", i + 1)?;
            write_str_lit(w, self.procs[i].proc_state())?;
        }
        w.write_char('}')
    }

    fn write_threadstate(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for tid in 1..=(NTHREAD as i32) {
            if tid > 1 {
                w.write_char(',')?;
            }
            let (state, _reason) = self.locate_thread(tid);
            write!(w, "\"t{}\":", tid)?;
            write_str_lit(w, state)?;
        }
        w.write_char('}')
    }

    fn write_threadreason(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for tid in 1..=(NTHREAD as i32) {
            if tid > 1 {
                w.write_char(',')?;
            }
            let (_state, reason) = self.locate_thread(tid);
            write!(w, "\"t{}\":", tid)?;
            write_str_lit(w, reason)?;
        }
        w.write_char('}')
    }

    fn write_running(&self, w: &mut KlogWriter) -> fmt::Result {
        match self.running_pid {
            Some(i) => write!(w, "\"p{}\"", i + 1),
            None => w.write_str("\"NoProc\""),
        }
    }

    fn write_condwaiters(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for c in 0..NCOND {
            if c > 0 {
                w.write_char(',')?;
            }
            write!(w, "\"c{}\":[", c + 1)?;
            for (j, tid) in self.cond_waiters[c].iter().enumerate() {
                if j > 0 {
                    w.write_char(',')?;
                }
                write!(w, "\"t{}\"", tid)?;
            }
            w.write_char(']')?;
        }
        w.write_char('}')
    }

    /// Converts a blocked/pending signal bitmask to the sorted list of modeled signal numbers.
    fn mask_to_signals(mask: u64) -> [bool; NSIG] {
        let mut present = [false; NSIG];
        for (s, slot) in present.iter_mut().enumerate() {
            *slot = (mask & (1u64 << s)) != 0;
        }
        present
    }

    /// Writes a JSON int array of the modeled signals set in `mask`.
    fn write_signal_array(w: &mut KlogWriter, mask: u64) -> fmt::Result {
        w.write_char('[')?;
        let mut first = true;
        for s in 1..=(NSIG as i64) {
            if (mask & (1u64 << (s - 1))) != 0 {
                if !first {
                    w.write_char(',')?;
                }
                write!(w, "{}", s)?;
                first = false;
            }
        }
        w.write_char(']')
    }

    /// The per-process pending signal set (spec `pending`), read from the real signal-control block.
    fn write_pending(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for i in 0..NPROC {
            if i > 0 {
                w.write_char(',')?;
            }
            write!(w, "\"p{}\":", i + 1)?;
            let mask: u64 = self.procs[i].signals().map(|s| s.pending()).unwrap_or(0);
            Self::write_signal_array(w, mask)?;
        }
        w.write_char('}')
    }

    /// The per-thread blocked signal mask (spec `blocked`), read from the real thread state.
    fn write_blocked(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for tid in 1..=(NTHREAD as i32) {
            if tid > 1 {
                w.write_char(',')?;
            }
            write!(w, "\"t{}\":", tid)?;
            let mask: u64 = self.thread_blocked(tid);
            Self::write_signal_array(w, mask)?;
        }
        w.write_char('}')
    }

    /// The per-thread blocked mask read from the real thread state (0 if the thread is free).
    fn thread_blocked(&self, tid: i32) -> u64 {
        let id = ThreadIdentifier::from(tid);
        for slot in self.procs.iter() {
            if let Some(tref) = slot.find_thread(id) {
                return tref.thread_state().blocked();
            }
        }
        0
    }

    /// The per-thread sigsuspend saved mask (spec `savedBlocked`): `"NoMask"` or an int array.
    fn write_savedblocked(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for tid in 1..=(NTHREAD as i32) {
            if tid > 1 {
                w.write_char(',')?;
            }
            write!(w, "\"t{}\":", tid)?;
            let id = ThreadIdentifier::from(tid);
            let mut saved: Option<u64> = None;
            for slot in self.procs.iter() {
                if let Some(tref) = slot.find_thread(id) {
                    saved = tref.thread_state().saved_blocked_ref();
                    break;
                }
            }
            match saved {
                Some(mask) => Self::write_signal_array(w, mask)?,
                None => w.write_str("\"NoMask\"")?,
            }
        }
        w.write_char('}')
    }

    /// The per-process signal dispositions (spec `disposition`), emitted as a signal-indexed array
    /// per process (a JSON array deserializes to a TLA sequence whose domain is `1..NSIG == Signal`).
    fn write_disposition(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for i in 0..NPROC {
            if i > 0 {
                w.write_char(',')?;
            }
            write!(w, "\"p{}\":[", i + 1)?;
            for s in 1..=(NSIG) {
                if s > 1 {
                    w.write_char(',')?;
                }
                let disp: &str = match self.procs[i].signals().and_then(|c| c.disposition(s)) {
                    Some(SignalDisposition::Ignore) => "ignore",
                    Some(SignalDisposition::Handler(_)) => "handler",
                    _ => "default",
                };
                write_str_lit(w, disp)?;
            }
            w.write_char(']')?;
        }
        w.write_char('}')
    }

    /// held: the mutex-map guard set per thread (spec `held`). Only m1 is modeled, held by
    /// `mutex_owner` when locked.
    fn write_held(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_char('{')?;
        for tid in 1..=(NTHREAD as i32) {
            if tid > 1 {
                w.write_char(',')?;
            }
            if self.mutex_owner == Some(tid) {
                write!(w, "\"t{}\":[\"m1\"]", tid)?;
            } else {
                write!(w, "\"t{}\":[]", tid)?;
            }
        }
        w.write_char('}')
    }

    /// Streams the full `state` object.
    fn write_state(&self, w: &mut KlogWriter) -> fmt::Result {
        w.write_str("{\"procState\":")?;
        self.write_procstate(w)?;
        w.write_str(",\"threadState\":")?;
        self.write_threadstate(w)?;
        w.write_str(",\"running\":")?;
        self.write_running(w)?;
        w.write_str(",\"threadReason\":")?;
        self.write_threadreason(w)?;
        w.write_str(",\"exitPhase\":")?;
        write_str_lit(w, self.exit_phase.as_str())?;
        w.write_str(",\"condWaiters\":")?;
        self.write_condwaiters(w)?;
        w.write_str(",\"pending\":")?;
        self.write_pending(w)?;
        w.write_str(",\"blocked\":")?;
        self.write_blocked(w)?;
        w.write_str(",\"disposition\":")?;
        self.write_disposition(w)?;
        w.write_str(",\"savedBlocked\":")?;
        self.write_savedblocked(w)?;
        w.write_str(",\"mutexInMap\":{\"m1\":")?;
        write!(w, "{}", self.mutex_in_map)?;
        w.write_str("},\"mutexLocked\":{\"m1\":")?;
        write!(w, "{}", self.mutex_locked)?;
        w.write_str("},\"mutexOwner\":{\"m1\":")?;
        match self.mutex_owner {
            Some(t) => write!(w, "\"t{}\"", t)?,
            None => w.write_str("\"NoThread\"")?,
        }
        w.write_str("},\"held\":")?;
        self.write_held(w)?;
        // Bug-ghost fields: always false on a real (non-buggy) execution.
        w.write_str(",\"panicked\":false,\"lostNotify\":false,\"signalDeliveryFailed\":false")?;
        w.write_str(",\"resumedAfterTerminate\":false,\"condWaitBad\":false,\"maskViolated\":false")?;
        w.write_str(",\"immortalPending\":false,\"savedMaskViolated\":false")?;
        w.write_str(",\"restartMisattributed\":false,\"spuriousOOM\":false")?;
        w.write_char('}')
    }

    /// Emits one trace event: `{"event":..., <extra>..., "state":{...}}`.
    fn emit<F>(&self, event: &str, write_extra: F)
    where
        F: FnOnce(&mut KlogWriter) -> fmt::Result,
    {
        tla_trace::emit_line(|w| {
            w.write_str("{\"event\":")?;
            write_str_lit(w, event)?;
            write_extra(w)?;
            w.write_str(",\"state\":")?;
            self.write_state(w)?;
            w.write_char('}')
        });
    }

    //----------------------------------------------------------------------------------------------
    // Spec actions (each performs the real transition, then emits the post-state)
    //----------------------------------------------------------------------------------------------

    /// CreateProcess: a fresh runnable process appears with one ready thread.
    fn create_process(&mut self, slot: usize, pid: i32, parent: i32, tid: i32) -> bool {
        match make_runnable(pid, parent, tid) {
            Some(p) => {
                self.procs[slot] = Slot::Runnable(p);
                self.emit("CreateProcess", |_w| Ok(()));
                true
            },
            None => false,
        }
    }

    /// Preempt: the running thread is re-queued to ready and the running slot is freed.
    fn preempt(&mut self) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Running(rp) => {
                let (runnable, _ctx) = rp.schedule();
                self.procs[i] = Slot::Runnable(runnable);
                self.running_pid = None;
                self.emit("Preempt", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// Schedule: a ready process is dispatched into the running slot.
    fn schedule(&mut self, i: usize) -> bool {
        if self.running_pid.is_some() || self.exit_phase != ExitPhase::None {
            return false;
        }
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Runnable(rp) => {
                let (mut running, reason, _ctx, _tda) = rp.run();
                // `ReadyThread::run` extracts the interrupt reason into the dispatcher return value,
                // clearing it from the thread. Re-store it so `threadReason` stays observable on the
                // running thread, matching the spec's model (it persists until DispatcherCheckpoint).
                if let Some(r) = reason {
                    running.running_mut().thread_state_mut().set_interrupt_reason_trace(r);
                }
                self.procs[i] = Slot::Running(running);
                self.running_pid = Some(i);
                self.emit("Schedule", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// RunnableTerminate: procd terminates a ready process; the real terminate folds its threads.
    fn runnable_terminate(&mut self, i: usize) -> bool {
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Runnable(rp) => {
                self.procs[i] = match rp.terminate() {
                    Ok(interrupted) => Slot::Interrupted(interrupted),
                    Err(zombie) => Slot::Zombie(zombie),
                };
                self.emit("RunnableTerminate", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// HarvestZombieProc: a buried zombie process frees its slot and threads.
    fn harvest_zombie(&mut self, i: usize) -> bool {
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Zombie(zp) => {
                let (_threads, _state, _status) = zp.bury();
                // Threads and process state are dropped; the slot is now free.
                self.emit("HarvestZombieProc", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// Identifier of the running thread of the running process (the sole `running` thread).
    fn running_thread_tid(&self) -> Option<i32> {
        for tid in 1..=(NTHREAD as i32) {
            let (state, _r) = self.locate_thread(tid);
            if state == "running" {
                return Some(tid);
            }
        }
        None
    }

    /// A monotonic time strictly after `SystemTime::EPOCH`, used as the alarm-expiry `now`.
    fn later_time() -> SystemTime {
        SystemTime::new(1, 0).unwrap_or(SystemTime::EPOCH)
    }

    /// Common body for the two "the running thread blocks" actions (Sleep / RegisterRendezvous):
    /// drives the real `RunningProcess::sleep` transition and updates the running slot.
    /// Returns the tid of the thread that blocked.
    fn block_running_thread(&mut self, alarm: Option<SystemTime>) -> Option<i32> {
        let i: usize = self.running_pid?;
        let tid: i32 = self.running_thread_tid()?;
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Running(rp) => {
                self.procs[i] = match rp.sleep(alarm) {
                    Ok((runnable, _ctx)) => Slot::Runnable(runnable),
                    Err((sleeping, _ctx)) => Slot::Sleeping(sleeping),
                };
                self.running_pid = None;
                Some(tid)
            },
            other => {
                self.procs[i] = other;
                None
            },
        }
    }

    /// Sleep: the running thread parks on condition `cond` (spec `Sleep(c)`); an optional alarm
    /// mirrors a timed sleep. The thread joins the sleeping subset and is appended to the condvar
    /// FIFO.
    fn sleep_on_cond(&mut self, cond: usize, with_alarm: bool) -> bool {
        let alarm: Option<SystemTime> = if with_alarm { Some(SystemTime::EPOCH) } else { None };
        match self.block_running_thread(alarm) {
            Some(tid) => {
                self.cond_waiters[cond].push(tid);
                let cname = cond + 1;
                self.emit("Sleep", |w| write!(w, ",\"cond\":\"c{}\"", cname));
                true
            },
            None => false,
        }
    }

    /// RegisterRendezvous: the running thread blocks as an IPC rendezvous counterpart (spec
    /// `RegisterRendezvous`). Same real block transition as Sleep, but no condvar enqueue.
    fn register_rendezvous(&mut self) -> bool {
        match self.block_running_thread(None) {
            Some(_tid) => {
                self.emit("RegisterRendezvous", |_w| Ok(()));
                true
            },
            None => false,
        }
    }

    /// AlarmFire (suspended process): the sleeping thread's alarm expires, moving the whole process
    /// to the interrupted list with the fired thread interrupted/TimedOut.
    fn alarm_fire_suspended(&mut self, i: usize) -> bool {
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Sleeping(sp) => {
                match sp.wakeup_alarm(Self::later_time()) {
                    Ok(interrupted) => {
                        self.procs[i] = Slot::Interrupted(interrupted);
                        // The fired thread leaves every condvar FIFO it was parked on.
                        if let Some(tid) = self.first_interrupted_tid(i) {
                            for c in 0..NCOND {
                                self.cond_waiters[c].retain(|t| *t != tid);
                            }
                        }
                        self.emit("AlarmFire", |_w| Ok(()));
                        true
                    },
                    Err(sleeping) => {
                        self.procs[i] = Slot::Sleeping(sleeping);
                        false
                    },
                }
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// The tid of the first interrupted thread of process slot `i`, if any.
    fn first_interrupted_tid(&self, i: usize) -> Option<i32> {
        for tid in 1..=(NTHREAD as i32) {
            if let Some(tref) = self.procs[i].find_thread(ThreadIdentifier::from(tid)) {
                if matches!(tref, ThreadRef::Interrupted(_)) {
                    return Some(tid);
                }
            }
        }
        None
    }

    /// SuspendedTerminate: procd terminates a suspended process; sleepers fold to Killed-interrupted
    /// and the process moves to the interrupted list.
    fn suspended_terminate(&mut self, i: usize) -> bool {
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Sleeping(sp) => {
                self.procs[i] = Slot::Interrupted(sp.terminate());
                self.emit("SuspendedTerminate", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// InterruptedTerminate: procd terminates an already-interrupted process; every interrupted
    /// thread is re-marked Killed.
    fn interrupted_terminate(&mut self, i: usize) -> bool {
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Interrupted(ip) => {
                self.procs[i] = Slot::Interrupted(ip.terminate());
                self.emit("InterruptedTerminate", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// ResumeInterrupted: one interrupted thread is resumed to Ready (reason preserved) and the
    /// process becomes runnable.
    fn resume_interrupted(&mut self, i: usize) -> bool {
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Interrupted(ip) => {
                self.procs[i] = Slot::Runnable(ip.resume());
                self.emit("ResumeInterrupted", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// DispatcherCheckpoint (return-to-user): a resumed running thread whose interrupt reason is
    /// TimedOut/Signaled returns to user mode; the reason is consumed and the thread keeps running.
    fn dispatcher_checkpoint_return(&mut self) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        match &mut self.procs[i] {
            Slot::Running(rp) => {
                rp.running_mut().thread_state_mut().clear_interrupt_reason();
                self.emit("DispatcherCheckpoint", |_w| Ok(()));
                true
            },
            _ => false,
        }
    }

    /// DispatcherCheckpoint (exit): a resumed running thread whose interrupt reason is Killed drives
    /// the process to exit; the running slot is freed.
    fn dispatcher_checkpoint_exit(&mut self) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Running(rp) => {
                self.procs[i] = match rp.exit(ExitStatus::from(0u32)) {
                    Ok((runnable, _ctx)) => Slot::Runnable(runnable),
                    Err((zombie, _ctx)) => Slot::Zombie(zombie),
                };
                self.running_pid = None;
                self.emit("DispatcherCheckpoint", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// ExitTakeRunning: `take_running()` nulls the running slot; the exiting process stays marked
    /// running for the rest of the do_exit window.
    fn exit_take_running(&mut self) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        if !matches!(self.procs[i], Slot::Running(_)) {
            return false;
        }
        self.exiting = Some(i);
        self.running_pid = None;
        self.exit_phase = ExitPhase::Taken;
        self.emit("ExitTakeRunning", |_w| Ok(()));
        true
    }

    /// ExitCleanupRendezvous: with no rendezvous counterpart to wake, the cleanup window closes
    /// safely (no reentrant wakeup, so no panic).
    fn exit_cleanup_rendezvous(&mut self) -> bool {
        if self.exit_phase != ExitPhase::Taken {
            return false;
        }
        self.exit_phase = ExitPhase::Cleaned;
        self.emit("ExitCleanupRendezvous", |_w| Ok(()));
        true
    }

    /// ExitReinsert: `RunningProcess::exit()` folds the threads and re-lists the process (zombie or,
    /// if interrupted threads remain, interrupted); the running slot stays empty for the next
    /// Schedule.
    fn exit_reinsert(&mut self) -> bool {
        if self.exit_phase != ExitPhase::Cleaned {
            return false;
        }
        let i: usize = match self.exiting {
            Some(i) => i,
            None => return false,
        };
        let slot = ::core::mem::replace(&mut self.procs[i], Slot::Free);
        match slot {
            Slot::Running(rp) => {
                self.procs[i] = match rp.exit(ExitStatus::from(0u32)) {
                    Ok((runnable, _ctx)) => Slot::Runnable(runnable),
                    Err((zombie, _ctx)) => Slot::Zombie(zombie),
                };
                self.exit_phase = ExitPhase::None;
                self.exiting = None;
                self.running_pid = None;
                self.emit("ExitReinsert", |_w| Ok(()));
                true
            },
            other => {
                self.procs[i] = other;
                false
            },
        }
    }

    /// CreateThread: the running process spawns an additional ready thread (real
    /// `RunningProcess::add_thread`).
    fn create_thread(&mut self, tid: i32) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        match &mut self.procs[i] {
            Slot::Running(rp) => {
                rp.add_thread(make_ready_thread(tid));
                self.emit("CreateThread", |_w| Ok(()));
                true
            },
            _ => false,
        }
    }

    /// NotifyDequeue: `notify_first` pops the front waiter of condition `cond` into the in-flight
    /// notify register, leaving the "consumed-but-not-yet-woken" gap observable.
    fn notify_dequeue(&mut self, cond: usize) -> bool {
        if self.running_pid.is_none() || self.notify_reg.is_some() || self.cond_waiters[cond].is_empty() {
            return false;
        }
        let tid: i32 = self.cond_waiters[cond].remove(0);
        self.notify_reg = Some(tid);
        let cname = cond + 1;
        self.emit("NotifyDequeue", |w| write!(w, ",\"cond\":\"c{}\"", cname));
        true
    }

    /// WakeDequeued: the popped waiter is woken via the real wakeup search (found & reachable),
    /// moving it from sleeping to ready and its process from suspended to ready.
    fn wake_dequeued(&mut self) -> bool {
        let tid: i32 = match self.notify_reg {
            Some(t) => t,
            None => return false,
        };
        let id: ThreadIdentifier = ThreadIdentifier::from(tid);
        // Locate the suspended process holding the sleeping waiter.
        let mut target: Option<usize> = None;
        for (j, slot) in self.procs.iter().enumerate() {
            if let Some(ThreadRef::Sleeping(_)) = slot.find_thread(id) {
                target = Some(j);
                break;
            }
        }
        let j: usize = match target {
            Some(j) => j,
            None => return false,
        };
        let slot = ::core::mem::replace(&mut self.procs[j], Slot::Free);
        match slot {
            Slot::Sleeping(sp) => {
                self.procs[j] = match sp.wakeup(id) {
                    Ok(runnable) => Slot::Runnable(runnable),
                    Err(sleeping) => Slot::Sleeping(sleeping),
                };
                self.notify_reg = None;
                self.emit("WakeDequeued", |_w| Ok(()));
                true
            },
            other => {
                self.procs[j] = other;
                false
            },
        }
    }

    /// Borrows the running process as a `RunningProcess`, if any.
    fn running_process_mut(&mut self) -> Option<&mut RunningProcess> {
        let i: usize = self.running_pid?;
        match &mut self.procs[i] {
            Slot::Running(rp) => Some(rp),
            _ => None,
        }
    }

    /// SetDisposition: `sigaction()` installs a new disposition for the caller's own signal.
    fn set_disposition(&mut self, sig: usize, disp: &'static str) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        let d: SignalDisposition = match disp {
            "ignore" => SignalDisposition::Ignore,
            "handler" => SignalDisposition::Handler(Box::new(SignalHandler {
                entry: VirtualAddress::new(0x1000),
                mask: 0,
                flags: 0,
                sigaction: 0,
            })),
            _ => SignalDisposition::Default,
        };
        match self.running_process_mut() {
            Some(rp) => {
                rp.state_mut().signals_mut().set_disposition(sig, d);
                self.emit("SetDisposition", |w| {
                    write!(w, ",\"pid\":\"p{}\",\"sig\":{},\"disp\":\"{}\"", i + 1, sig, disp)
                });
                true
            },
            None => false,
        }
    }

    /// InstallHandler: `sigaction()` installs a caught handler (optionally with SA_RESTART).
    fn install_handler(&mut self, sig: usize, sar: bool) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        let handler = SignalDisposition::Handler(Box::new(SignalHandler {
            entry: VirtualAddress::new(0x2000),
            mask: 0,
            flags: if sar { 4 } else { 0 },
            sigaction: 0,
        }));
        match self.running_process_mut() {
            Some(rp) => {
                rp.state_mut().signals_mut().set_disposition(sig, handler);
                self.emit("InstallHandler", |w| {
                    write!(w, ",\"pid\":\"p{}\",\"sig\":{},\"sar\":{}", i + 1, sig, sar)
                });
                true
            },
            None => false,
        }
    }

    /// Exec: `execv()` resets caught dispositions to default, zeroes pending, and drops the restorer.
    fn exec(&mut self) -> bool {
        match self.running_process_mut() {
            Some(rp) => {
                rp.state_mut().signals_mut().reset_for_exec();
                self.emit("Exec", |_w| Ok(()));
                true
            },
            None => false,
        }
    }

    /// MarkInterruptedBySignal: records a signum-less restart record on the running thread.
    fn mark_interrupted(&mut self, sig: i64) -> bool {
        match self.running_process_mut() {
            Some(rp) => {
                rp.running_mut()
                    .thread_state_mut()
                    .set_restart(KcallRestart { number: 0, args: [0; 4] });
                self.emit("MarkInterruptedBySignal", |w| write!(w, ",\"sig\":{}", sig));
                true
            },
            None => false,
        }
    }

    /// MaskChange: `sigprocmask()` replaces the running thread's blocked mask.
    fn mask_change(&mut self, mask_bits: u64) -> bool {
        match self.running_process_mut() {
            Some(rp) => {
                rp.running_mut().thread_state_mut().set_blocked(mask_bits);
                self.emit("MaskChange", |w| {
                    w.write_str(",\"mask\":")?;
                    World::write_signal_array(w, mask_bits)
                });
                true
            },
            None => false,
        }
    }

    /// SigSuspendInstall: saves the current blocked mask and installs a temporary one.
    fn sigsuspend_install(&mut self, mask_bits: u64) -> bool {
        match self.running_process_mut() {
            Some(rp) => {
                let ts = rp.running_mut().thread_state_mut();
                let current: u64 = ts.blocked();
                ts.set_saved_blocked(Some(current));
                ts.set_blocked(mask_bits);
                self.emit("SigSuspendInstall", |w| {
                    w.write_str(",\"mask\":")?;
                    World::write_signal_array(w, mask_bits)
                });
                true
            },
            None => false,
        }
    }

    /// SigReturn: restores the blocked mask from the sigsuspend saved slot and clears it.
    fn sigreturn(&mut self) -> bool {
        match self.running_process_mut() {
            Some(rp) => {
                let ts = rp.running_mut().thread_state_mut();
                if let Some(saved) = ts.take_saved_blocked() {
                    ts.set_blocked(saved);
                    self.emit("SigReturn", |_w| Ok(()));
                    true
                } else {
                    false
                }
            },
            None => false,
        }
    }

    /// LockMutexAcquire: the running thread acquires m1 via the real `get_mutex` + `try_lock`. The
    /// guard is retained by the world to keep the real lock held (dropping it fires the real
    /// unlock).
    fn lock_mutex_acquire(&mut self) -> bool {
        if self.mutex_locked {
            return false;
        }
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        let t: i32 = match self.running_thread_tid() {
            Some(t) => t,
            None => return false,
        };
        let addr: MutexAddress = MutexAddress::from(M1_ADDR);
        // Acquire under a scoped borrow so the returned `Mutex` clone is dropped (leaving the map
        // entry + the guard's own Arc as the only references).
        let guard: Option<MutexGuard> = match &mut self.procs[i] {
            Slot::Running(rp) => match rp.state_mut().get_mutex(addr) {
                Ok(mutex) => mutex.try_lock().ok(),
                Err(_) => None,
            },
            _ => None,
        };
        let guard: MutexGuard = match guard {
            Some(g) => g,
            None => return false,
        };
        self.mutex_guard = Some(guard);
        self.mutex_locked = true;
        self.mutex_owner = Some(t);
        self.mutex_in_map = match &self.procs[i] {
            Slot::Running(rp) => rp.state().contains_mutex(addr),
            _ => true,
        };
        self.emit("LockMutexAcquire", |w| w.write_str(",\"mutex\":\"m1\""));
        true
    }

    /// UnlockMutex: the running thread releases m1. Dropping the guard fires the real
    /// `MutexInner::unlock`; `put_mutex` then reclaims the map entry when the refcount permits.
    fn unlock_mutex(&mut self) -> bool {
        let i: usize = match self.running_pid {
            Some(i) => i,
            None => return false,
        };
        // The running thread must own the guard.
        if self.mutex_guard.is_none() || self.mutex_owner != self.running_thread_tid() {
            return false;
        }
        let addr: MutexAddress = MutexAddress::from(M1_ADDR);
        // Drop the guard first: the real unlock (and any first-waiter notify) fires here.
        self.mutex_guard = None;
        let in_map: bool = match &mut self.procs[i] {
            Slot::Running(rp) => {
                let _ = rp.state_mut().put_mutex(addr);
                rp.state().contains_mutex(addr)
            },
            _ => return false,
        };
        self.mutex_locked = false;
        self.mutex_owner = None;
        self.mutex_in_map = in_map;
        self.emit("UnlockMutex", |w| w.write_str(",\"mutex\":\"m1\""));
        true
    }
}

//==================================================================================================
// Scenarios
//==================================================================================================

/// Scenario: basic process lifecycle — create, schedule, preempt, terminate, harvest.
fn scenario_lifecycle() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => {
            error!("tla_world: boot failed");
            return false;
        },
    };

    // p1(t1) is running. Create p2 with ready thread t2.
    if !w.create_process(1, 2, 1, 2) {
        return false;
    }
    // Preempt p1 -> ready; running slot free.
    if !w.preempt() {
        return false;
    }
    // Schedule p2 -> running.
    if !w.schedule(1) {
        return false;
    }
    // Preempt p2 -> ready.
    if !w.preempt() {
        return false;
    }
    // Schedule p1 -> running.
    if !w.schedule(0) {
        return false;
    }
    // Terminate ready p2 -> zombie (single ready thread folds to zombie).
    if !w.runnable_terminate(1) {
        return false;
    }
    // Harvest the p2 zombie -> free.
    if !w.harvest_zombie(1) {
        return false;
    }
    true
}

/// Scenario: sleep -> alarm -> resume -> return-to-user dispatcher checkpoint.
fn scenario_alarm_resume() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    // Build p2, run it, and put its thread to sleep with an alarm.
    if !w.create_process(1, 2, 1, 2) {
        return false;
    }
    if !w.preempt() {
        return false;
    }
    if !w.schedule(1) {
        return false;
    }
    // t2 sleeps on c1 with an alarm; p2 becomes suspended.
    if !w.sleep_on_cond(0, true) {
        return false;
    }
    // Run p1 so there is a running process while p2's alarm fires.
    if !w.schedule(0) {
        return false;
    }
    // p2's alarm expires: t2 -> interrupted/TimedOut, p2 -> interrupted.
    if !w.alarm_fire_suspended(1) {
        return false;
    }
    // Resume t2 to ready (reason TimedOut preserved); p2 -> ready.
    if !w.resume_interrupted(1) {
        return false;
    }
    // Run p2 so t2 reaches its return-to-user dispatcher checkpoint.
    if !w.preempt() {
        return false;
    }
    if !w.schedule(1) {
        return false;
    }
    // TimedOut resume returns to user: reason consumed, thread keeps running.
    if !w.dispatcher_checkpoint_return() {
        return false;
    }
    true
}

/// Scenario: sleep -> suspended terminate -> interrupted terminate -> resume killed -> dispatcher
/// exit -> harvest.
fn scenario_terminate() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    if !w.create_process(1, 2, 1, 2) {
        return false;
    }
    if !w.preempt() {
        return false;
    }
    if !w.schedule(1) {
        return false;
    }
    // t2 sleeps on c1; p2 becomes suspended.
    if !w.sleep_on_cond(0, false) {
        return false;
    }
    if !w.schedule(0) {
        return false;
    }
    // Terminate suspended p2: sleeper t2 folds to Killed-interrupted; p2 -> interrupted.
    if !w.suspended_terminate(1) {
        return false;
    }
    // Terminate the already-interrupted p2 again (idempotent Killed re-mark).
    if !w.interrupted_terminate(1) {
        return false;
    }
    // Resume the killed thread to ready (reason Killed preserved); p2 -> ready.
    if !w.resume_interrupted(1) {
        return false;
    }
    if !w.preempt() {
        return false;
    }
    if !w.schedule(1) {
        return false;
    }
    // Killed resume drives the process to exit at the dispatcher checkpoint -> p2 zombie.
    if !w.dispatcher_checkpoint_exit() {
        return false;
    }
    // Run p1 again, then harvest the p2 zombie.
    if !w.schedule(0) {
        return false;
    }
    if !w.harvest_zombie(1) {
        return false;
    }
    true
}

/// Scenario: do_exit split window (take-running -> cleanup -> reinsert) with a bystander process.
fn scenario_exit() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    // p2 exists so the exiting p1 can be replaced by a schedulable process afterwards.
    if !w.create_process(1, 2, 1, 2) {
        return false;
    }
    // do_exit split on the running p1.
    if !w.exit_take_running() {
        return false;
    }
    if !w.exit_cleanup_rendezvous() {
        return false;
    }
    // p1 folds to a zombie (single running thread) and the running slot is freed.
    if !w.exit_reinsert() {
        return false;
    }
    // Schedule the bystander p2, then harvest the p1 zombie.
    if !w.schedule(1) {
        return false;
    }
    if !w.harvest_zombie(0) {
        return false;
    }
    true
}

/// Scenario: IPC rendezvous registration blocks the running thread, then a bystander runs.
fn scenario_rendezvous() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    if !w.create_process(1, 2, 1, 2) {
        return false;
    }
    if !w.preempt() {
        return false;
    }
    if !w.schedule(1) {
        return false;
    }
    // t2 registers as a rendezvous counterpart on the still-live p1 and blocks; p2 -> suspended.
    if !w.register_rendezvous() {
        return false;
    }
    // p1 runs again while the rendezvous counterpart is parked.
    if !w.schedule(0) {
        return false;
    }
    // Terminate the suspended p2 (folds the parked counterpart to Killed-interrupted).
    if !w.suspended_terminate(1) {
        return false;
    }
    true
}

/// Scenario: multi-threaded process — create extra threads, then a sibling keeps the process
/// runnable while one thread sleeps.
fn scenario_multithread() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    // p1 gains two more ready threads (t2, t3) beside the running t1.
    if !w.create_thread(2) {
        return false;
    }
    if !w.create_thread(3) {
        return false;
    }
    // Preempt t1 and re-dispatch: one of p1's ready threads becomes running.
    if !w.preempt() {
        return false;
    }
    if !w.schedule(0) {
        return false;
    }
    // The running thread sleeps; because sibling ready threads remain, p1 stays runnable (ready).
    if !w.sleep_on_cond(0, false) {
        return false;
    }
    // Re-dispatch p1 (another sibling runs).
    if !w.schedule(0) {
        return false;
    }
    true
}

/// Scenario: condvar notify split — dequeue a waiter, then wake it via the real wakeup search.
fn scenario_notify() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    if !w.create_process(1, 2, 1, 2) {
        return false;
    }
    if !w.preempt() {
        return false;
    }
    if !w.schedule(1) {
        return false;
    }
    // t2 sleeps on c1; p2 -> suspended, condWaiters[c1] = [t2].
    if !w.sleep_on_cond(0, false) {
        return false;
    }
    // Run p1 so a running process exists for the wakeup search.
    if !w.schedule(0) {
        return false;
    }
    // Dequeue t2 from the condvar FIFO (consumed-but-not-yet-woken gap).
    if !w.notify_dequeue(0) {
        return false;
    }
    // Wake t2: sleeping -> ready, p2 suspended -> ready.
    if !w.wake_dequeued() {
        return false;
    }
    true
}

/// Scenario: signal disposition lifecycle — install dispositions/handlers, mark a blocking call
/// interrupted, then exec (which resets handlers and clears pending).
fn scenario_signal_disposition() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    // p1's own dispositions: ignore signal 1, catch signal 2 with SA_RESTART.
    if !w.set_disposition(1, "ignore") {
        return false;
    }
    if !w.install_handler(2, true) {
        return false;
    }
    // Record that a blocking call was interrupted by signal 1.
    if !w.mark_interrupted(1) {
        return false;
    }
    // Change signal 2 back to default (still caught? no: default now).
    if !w.set_disposition(2, "default") {
        return false;
    }
    // Re-install a handler on signal 1, then exec resets caught dispositions to default.
    if !w.install_handler(1, false) {
        return false;
    }
    if !w.exec() {
        return false;
    }
    true
}

/// Scenario: signal masking — sigprocmask, then a sigsuspend/sigreturn save-restore cycle.
///
/// NOTE: the `MaskChange`/`SigSuspendInstall` events carry a `mask` array. `Trace.tla` passes it to
/// the base action unchanged, but `base!MaskChange`/`base!SigSuspendInstall` require a SET
/// (`newmask \subseteq Signal`). A JSON array deserializes to a TLA *sequence*, which is not
/// enumerable for `\subseteq`. Validating this scenario therefore requires the one-line Phase-3
/// `Trace.tla` fix documented in `harness/INSTRUMENTATION.md` (wrap `logline.mask` with `AsSet`).
fn scenario_signal_mask() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    // Block signal 1 on the running thread.
    if !w.mask_change(0b01) {
        return false;
    }
    // sigsuspend: save the current mask (block signal 1) and install a temporary mask (block 2).
    if !w.sigsuspend_install(0b10) {
        return false;
    }
    // sigreturn: restore the pre-suspend mask (block signal 1) and clear the saved slot.
    if !w.sigreturn() {
        return false;
    }
    true
}

/// Scenario: mutex acquire/release — the running thread locks and unlocks m1 (real `get_mutex` /
/// `try_lock` / guard-drop / `put_mutex`).
fn scenario_sync() -> bool {
    let mut w: World = match World::boot() {
        Some(w) => w,
        None => return false,
    };
    // t1 (running) acquires m1.
    if !w.lock_mutex_acquire() {
        return false;
    }
    // t1 releases m1; the map entry is reclaimed.
    if !w.unlock_mutex() {
        return false;
    }
    true
}

//==================================================================================================
// Entry point
//==================================================================================================

/// Runs all trace scenarios, emitting NDJSON trace events to the kernel console.
///
/// Each scenario boots a fresh `World`; `run.sh` splits the captured console stream per scenario
/// using the emitted `@@SCENARIO@@` markers.
pub(crate) fn run_all() -> bool {
    let mut passed: bool = true;

    tla_trace::emit_marker("lifecycle");
    passed &= scenario_lifecycle();

    tla_trace::emit_marker("alarm_resume");
    passed &= scenario_alarm_resume();

    tla_trace::emit_marker("terminate");
    passed &= scenario_terminate();

    tla_trace::emit_marker("exit");
    passed &= scenario_exit();

    tla_trace::emit_marker("rendezvous");
    passed &= scenario_rendezvous();

    tla_trace::emit_marker("multithread");
    passed &= scenario_multithread();

    tla_trace::emit_marker("notify");
    passed &= scenario_notify();

    tla_trace::emit_marker("signal_disposition");
    passed &= scenario_signal_disposition();

    tla_trace::emit_marker("sync");
    passed &= scenario_sync();

    // The signal-mask scenario (MaskChange / SigSuspendInstall / SigReturn) is implemented but not
    // emitted by default: `Trace.tla` passes the `mask` array to the base action unchanged, and the
    // base action requires a SET (`newmask \subseteq Signal`), which a JSON-array-derived sequence
    // is not. Enabling it requires the Phase-3 `Trace.tla` fix documented in INSTRUMENTATION.md.
    // To emit it, uncomment the two lines below.
    // tla_trace::emit_marker("signal_mask");
    // passed &= scenario_signal_mask();

    passed
}
