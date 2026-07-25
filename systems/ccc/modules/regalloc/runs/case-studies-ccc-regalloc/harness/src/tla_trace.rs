//! TLA+ trace emission module — Phase 2.5 harness for the CCC regalloc /
//! liveness spec. Writes one NDJSON event line per spec action to a
//! thread-local trace file. No-op when the caller has not opened a file via
//! `tla_trace::open(path)`.
//!
//! The trace format is Category A (sequential compiler pipeline), one linear
//! cursor. Every line contains `"tag": "trace"` so that the Trace.tla
//! ndJsonDeserialize filter picks it up.
//!
//! All JSON values are emitted by hand (no serde dependency) because the
//! upstream `ccc` crate does not depend on serde and we do not want to drag in
//! a new dependency for trace collection.

#![allow(dead_code)]

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Default)]
struct Ctx {
    writer: Option<BufWriter<File>>,
    func_name: String,
    seq: u64,
}

thread_local! {
    static CTX: RefCell<Ctx> = RefCell::new(Ctx::default());
}

/// Open a fresh trace file for this thread.
pub fn open(path: &str) {
    let file = File::create(path).expect("tla_trace: failed to open trace file");
    CTX.with(|c| {
        let mut c = c.borrow_mut();
        c.writer = Some(BufWriter::new(file));
        c.seq = 0;
    });
}

/// Close the trace file, flushing buffers.
pub fn close() {
    CTX.with(|c| {
        let mut c = c.borrow_mut();
        if let Some(mut w) = c.writer.take() {
            let _ = w.flush();
        }
    });
}

/// Set the "func" field for all subsequent events.
pub fn begin_function(name: &str) {
    CTX.with(|c| c.borrow_mut().func_name = name.to_string());
}

/// Return whether a writer is active — instrumentation call sites can use
/// this to skip expensive bitset decoding when tracing is off.
pub fn is_active() -> bool {
    CTX.with(|c| c.borrow().writer.is_some())
}

fn ts_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

fn next_seq() -> u64 {
    CTX.with(|c| {
        let mut c = c.borrow_mut();
        c.seq += 1;
        c.seq
    })
}

fn current_func() -> String {
    CTX.with(|c| c.borrow().func_name.clone())
}

fn write_line(line: &str) {
    CTX.with(|c| {
        let mut c = c.borrow_mut();
        if let Some(ref mut w) = c.writer {
            let _ = w.write_all(line.as_bytes());
            let _ = w.write_all(b"\n");
        }
    });
}

// ── JSON encoding helpers ───────────────────────────────────────────────────

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn fmt_u32_set(xs: &[u32]) -> String {
    let mut sorted: Vec<u32> = xs.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    let parts: Vec<String> = sorted.iter().map(|x| x.to_string()).collect();
    format!("[{}]", parts.join(","))
}

fn fmt_u8_set(xs: &[u8]) -> String {
    let mut sorted: Vec<u8> = xs.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    let parts: Vec<String> = sorted.iter().map(|x| x.to_string()).collect();
    format!("[{}]", parts.join(","))
}

fn fmt_map_u32_u32(m: &BTreeMap<u32, u32>) -> String {
    let parts: Vec<String> = m
        .iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), v))
        .collect();
    format!("{{{}}}", parts.join(","))
}

fn fmt_map_u32_i64(m: &BTreeMap<u32, i64>) -> String {
    let parts: Vec<String> = m
        .iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), v))
        .collect();
    format!("{{{}}}", parts.join(","))
}

fn fmt_map_usize_u32set(m: &BTreeMap<usize, Vec<u32>>) -> String {
    let parts: Vec<String> = m
        .iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), fmt_u32_set(v)))
        .collect();
    format!("{{{}}}", parts.join(","))
}

fn fmt_map_u8_u32(m: &BTreeMap<u8, u32>) -> String {
    let parts: Vec<String> = m
        .iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), v))
        .collect();
    format!("{{{}}}", parts.join(","))
}

// ── Config line (once per trace, before any events) ─────────────────────────

pub struct FunctionConfig<'a> {
    pub name: &'a str,
    pub vals: &'a [u32],
    pub points: &'a [u32],
    pub blocks: &'a [u32],
    pub func_end: u32,
    pub max_iters: u32,
    pub block_of_point: &'a BTreeMap<u32, u32>,
    pub block_succs: &'a BTreeMap<u32, Vec<u32>>,
    pub true_def: &'a BTreeMap<u32, u32>,
    pub true_uses: &'a BTreeMap<u32, Vec<u32>>,
    pub call_points: &'a [u32],
    pub asm_points: &'a [u32],
    pub asm_has_operands: &'a BTreeMap<u32, bool>,
    pub asm_clobbers: &'a BTreeMap<u32, Vec<u8>>,
    pub returns_twice_points: &'a [u32],
    pub is_recognized_returns_twice: &'a BTreeMap<u32, bool>,
    pub callee_saved_regs: &'a [u8],
    pub caller_saved_regs: &'a [u8],
    pub slots: &'a [u32],
    pub priority: &'a BTreeMap<u32, u32>,
}

pub fn emit_config(cfg: &FunctionConfig) {
    if !is_active() { return; }
    let mut buf = String::new();
    buf.push_str(&format!(
        "{{\"tag\":\"config\",\"ts\":{},\"func\":{},\"config\":{{",
        ts_ns(),
        json_escape(cfg.name),
    ));
    buf.push_str(&format!("\"Vals\":{},", fmt_u32_set(cfg.vals)));
    buf.push_str(&format!("\"Points\":{},", fmt_u32_set(cfg.points)));
    buf.push_str(&format!("\"Blocks\":{},", fmt_u32_set(cfg.blocks)));
    buf.push_str(&format!("\"FuncEnd\":{},", cfg.func_end));
    buf.push_str(&format!("\"MaxIters\":{},", cfg.max_iters));
    buf.push_str(&format!("\"BlockOfPoint\":{},", fmt_map_u32_u32(cfg.block_of_point)));
    // BlockSuccs — object from block_id → list of successor block_ids.
    let bs_parts: Vec<String> = cfg.block_succs.iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), fmt_u32_set(v)))
        .collect();
    buf.push_str(&format!("\"BlockSuccs\":{{{}}},", bs_parts.join(",")));
    buf.push_str(&format!("\"TrueDef\":{},", fmt_map_u32_u32(cfg.true_def)));
    let tu_parts: Vec<String> = cfg.true_uses.iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), fmt_u32_set(v)))
        .collect();
    buf.push_str(&format!("\"TrueUses\":{{{}}},", tu_parts.join(",")));
    buf.push_str(&format!("\"CallPoints\":{},", fmt_u32_set(cfg.call_points)));
    buf.push_str(&format!("\"AsmPoints\":{},", fmt_u32_set(cfg.asm_points)));
    let aho_parts: Vec<String> = cfg.asm_has_operands.iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), v))
        .collect();
    buf.push_str(&format!("\"AsmHasOperands\":{{{}}},", aho_parts.join(",")));
    let ac_parts: Vec<String> = cfg.asm_clobbers.iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), fmt_u8_set(v)))
        .collect();
    buf.push_str(&format!("\"AsmClobbers\":{{{}}},", ac_parts.join(",")));
    buf.push_str(&format!("\"ReturnsTwicePoints\":{},", fmt_u32_set(cfg.returns_twice_points)));
    let irt_parts: Vec<String> = cfg.is_recognized_returns_twice.iter()
        .map(|(k, v)| format!("{}:{}", json_escape(&k.to_string()), v))
        .collect();
    buf.push_str(&format!("\"IsRecognizedReturnsTwice\":{{{}}},", irt_parts.join(",")));
    buf.push_str(&format!("\"CalleeSavedRegs\":{},", fmt_u8_set(cfg.callee_saved_regs)));
    buf.push_str(&format!("\"CallerSavedRegs\":{},", fmt_u8_set(cfg.caller_saved_regs)));
    buf.push_str(&format!("\"Slots\":{},", fmt_u32_set(cfg.slots)));
    buf.push_str(&format!("\"Priority\":{}", fmt_map_u32_u32(cfg.priority)));
    buf.push_str("}}");
    write_line(&buf);
}

// ── Event emitters (one per spec action) ────────────────────────────────────

fn envelope_prefix(event: &str) -> String {
    format!(
        "{{\"tag\":\"trace\",\"ts\":{},\"seq\":{},\"func\":{},\"event\":{},",
        ts_ns(),
        next_seq(),
        json_escape(&current_func()),
        json_escape(event),
    )
}

/// Section 2.1 — AssignProgramPoints.
pub fn emit_assign_program_points(
    recorded_call_points: &[u32],
    computed_def: &BTreeMap<u32, u32>,
    computed_last_use: &BTreeMap<u32, u32>,
    block_gen: &BTreeMap<usize, Vec<u32>>,
    block_kill: &BTreeMap<usize, Vec<u32>>,
) {
    if !is_active() { return; }
    let mut buf = envelope_prefix("AssignProgramPoints");
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"phase\":\"Dataflow\","));
    buf.push_str(&format!("\"recordedCallPoints\":{},", fmt_u32_set(recorded_call_points)));
    buf.push_str(&format!("\"computedDef\":{},", fmt_map_u32_u32(computed_def)));
    buf.push_str(&format!("\"computedLastUse\":{},", fmt_map_u32_u32(computed_last_use)));
    buf.push_str(&format!("\"blockGen\":{},", fmt_map_usize_u32set(block_gen)));
    buf.push_str(&format!("\"blockKill\":{}", fmt_map_usize_u32set(block_kill)));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.2 — DataflowIterStep (one per outer iteration).
pub fn emit_dataflow_iter_step(
    iter: u32,
    live_in: &BTreeMap<usize, Vec<u32>>,
    live_out: &BTreeMap<usize, Vec<u32>>,
    fixpoint_reached: bool,
) {
    if !is_active() { return; }
    let phase = if fixpoint_reached { "ExtendIntervals" } else { "Dataflow" };
    let mut buf = envelope_prefix("DataflowIterStep");
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"phase\":{},", json_escape(phase)));
    buf.push_str(&format!("\"iter\":{},", iter));
    buf.push_str(&format!("\"liveIn\":{},", fmt_map_usize_u32set(live_in)));
    buf.push_str(&format!("\"liveOut\":{},", fmt_map_usize_u32set(live_out)));
    buf.push_str(&format!("\"fixpointReached\":{}", fixpoint_reached));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.3 — DataflowCapHit (emitted only when loop exited due to cap).
pub fn emit_dataflow_cap_hit() {
    if !is_active() { return; }
    let mut buf = envelope_prefix("DataflowCapHit");
    buf.push_str("\"state\":{");
    buf.push_str("\"phase\":\"ExtendIntervals\",");
    buf.push_str("\"fixpointReached\":false");
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.4 — ExtendIntervalsFromLiveness.
pub fn emit_extend_intervals(computed_last_use: &BTreeMap<u32, u32>) {
    if !is_active() { return; }
    let mut buf = envelope_prefix("ExtendIntervalsFromLiveness");
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"phase\":\"BuildIntervals\","));
    buf.push_str(&format!("\"computedLastUse\":{}", fmt_map_u32_u32(computed_last_use)));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.5 — BuildIntervals (pure phase marker).
pub fn emit_build_intervals() {
    if !is_active() { return; }
    let mut buf = envelope_prefix("BuildIntervals");
    buf.push_str("\"state\":{\"phase\":\"Phase1\"}}");
    write_line(&buf);
}

/// Section 2.6 — Phase1Allocate (one per successful assignment).
pub fn emit_phase1_allocate(
    value: u32,
    reg: u8,
    reg_free_until_at_r: u32,
    used_regs: &[u8],
    assignment_v: u8,
) {
    if !is_active() { return; }
    let mut buf = envelope_prefix("Phase1Allocate");
    buf.push_str(&format!("\"value\":{},\"reg\":{},", value, reg));
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"regFreeUntilAtR\":{},", reg_free_until_at_r));
    buf.push_str(&format!("\"usedRegs\":{},", fmt_u8_set(used_regs)));
    buf.push_str(&format!("\"assignmentV\":{}", assignment_v));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.7 — Phase1Done.
pub fn emit_phase1_done() {
    if !is_active() { return; }
    let mut buf = envelope_prefix("Phase1Done");
    buf.push_str("\"state\":{\"phase\":\"Phase2\"}}");
    write_line(&buf);
}

/// Section 2.8 — Phase2Allocate.
pub fn emit_phase2_allocate(
    value: u32,
    reg: u8,
    caller_free_until_at_r: u32,
    assignment_v: u8,
) {
    if !is_active() { return; }
    let mut buf = envelope_prefix("Phase2Allocate");
    buf.push_str(&format!("\"value\":{},\"reg\":{},", value, reg));
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"callerFreeUntilAtR\":{},", caller_free_until_at_r));
    buf.push_str(&format!("\"assignmentV\":{}", assignment_v));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.9 — Phase2Done.
pub fn emit_phase2_done() {
    if !is_active() { return; }
    let mut buf = envelope_prefix("Phase2Done");
    buf.push_str("\"state\":{\"phase\":\"Phase3\"}}");
    write_line(&buf);
}

/// Section 2.10 — Phase3Allocate.
pub fn emit_phase3_allocate(
    value: u32,
    reg: u8,
    reg_free_until_at_r: u32,
    used_regs: &[u8],
    assignment_v: u8,
) {
    if !is_active() { return; }
    let mut buf = envelope_prefix("Phase3Allocate");
    buf.push_str(&format!("\"value\":{},\"reg\":{},", value, reg));
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"regFreeUntilAtR\":{},", reg_free_until_at_r));
    buf.push_str(&format!("\"usedRegs\":{},", fmt_u8_set(used_regs)));
    buf.push_str(&format!("\"assignmentV\":{}", assignment_v));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.11 — Phase3Done.
pub fn emit_phase3_done() {
    if !is_active() { return; }
    let mut buf = envelope_prefix("Phase3Done");
    buf.push_str("\"state\":{\"phase\":\"PackSlots\"}}");
    write_line(&buf);
}

/// Section 2.12 — AssignSlot.
pub fn emit_assign_slot(value: u32, slot: i64, slot_free_until_at_s: u32) {
    if !is_active() { return; }
    let mut buf = envelope_prefix("AssignSlot");
    buf.push_str(&format!("\"value\":{},\"slot\":{},", value, slot));
    buf.push_str("\"state\":{");
    buf.push_str(&format!("\"slotFreeUntilAtS\":{},", slot_free_until_at_s));
    buf.push_str(&format!("\"slotOfV\":{}", slot));
    buf.push_str("}}");
    write_line(&buf);
}

/// Section 2.13 — PackSlotsDone.
pub fn emit_pack_slots_done() {
    if !is_active() { return; }
    let mut buf = envelope_prefix("PackSlotsDone");
    buf.push_str("\"state\":{\"phase\":\"Done\"}}");
    write_line(&buf);
}

// ── Re-exported helpers for instrumentation points ───────────────────────────

/// Convert a slice of u32 to a BTreeMap keyed by dense index, used to decode
/// dense BitSet contents to sparse value ids for instrumentation emit calls.
pub fn dense_vec_to_sparse_set(dense: &[usize], dense_to_sparse: &[u32]) -> Vec<u32> {
    dense.iter().map(|&d| dense_to_sparse[d]).collect()
}

/// Helper used by instrumentation: convert a u32-indexed Vec to a BTreeMap
/// keyed by sparse value id, skipping u32::MAX entries (not defined yet).
pub fn dense_u32_to_sparse_map(
    dense: &[u32],
    dense_to_sparse: &[u32],
) -> BTreeMap<u32, u32> {
    let mut out = BTreeMap::new();
    for (d, &sparse) in dense_to_sparse.iter().enumerate() {
        if d >= dense.len() { break; }
        let v = dense[d];
        if v != u32::MAX {
            out.insert(sparse, v);
        }
    }
    out
}
