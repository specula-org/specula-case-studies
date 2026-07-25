//! Mem2reg-specific event emitters that build on `tla_trace`.
//!
//! Each function corresponds to a base spec action (see Trace.tla).
//! All emit JSON event bodies (no outer braces) per the schema in
//! `instrumentation-spec.md`.

use super::tla_trace as tt;
use crate::common::fx_hash::FxHashSet;
use std::cell::Cell;

thread_local! {
    /// Whether the current `insert_phis` invocation should emit IDF events.
    /// `promote_function` sets this true before the first call (with cost calc)
    /// and clears it before the second call (after cost drop).
    pub static IDF_EMIT: Cell<bool> = const { Cell::new(false) };
}

pub fn set_idf_emit(v: bool) {
    IDF_EMIT.with(|c| c.set(v));
}

pub fn idf_emit_enabled() -> bool {
    IDF_EMIT.with(|c| c.get())
}

// ── Phase 0/1: filter ────────────────────────────────────────────────────

pub fn start_filter() {
    if !tt::enabled() { return; }
    tt::emit_raw("\"name\":\"StartFilter\",\"state\":{\"phase\":\"FILTER\"}");
}

pub fn filter_step(block: usize, pos: usize, kind: &str, alloca_value: u32, disqualified: &FxHashSet<u32>) {
    if !tt::enabled() { return; }
    let aid = tt::alloca_id(alloca_value);
    let mut dq: Vec<u32> = disqualified.iter().map(|v| tt::alloca_id(*v)).collect();
    dq.sort();
    let body = format!(
        "\"name\":\"FilterStep\",\"block\":{},\"pos\":{},\"kind\":\"{}\",\"alloca\":{},\"state\":{{\"disqualified\":{}}}",
        block, pos, kind, aid, tt::json_arr_u32(&dq)
    );
    tt::emit_raw(&body);
}

pub fn filter_done(disqualified: &FxHashSet<u32>) {
    if !tt::enabled() { return; }
    let mut dq: Vec<u32> = disqualified.iter().map(|v| tt::alloca_id(*v)).collect();
    dq.sort();
    let body = format!(
        "\"name\":\"FilterDone\",\"state\":{{\"phase\":\"BUILD_CFG\",\"disqualified\":{}}}",
        tt::json_arr_u32(&dq)
    );
    tt::emit_raw(&body);
}

// ── Phase 2: build_cfg ───────────────────────────────────────────────────

/// Emit BuildCFG.
/// `succs[b]` is the set of successor block indices (after dedup).
pub fn build_cfg(num_blocks: usize, succs: &[Vec<u32>]) {
    if !tt::enabled() { return; }
    let mut succ_str = String::from("{");
    let mut first = true;
    for (b, s) in succs.iter().enumerate() {
        if b >= num_blocks { break; }
        if !first { succ_str.push(','); }
        first = false;
        let mut v: Vec<u32> = s.clone();
        v.sort();
        succ_str.push_str(&format!("\"{}\":{}", b, tt::json_arr_u32(&v)));
    }
    succ_str.push('}');
    let body = format!(
        "\"name\":\"BuildCFG\",\"state\":{{\"phase\":\"IDOM\",\"succs\":{}}}",
        succ_str
    );
    tt::emit_raw(&body);
}

// ── Phase 3: dominators ──────────────────────────────────────────────────

pub fn compute_rpo(rpo: &[usize]) {
    if !tt::enabled() { return; }
    let body = format!(
        "\"name\":\"ComputeRPO\",\"state\":{{\"rpo\":{}}}",
        tt::json_arr_usize(rpo)
    );
    tt::emit_raw(&body);
}

pub fn idom_iter_step(idom: &[usize], iters: usize) {
    if !tt::enabled() { return; }
    // Emit idom as a JSON array so it parses to a TLA+ sequence
    // indexable by block-index + 1. usize::MAX -> -1 = spec UNDEF.
    let mut s = String::from("[");
    let mut first = true;
    for &d in idom {
        if !first { s.push(','); }
        first = false;
        let v: i64 = if d == usize::MAX { -1 } else { d as i64 };
        s.push_str(&format!("{}", v));
    }
    s.push(']');
    let body = format!(
        "\"name\":\"IdomIterStep\",\"state\":{{\"idom_arr\":{},\"idomIters\":{}}}",
        s, iters
    );
    tt::emit_raw(&body);
}

pub fn idom_done() {
    if !tt::enabled() { return; }
    tt::emit_raw("\"name\":\"IdomDone\",\"state\":{\"phase\":\"DF\"}");
}

// ── Phase 4: dominance frontiers ─────────────────────────────────────────

pub fn compute_df(df: &[FxHashSet<usize>]) {
    if !tt::enabled() { return; }
    let mut s = String::from("{");
    let mut first = true;
    for (b, set) in df.iter().enumerate() {
        if !first { s.push(','); }
        first = false;
        let mut v: Vec<usize> = set.iter().copied().collect();
        v.sort();
        s.push_str(&format!("\"{}\":{}", b, tt::json_arr_usize(&v)));
    }
    s.push('}');
    let body = format!(
        "\"name\":\"ComputeDF\",\"state\":{{\"phase\":\"IDF\",\"df\":{}}}",
        s
    );
    tt::emit_raw(&body);
}

// ── Phase 5: IDF ─────────────────────────────────────────────────────────

pub fn idf_init_alloca(alloca_value: u32, def_blocks: &FxHashSet<usize>) {
    if !tt::enabled() { return; }
    let aid = tt::alloca_id(alloca_value);
    let mut v: Vec<usize> = def_blocks.iter().copied().collect();
    v.sort();
    let body = format!(
        "\"name\":\"IdfInitAlloca\",\"alloca\":{},\"state\":{{\"def_blocks_a\":{}}}",
        aid, tt::json_arr_usize(&v)
    );
    tt::emit_raw(&body);
}

pub fn idf_worklist_step(alloca_value: u32, block: usize, phi_site_value_ids: &[u32]) {
    if !tt::enabled() { return; }
    let aid = tt::alloca_id(alloca_value);
    let mut v: Vec<u32> = phi_site_value_ids.iter().map(|val| tt::alloca_id(*val)).collect();
    v.sort();
    let body = format!(
        "\"name\":\"IdfWorklistStep\",\"alloca\":{},\"block\":{},\"state\":{{\"phi_sites_b\":{}}}",
        aid, block, tt::json_arr_u32(&v)
    );
    tt::emit_raw(&body);
}

pub fn idf_finish_alloca(alloca_value: u32) {
    if !tt::enabled() { return; }
    let aid = tt::alloca_id(alloca_value);
    let body = format!("\"name\":\"IdfFinishAlloca\",\"alloca\":{}", aid);
    tt::emit_raw(&body);
}

pub fn idf_phase_done() {
    if !tt::enabled() { return; }
    tt::emit_raw("\"name\":\"IdfPhaseDone\",\"state\":{\"phase\":\"COST_DROP\"}");
}

// ── Phase 6: cost drop ───────────────────────────────────────────────────

pub fn cost_drop_action(dropped: &FxHashSet<u32>, total_cost: usize) {
    if !tt::enabled() { return; }
    let mut v: Vec<u32> = dropped.iter().map(|val| tt::alloca_id(*val)).collect();
    v.sort();
    let body = format!(
        "\"name\":\"CostDropAction\",\"state\":{{\"phase\":\"REINSERT\",\"dropped_by_cost\":{},\"total_phi_cost\":{}}}",
        tt::json_arr_u32(&v), total_cost
    );
    tt::emit_raw(&body);
}

// ── Phase 7: reinsert ────────────────────────────────────────────────────

pub fn reinsert_phis(promoted: &[u32]) {
    if !tt::enabled() { return; }
    let mut v: Vec<u32> = promoted.iter().map(|val| tt::alloca_id(*val)).collect();
    v.sort();
    let body = format!(
        "\"name\":\"ReinsertPhis\",\"state\":{{\"phase\":\"RENAME\",\"promoted\":{}}}",
        tt::json_arr_u32(&v)
    );
    tt::emit_raw(&body);
}

// ── Phase 8: rename ──────────────────────────────────────────────────────

pub fn start_rename() {
    if !tt::enabled() { return; }
    tt::emit_raw("\"name\":\"StartRename\",\"state\":{\"rename_stack_len\":1}");
}

pub fn rename_push_phi_defs(block: usize, phi_pushed: &[u32]) {
    if !tt::enabled() { return; }
    let mut v: Vec<u32> = phi_pushed.iter().map(|val| tt::alloca_id(*val)).collect();
    v.sort();
    let body = format!(
        "\"name\":\"RenamePushPhiDefs\",\"block\":{},\"state\":{{\"phi_pushed\":{}}}",
        block, tt::json_arr_u32(&v)
    );
    tt::emit_raw(&body);
}

pub fn rename_inst_step(block: usize, pos: usize, kind: &str, alloca_value: Option<u32>) {
    if !tt::enabled() { return; }
    let aid_str = match alloca_value {
        Some(v) => format!(",\"alloca\":{}", tt::alloca_id(v)),
        None => String::new(),
    };
    let body = format!(
        "\"name\":\"RenameInstStep\",\"block\":{},\"pos\":{},\"kind\":\"{}\"{}",
        block, pos, kind, aid_str
    );
    tt::emit_raw(&body);
}

pub fn rename_fill_phis(block: usize, succs_filled: &[usize]) {
    if !tt::enabled() { return; }
    let mut v: Vec<usize> = succs_filled.to_vec();
    v.sort();
    let body = format!(
        "\"name\":\"RenameFillPhis\",\"block\":{},\"state\":{{\"succs_filled\":{}}}",
        block, tt::json_arr_usize(&v)
    );
    tt::emit_raw(&body);
}

pub fn rename_descend_child(block: usize, child: usize, is_goto: bool, stack_len: usize) {
    if !tt::enabled() { return; }
    let body = format!(
        "\"name\":\"RenameDescendChild\",\"block\":{},\"child\":{},\"is_goto\":{},\"state\":{{\"rename_stack_len\":{}}}",
        block, child, is_goto, stack_len
    );
    tt::emit_raw(&body);
}

pub fn rename_pop_frame(block: usize, stack_len: usize) {
    if !tt::enabled() { return; }
    let body = format!(
        "\"name\":\"RenamePopFrame\",\"block\":{},\"state\":{{\"rename_stack_len\":{}}}",
        block, stack_len
    );
    tt::emit_raw(&body);
}

pub fn rename_done() {
    if !tt::enabled() { return; }
    tt::emit_raw("\"name\":\"RenameDone\",\"state\":{\"phase\":\"REMOVE\"}");
}

// ── Phase 9: remove ──────────────────────────────────────────────────────

pub fn remove_action(removed: &[u32]) {
    if !tt::enabled() { return; }
    let mut v: Vec<u32> = removed.iter().map(|val| tt::alloca_id(*val)).collect();
    v.sort();
    let body = format!(
        "\"name\":\"RemoveAction\",\"state\":{{\"phase\":\"PHI_ELIM\",\"removed_allocas\":{}}}",
        tt::json_arr_u32(&v)
    );
    tt::emit_raw(&body);
}

// ── Phase 10: phi elim ───────────────────────────────────────────────────

pub fn phi_elim_plan(num_trampolines: usize) {
    if !tt::enabled() { return; }
    let body = format!(
        "\"name\":\"PhiElimPlan\",\"state\":{{\"phase\":\"DONE\",\"num_trampolines\":{}}}",
        num_trampolines
    );
    tt::emit_raw(&body);
}
