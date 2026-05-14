//! TLA+ trace emission module for arc-swap (Phase 2.5 harness, round 4).
//!
//! Emits one NDJSON event per spec-action site.  Each event carries the global
//! `seq` counter; the spec consumer sorts events by `seq` to produce a
//! totally-ordered trace consumable by Trace.tla (Category-A style).
//!
//! Round 4 changes vs round 3:
//! * New `emit_reader_fallback_discard_node()` for the F5 split — fires after
//!   `start_cooldown + self.node.take()` in `LocalNode::new_helping`.
//! * New `emit_guard_clone()` for the F2 fork primitive — harness-only, fires
//!   when the test does `Arc::clone(&*g) + Guard::from_inner`.
//! * `ReaderFallbackControlSwap` / `ReaderFallbackConfirmOK` /
//!   `ReaderFallbackConfirmHelped` now emit `pendingHelpingTx` (BOOLEAN).
//! * `ClaimNode` now emits `localNode`.
//! * `ReaderFallbackDiscardNode` emits `localNode = "NONE"`.
//!
//! Tests are responsible for:
//!   1. calling `init(path)` once
//!   2. calling `seed_init_addr(p)` with the initial Arc pointer (becomes `a1`)
//!   3. calling `register_thread("tN")` from each worker thread before doing work
//!   4. calling `enable()` to start emitting (and `disable()` to stop)
//!   5. calling `shutdown()` to flush

#![allow(dead_code)]
#![allow(missing_docs)]

use std::cell::Cell;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread::ThreadId;

thread_local! {
    /// Set true while a thread is inside `Debt::pay_all` so that internal
    /// writer-pay events fire only on the writer path (not on Node::get,
    /// thread-local cooldown, etc.).
    static IN_PAY_ALL: Cell<bool> = const { Cell::new(false) };

    /// Set true while a thread is inside `compare_and_swap`'s loop so that
    /// the inner load's reader-fast events are suppressed (the spec's
    /// `CASBegin` collapses the inner load into one atomic action).
    static IN_CAS: Cell<bool> = const { Cell::new(false) };

    /// The CAS kind for the next `compare_and_swap` call, set by the test
    /// before invoking CAS so the harness can label the CAS event.  Defaults
    /// to "Arc" (the standard caller-supplies-an-Arc path).
    static PENDING_CAS_KIND: Cell<&'static str> = const { Cell::new("Arc") };

    /// Suppress emit_guard_into_inner from the impl's internal helper paths
    /// (e.g., fallback's `Self::new(...).into_inner()` is an internal
    /// implementation detail of the load transition, not a user action).
    static INTERNAL_INTO_INNER: Cell<bool> = const { Cell::new(false) };
}

/// RAII guard that suppresses GuardIntoInner emission for the surrounding
/// scope.  Used by fallback() where into_inner is an internal helper, not a
/// user-visible action.
pub struct InternalIntoInnerScope;

impl InternalIntoInnerScope {
    pub fn enter() -> Self {
        INTERNAL_INTO_INNER.with(|c| c.set(true));
        Self
    }
}

impl Drop for InternalIntoInnerScope {
    fn drop(&mut self) {
        INTERNAL_INTO_INNER.with(|c| c.set(false));
    }
}

#[inline]
fn internal_into_inner_suppressed() -> bool {
    INTERNAL_INTO_INNER.with(|c| c.get())
}

/// Set the CAS kind label for the next compare_and_swap on this thread.
/// Call once before each `compare_and_swap`/`rcu` invocation; reverts to "Arc"
/// after the call consumes it.
pub fn set_pending_cas_kind(kind: &'static str) {
    PENDING_CAS_KIND.with(|c| c.set(kind));
}

/// Internal: consume the kind label set by `set_pending_cas_kind` (one-shot).
pub fn take_pending_cas_kind() -> &'static str {
    PENDING_CAS_KIND.with(|c| {
        let k = c.get();
        c.set("Arc");
        k
    })
}

/// RAII guard that marks the surrounding scope as "writer pay_all in progress".
pub struct PayAllScope;

impl PayAllScope {
    pub fn enter() -> Self {
        IN_PAY_ALL.with(|c| c.set(true));
        Self
    }
}

impl Drop for PayAllScope {
    fn drop(&mut self) {
        IN_PAY_ALL.with(|c| c.set(false));
    }
}

/// RAII guard that marks the surrounding scope as "compare_and_swap in progress".
/// While set, reader-fast emissions are suppressed (the spec collapses the inner
/// load into the `CASBegin` action).
pub struct CasScope;

impl CasScope {
    pub fn enter() -> Self {
        IN_CAS.with(|c| c.set(true));
        Self
    }
}

impl Drop for CasScope {
    fn drop(&mut self) {
        IN_CAS.with(|c| c.set(false));
    }
}

#[inline]
fn in_pay_all() -> bool {
    IN_PAY_ALL.with(|c| c.get())
}

#[inline]
fn in_cas() -> bool {
    IN_CAS.with(|c| c.get())
}

static ENABLED: AtomicBool = AtomicBool::new(false);
static SEQ: AtomicU64 = AtomicU64::new(0);

struct State {
    writer: Option<BufWriter<File>>,
    threads: HashMap<ThreadId, String>,
    addrs: HashMap<usize, String>,
    next_addr: u32,
    nodes: HashMap<usize, String>,
    /// Per-thread spec-side helpGen counter (mirrors the spec's mod-(MaxHelpGen+1)
    /// arithmetic so trace replay matches without the harness needing to know
    /// the implementation's raw `local.generation`).
    help_gen: HashMap<ThreadId, u64>,
    /// (Round 4) Per-thread localNode tracking.  Defaults to the thread's own
    /// name (matching spec's Init: localNode[t] = t).  Becomes "NONE" after
    /// `emit_reader_fallback_discard_node`.  Becomes the claimed node's name
    /// after `emit_claim_node`.
    local_nodes: HashMap<ThreadId, String>,
    /// (Round 4) Per-thread pendingHelpingTx flag.  Set TRUE on
    /// ReaderFallbackControlSwap, FALSE on ReaderFallbackConfirm{OK,Helped}
    /// and on ClaimNode (re-armed transactions on a fresh node start at 0).
    pending_helping: HashMap<ThreadId, bool>,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| {
        Mutex::new(State {
            writer: None,
            threads: HashMap::new(),
            addrs: HashMap::new(),
            next_addr: 1,
            nodes: HashMap::new(),
            help_gen: HashMap::new(),
            local_nodes: HashMap::new(),
            pending_helping: HashMap::new(),
        })
    })
}

pub fn init(path: &str) {
    let mut s = state().lock().unwrap();
    s.writer = Some(BufWriter::new(File::create(path).expect("open trace file")));
    s.threads.clear();
    s.addrs.clear();
    s.nodes.clear();
    s.help_gen.clear();
    s.local_nodes.clear();
    s.pending_helping.clear();
    s.next_addr = 1;
    SEQ.store(0, Ordering::SeqCst);
    ENABLED.store(false, Ordering::SeqCst);
}

/// Seed the address map so the initial Arc pointer is recorded as `a1`.
pub fn seed_init_addr(p: usize) {
    let mut s = state().lock().unwrap();
    s.addrs.insert(p, "a1".to_string());
    s.next_addr = 2;
}

/// Register the current thread under the given spec-thread name (`t1`, `t2`, ...).
/// Round 4: also seeds `localNode[id] = name` (matches spec Init) and
/// `pendingHelpingTx[id] = false`.
pub fn register_thread(name: &str) {
    let id = std::thread::current().id();
    let mut s = state().lock().unwrap();
    s.threads.insert(id, name.to_string());
    s.local_nodes.insert(id, name.to_string());
    s.pending_helping.insert(id, false);
}

/// Map a real Node pointer to its spec-side thread name.  Called from
/// `Node::get` (in list.rs) when a thread first claims a node.
pub fn register_node(node_ptr: usize) {
    let id = std::thread::current().id();
    let mut s = state().lock().unwrap();
    let tname = match s.threads.get(&id) {
        Some(n) => n.clone(),
        None => return,
    };
    s.nodes.entry(node_ptr).or_insert(tname);
}

pub fn enable() {
    ENABLED.store(true, Ordering::SeqCst);
}

pub fn disable() {
    ENABLED.store(false, Ordering::SeqCst);
}

pub fn shutdown() {
    let mut s = state().lock().unwrap();
    if let Some(mut w) = s.writer.take() {
        let _ = w.flush();
    }
}

#[inline]
fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

fn map_addr(s: &mut State, p: usize) -> String {
    if p == 0 || p == 0b11 {
        return "NULL".to_string();
    }
    if let Some(id) = s.addrs.get(&p) {
        return id.clone();
    }
    let id = format!("a{}", s.next_addr);
    s.next_addr += 1;
    s.addrs.insert(p, id.clone());
    id
}

fn map_node(s: &State, node_ptr: usize) -> Option<String> {
    s.nodes.get(&node_ptr).cloned()
}

fn write_line(s: &mut State, body: String) {
    if let Some(ref mut w) = s.writer {
        let _ = w.write_all(body.as_bytes());
        let _ = w.write_all(b"\n");
    }
}

fn now_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

fn current_thread_name(s: &State) -> Option<String> {
    s.threads.get(&std::thread::current().id()).cloned()
}

fn current_local_node(s: &State) -> String {
    let id = std::thread::current().id();
    match s.local_nodes.get(&id) {
        Some(n) => n.clone(),
        None => "NONE".to_string(),
    }
}

fn current_pending_helping(s: &State) -> bool {
    let id = std::thread::current().id();
    *s.pending_helping.get(&id).unwrap_or(&false)
}

fn next_help_gen_spec(s: &mut State, max_help_gen: u64) -> u64 {
    let id = std::thread::current().id();
    let cur = *s.help_gen.get(&id).unwrap_or(&0);
    let next = (cur + 4) % (max_help_gen + 1);
    s.help_gen.insert(id, next);
    next
}

// ===========================================================================
// Reader fast path
// ===========================================================================

pub fn emit_reader_fast_load(storage_ptr: usize) {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let storage = map_addr(&mut s, storage_ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFastLoad","thread":"{t}","state":{{"storageAddr":"{storage}","rOpAddr":"{storage}","rPC":"r_fast_after_load","rPath":"fast"}}}}"#
    );
    write_line(&mut s, line);
}

/// `slot_idx` is the implementation's 0-based fast slot index.  We map to the
/// spec's 1..NumFastSlots range modulo NumFastSlots so the trace stays valid
/// for small NumFastSlots configs.
pub fn emit_reader_fast_slot_acquire(slot_idx_real: usize, num_fast_slots_spec: usize) {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let slot_spec = (slot_idx_real % num_fast_slots_spec) + 1;
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFastSlotAcquire","thread":"{t}","state":{{"rDebtSlot":{slot_spec},"rPC":"r_fast_after_slot"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_reader_fast_confirm_load(confirm_ptr: usize) {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let confirm = map_addr(&mut s, confirm_ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFastConfirmLoad","thread":"{t}","state":{{"rConfirmAddr":"{confirm}","rPC":"r_fast_after_confirm"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_reader_fast_branch_hit() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFastBranchHit","thread":"{t}","state":{{"rPC":"r_idle"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_reader_fast_resolve() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFastResolve","thread":"{t}","state":{{"rPC":"r_idle"}}}}"#
    );
    write_line(&mut s, line);
}

// ===========================================================================
// Reader fallback path  (helping.rs + hybrid.rs:75-103)
// ===========================================================================

pub fn emit_reader_fallback_active_addr() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackActiveAddr","thread":"{t}","state":{{"rPC":"r_fb_after_active_addr","rPath":"fallback"}}}}"#
    );
    write_line(&mut s, line);
}

/// `max_help_gen_spec` is the spec's MaxHelpGen constant — used to mirror the
/// `(gen + 4) % (MaxHelpGen + 1)` arithmetic so trace replay matches.
/// Round 4: also emits `pendingHelpingTx: true`.
pub fn emit_reader_fallback_control_swap(max_help_gen_spec: u64) {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let new_gen = next_help_gen_spec(&mut s, max_help_gen_spec);
    let id = std::thread::current().id();
    s.pending_helping.insert(id, true);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackControlSwap","thread":"{t}","state":{{"rPC":"r_fb_after_ctrl_gen","helpControl":"GEN","helpGen":{new_gen},"pendingHelpingTx":true}}}}"#
    );
    write_line(&mut s, line);
}

/// (Round 4 NEW) Fires after `start_cooldown + self.node.take()` in
/// `LocalNode::new_helping` (`debt/list.rs:296`).  At this point the thread's
/// `self.node` Cell is None — the spec's `localNode[t]` becomes `NoneGid`.
///
/// This event is only reachable when `discard == true` in `get_debt`, i.e.
/// when the implementation's raw helping generation wraps to 0 after
/// `wrapping_add(4)`.  In production (64-bit, real generations), this requires
/// 2^62 fallback calls — never reached.  In trace replay, this event will
/// appear only if the test deliberately drives a wrap (we don't; F5 is hunted
/// by MC, not trace replay).
pub fn emit_reader_fallback_discard_node() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let id = std::thread::current().id();
    s.local_nodes.insert(id, "NONE".to_string());
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackDiscardNode","thread":"{t}","state":{{"rPC":"r_fb_after_discard","localNode":"NONE"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_reader_fallback_candidate(candidate_ptr: usize) {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let confirm = map_addr(&mut s, candidate_ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackCandidate","thread":"{t}","state":{{"rConfirmAddr":"{confirm}","rPC":"r_fb_after_candidate"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_reader_fallback_slot_store(ptr: usize) {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let slot = map_addr(&mut s, ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackSlotStore","thread":"{t}","state":{{"rPC":"r_fb_after_slot","helpSlot":"{slot}"}}}}"#
    );
    write_line(&mut s, line);
}

/// Round 4: emits `pendingHelpingTx: false` (transaction completed).
pub fn emit_reader_fallback_confirm_ok() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let id = std::thread::current().id();
    s.pending_helping.insert(id, false);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackConfirmOK","thread":"{t}","state":{{"rPC":"r_idle","helpControl":"IDLE","pendingHelpingTx":false}}}}"#
    );
    write_line(&mut s, line);
}

/// Round 4: emits `pendingHelpingTx: false` (transaction completed) for audit.
pub fn emit_reader_fallback_confirm_helped() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let id = std::thread::current().id();
    s.pending_helping.insert(id, false);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackConfirmHelped","thread":"{t}","state":{{"rPC":"r_drop_paying","pendingHelpingTx":false}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_reader_fallback_resolve_envelope() {
    if !enabled() || in_cas() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ReaderFallbackResolveEnvelope","thread":"{t}","state":{{"rPC":"r_idle"}}}}"#
    );
    write_line(&mut s, line);
}

// ===========================================================================
// Writer
// ===========================================================================

pub fn emit_writer_swap(new_ptr: usize) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let storage = map_addr(&mut s, new_ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterSwap","thread":"{t}","state":{{"storageAddr":"{storage}","wPC":"w_after_swap"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_pay_init() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterPayInit","thread":"{t}","state":{{"wPC":"w_pay_init"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_traverse_load() {
    if !enabled() || !in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterTraverseLoad","thread":"{t}","state":{{"wPC":"w_traverse_loaded"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_reserve_node(node_ptr: usize, active_writers: usize) {
    if !enabled() || !in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let node_name = match map_node(&s, node_ptr) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterReserveNode","thread":"{t}","state":{{"wCurNode":"{node_name}","activeWriters":{active_writers},"wPC":"w_node_reserved"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_help_node() {
    if !enabled() || !in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterHelpNode","thread":"{t}","state":{{"wPC":"w_after_help"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_scan_slot(node_ptr: usize, _slot_idx_real: usize) {
    if !enabled() || !in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let node_name = match map_node(&s, node_ptr) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterScanSlot","thread":"{t}","state":{{"wCurNode":"{node_name}"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_release_node(node_ptr: usize, active_writers_after: usize) {
    if !enabled() || !in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let _node_name = match map_node(&s, node_ptr) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterReleaseNode","thread":"{t}","state":{{"activeWriters":{active_writers_after}}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_pay_done() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterPayDone","thread":"{t}","state":{{"wPC":"w_returning"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_writer_return() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"WriterReturn","thread":"{t}","state":{{"wPC":"w_idle"}}}}"#
    );
    write_line(&mut s, line);
}

// ===========================================================================
// Guard lifecycle / Family 2
// ===========================================================================

pub fn emit_drop_guard() {
    if !enabled() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"DropGuard","thread":"{t}","state":{{}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_guard_into_inner() {
    if !enabled() || internal_into_inner_suppressed() || in_pay_all() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"GuardIntoInner","thread":"{t}","state":{{}}}}"#
    );
    write_line(&mut s, line);
}

/// (Round 4 NEW) Harness-only event: emitted when the test forks a Guard via
/// `Arc::clone(&*g) + Guard::from_inner`.  Spec action: GuardClone — produces
/// a second guard for the same address, no-debt, refCount += 1.
pub fn emit_guard_clone() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"GuardClone","thread":"{t}","state":{{}}}}"#
    );
    write_line(&mut s, line);
}

/// Harness-only: fired when the test moves a Guard between threads.  Unlike
/// the implementation hooks, the source/destination thread names are passed
/// in by the harness — Rust's Send is implicit in ownership transfer.
pub fn emit_send_guard(src_name: &str, dst_name: &str) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"SendGuard","src":"{src_name}","dst":"{dst_name}"}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_drop_arc_swap() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"DropArcSwap","thread":"{t}","state":{{}}}}"#
    );
    write_line(&mut s, line);
}

// ===========================================================================
// CompareAndSwap (Family 2 — strategy/hybrid.rs:227-263)
// ===========================================================================

pub fn emit_cas_begin(kind: &str, cur_ptr: usize, new_ptr: usize) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let cur = map_addr(&mut s, cur_ptr);
    let new_addr = map_addr(&mut s, new_ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"CASBegin","thread":"{t}","state":{{"casKind":"{kind}","casCurAddr":"{cur}","casNewAddr":"{new_addr}","rPC":"cas_after_load"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_cas_compare_not_equal() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"CASCompareNotEqual","thread":"{t}","state":{{}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_cas_exchange_ok(new_ptr: usize) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let storage = map_addr(&mut s, new_ptr);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"CASExchangeOk","thread":"{t}","state":{{"storageAddr":"{storage}"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_cas_exchange_fail() {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"CASExchangeFail","thread":"{t}","state":{{}}}}"#
    );
    write_line(&mut s, line);
}

// ===========================================================================
// Node lifecycle (Family 4 — debt/list.rs)
// ===========================================================================

/// Round 4: emits `localNode` set to the claimed node's name (matches spec
/// `ClaimNode(t, n)` post-state `localNode'[t] = n`).  Also clears
/// `pendingHelpingTx[id]` per spec.
pub fn emit_claim_node(node_ptr: usize) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let node_name = match map_node(&s, node_ptr) {
        Some(n) => n,
        None => return,
    };
    let id = std::thread::current().id();
    s.local_nodes.insert(id, node_name.clone());
    s.pending_helping.insert(id, false);
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"ClaimNode","thread":"{t}","node":"{node_name}","state":{{"nodeState":"USED","localNode":"{node_name}"}}}}"#
    );
    write_line(&mut s, line);
}

pub fn emit_check_cooldown(node_ptr: usize) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let t = match current_thread_name(&s) {
        Some(n) => n,
        None => return,
    };
    let node_name = match map_node(&s, node_ptr) {
        Some(n) => n,
        None => return,
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"CheckCooldown","thread":"{t}","node":"{node_name}","state":{{"nodeState":"UNUSED"}}}}"#
    );
    write_line(&mut s, line);
}

// ===========================================================================
// Family 1 — relaxation adversary (harness-only)
// ===========================================================================

/// Harness-only: emitted when the test deterministically picks a
/// memory-ordering relaxation site for the current run.  No corresponding
/// implementation hook — the implementation always uses the labels the
/// authors wrote.
pub fn emit_pick_relax_site(site: &str) {
    if !enabled() {
        return;
    }
    let mut s = state().lock().unwrap();
    let seq = SEQ.fetch_add(1, Ordering::SeqCst);
    let ts = now_nanos();
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"seq":{seq},"event":"PickRelaxSite","site":"{site}"}}"#
    );
    write_line(&mut s, line);
}
