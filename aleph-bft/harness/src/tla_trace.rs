//! Trace emission for TLA+ trace validation (Specula).
//!
//! Generates NDJSON traces that align with `.specula-output/spec/Trace.tla`.
//! Every line carries `"tag": "trace"`; the validator filters on that field.
//!
//! Activated only when `TLA_TRACE_FILE` is set in the environment. When
//! unset, all `emit_*` calls become cheap no-ops, so leaving the
//! instrumentation in place during normal runs has near-zero cost.

use crate::{
    alerts::Alert,
    units::{Unit, UnitCoord},
    Data, Hasher, NodeIndex, Round, Signature,
};
use parking_lot::Mutex;
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

const TRACE_ENV: &str = "TLA_TRACE_FILE";

struct Writer {
    file: Mutex<File>,
}

static GLOBAL: Mutex<Option<Arc<Writer>>> = parking_lot::const_mutex(None);

fn writer() -> Option<Arc<Writer>> {
    if let Some(w) = GLOBAL.lock().as_ref() {
        return Some(w.clone());
    }
    let path = std::env::var(TRACE_ENV).ok()?;
    let mut guard = GLOBAL.lock();
    if let Some(w) = guard.as_ref() {
        return Some(w.clone());
    }
    let pb = PathBuf::from(&path);
    if let Some(parent) = pb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let file = match OpenOptions::new()
        .create(true)
        .append(true)
        .open(&pb)
    {
        Ok(f) => f,
        Err(e) => {
            eprintln!("tla_trace: failed to open {}: {}", path, e);
            return None;
        }
    };
    let w = Arc::new(Writer {
        file: Mutex::new(file),
    });
    *guard = Some(w.clone());
    Some(w)
}

fn ts_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

// === Shadow state counters =============================================
// The spec exposes counters (e.g., inFlightUnitsCount, broadcastUnitsCount)
// that have no in-impl variable. We maintain shadow counters keyed by
// node_id so each test member can be tracked independently.

#[derive(Default, Clone, Copy)]
pub(crate) struct Counters {
    pub in_flight: u64,
    pub persisted: u64,
    pub broadcast: u64,
    pub confirmed_alerts: u64,
    pub committed_units: u64,
    /// Cardinality(allUnits[n]) as tracked by the spec — increments on the
    /// same events the spec's `allUnits[n] = @ \cup {u}` updates (DeliverUnit,
    /// BroadcastUnit, ApplyForkingNotificationUnits). The impl's
    /// store/processing_units split would over-count during the
    /// Sign-to-BroadcastUnit window for own units, so we keep a separate
    /// shadow counter aligned with the spec.
    pub all_units: u64,
}

static COUNTERS: Mutex<BTreeMap<usize, Counters>> = parking_lot::const_mutex(BTreeMap::new());

fn with_counters<F, R>(node: NodeIndex, f: F) -> R
where
    F: FnOnce(&mut Counters) -> R,
{
    let mut g = COUNTERS.lock();
    let c = g.entry(node.0).or_default();
    f(c)
}

pub fn reset_counters(node: NodeIndex) {
    let mut g = COUNTERS.lock();
    g.insert(node.0, Counters::default());
}

pub fn snapshot(node: NodeIndex) -> Counters {
    let g = COUNTERS.lock();
    g.get(&node.0).cloned().unwrap_or_default()
}

pub fn in_flight_inc(node: NodeIndex) {
    with_counters(node, |c| c.in_flight = c.in_flight.saturating_add(1));
}

pub fn in_flight_dec(node: NodeIndex) {
    with_counters(node, |c| c.in_flight = c.in_flight.saturating_sub(1));
}

pub fn persisted_inc(node: NodeIndex) {
    with_counters(node, |c| c.persisted = c.persisted.saturating_add(1));
}

pub fn broadcast_inc(node: NodeIndex) {
    with_counters(node, |c| c.broadcast = c.broadcast.saturating_add(1));
}

pub fn confirmed_alerts_inc(node: NodeIndex) {
    with_counters(node, |c| {
        c.confirmed_alerts = c.confirmed_alerts.saturating_add(1)
    });
}

pub fn committed_units_inc(node: NodeIndex, n: u64) {
    with_counters(node, |c| {
        c.committed_units = c.committed_units.saturating_add(n);
        c.all_units = c.all_units.saturating_add(n);
    });
}

pub fn all_units_inc(node: NodeIndex) {
    with_counters(node, |c| c.all_units = c.all_units.saturating_add(1));
}

// === Per-node tracked totals (computed once, refreshed by callbacks) ===
//
// The spec also needs Cardinality(allUnits[i]), Cardinality(knownAlerts[i]),
// and similar. Rather than walking real structures for every emit, callers
// pass the live size in via the emit_* helpers (cheap on small DAGs).

// === JSON formatting helpers ===========================================
//
// We avoid pulling in serde to keep the dependency surface minimal. All
// emitted values are bounded structures so manual formatting is OK.

fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Format a single parents list. We accept any iterator yielding UnitCoord.
fn parents_json<I: IntoIterator<Item = UnitCoord>>(parents: I) -> String {
    let mut out = String::from("[");
    let mut first = true;
    for c in parents {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(&format!(
            "{{\"creator\":{},\"round\":{}}}",
            c.creator().0,
            c.round()
        ));
    }
    out.push(']');
    out
}

/// Build a unit JSON record (creator, round, variant, parents).
/// `variant` is synthetic — honest impl emits 1; harness assigns >1 for forks.
fn unit_json<U: Unit>(u: &U, variant: u32) -> String {
    let coord = u.coord();
    format!(
        "{{\"creator\":{},\"round\":{},\"variant\":{},\"parents\":{}}}",
        coord.creator().0,
        coord.round(),
        variant,
        parents_json(u.control_hash().parents())
    )
}

/// Build an alert JSON record matching the spec's Trace alert schema.
///
/// Uses the `pub(crate)` accessors `Alert::sender_index()`, `Alert::proof_ref()`,
/// `Alert::legit_units_ref()` added by instrumentation.
pub(crate) fn alert_json<H: Hasher, D: Data, S: Signature>(
    a: &Alert<H, D, S>,
) -> String {
    let (u1, u2) = a.proof_ref();
    let mut legit_out = String::from("[");
    let mut first = true;
    for u in a.legit_units_ref().iter() {
        if !first {
            legit_out.push(',');
        }
        first = false;
        legit_out.push_str(&unit_json(u.as_signable(), 1));
    }
    legit_out.push(']');
    format!(
        "{{\"sender\":{},\"forker\":{},\"proof\":{{\"unit1\":{},\"unit2\":{}}},\"legitUnits\":{}}}",
        a.sender_index().0,
        a.forker().0,
        unit_json(u1.as_signable(), 1),
        unit_json(u2.as_signable(), 2),
        legit_out
    )
}

/// Low-level write. `event_body` is the JSON content of the "event" object
/// (without the surrounding braces).
fn write_line(event_body: String) {
    if let Some(w) = writer() {
        let line = format!(
            "{{\"tag\":\"trace\",\"ts\":{},\"event\":{{{}}}}}\n",
            ts_nanos(),
            event_body
        );
        let mut f = w.file.lock();
        let _ = f.write_all(line.as_bytes());
    }
}

// === High-level event emitters =========================================

fn state_for_node(
    node: NodeIndex,
    last_signed_round: Option<i32>,
    all_units: Option<u64>,
    known_alerts: Option<u64>,
    known_rmcs: Option<u64>,
    local_forkers: Option<u64>,
) -> String {
    let c = snapshot(node);
    let mut parts: Vec<String> = Vec::new();
    if let Some(r) = last_signed_round {
        parts.push(format!("\"lastSignedRound\":{}", r));
    }
    parts.push(format!("\"inFlightUnitsCount\":{}", c.in_flight));
    parts.push(format!("\"persistedUnitsCount\":{}", c.persisted));
    parts.push(format!("\"broadcastUnitsCount\":{}", c.broadcast));
    if let Some(u) = all_units {
        parts.push(format!("\"allUnitsCount\":{}", u));
    }
    if let Some(u) = known_alerts {
        parts.push(format!("\"knownAlertsCount\":{}", u));
    }
    if let Some(u) = known_rmcs {
        parts.push(format!("\"knownRmcsCount\":{}", u));
    }
    parts.push(format!("\"confirmedAlertsCount\":{}", c.confirmed_alerts));
    if let Some(u) = local_forkers {
        parts.push(format!("\"localForkersCount\":{}", u));
    }
    parts.push(format!("\"committedUnitsCount\":{}", c.committed_units));
    format!("{{{}}}", parts.join(","))
}

pub fn emit_sign<U: Unit>(node: NodeIndex, unit: &U, last_signed_round: Round) {
    if writer().is_none() {
        return;
    }
    let unit_str = unit_json(unit, 1);
    let state = state_for_node(
        node,
        Some(last_signed_round as i32),
        None,
        None,
        None,
        None,
    );
    write_line(format!(
        "\"name\":\"Sign\",\"nid\":{},\"unit\":{},\"state\":{}",
        node.0, unit_str, state
    ));
}

pub fn emit_persist_unit<U: Unit>(node: NodeIndex, unit: &U) {
    if writer().is_none() {
        return;
    }
    let unit_str = unit_json(unit, 1);
    let state = state_for_node(node, None, None, None, None, None);
    write_line(format!(
        "\"name\":\"PersistUnit\",\"nid\":{},\"unit\":{},\"state\":{}",
        node.0, unit_str, state
    ));
}

pub fn emit_broadcast_unit<U: Unit>(node: NodeIndex, unit: &U, _all_units_hint: u64) {
    if writer().is_none() {
        return;
    }
    all_units_inc(node);
    let post = snapshot(node).all_units;
    let unit_str = unit_json(unit, 1);
    let state = state_for_node(node, None, Some(post), None, None, None);
    write_line(format!(
        "\"name\":\"BroadcastUnit\",\"nid\":{},\"unit\":{},\"state\":{}",
        node.0, unit_str, state
    ));
}

pub fn emit_deliver_unit<U: Unit>(node: NodeIndex, unit: &U, _all_units_hint: u64) {
    if writer().is_none() {
        return;
    }
    all_units_inc(node);
    let post = snapshot(node).all_units;
    let unit_str = unit_json(unit, 1);
    let state = state_for_node(node, None, Some(post), None, None, None);
    write_line(format!(
        "\"name\":\"DeliverUnit\",\"nid\":{},\"unit\":{},\"state\":{}",
        node.0, unit_str, state
    ));
}

pub fn emit_detect_fork<U1: Unit, U2: Unit>(
    node: NodeIndex,
    forker: NodeIndex,
    u_new: &U1,
    u_canon: &U2,
    local_forkers: u64,
    known_alerts: u64,
    known_rmcs: u64,
) {
    if writer().is_none() {
        return;
    }
    let unew = unit_json(u_new, 2);
    let ucan = unit_json(u_canon, 1);
    let state = state_for_node(
        node,
        None,
        None,
        Some(known_alerts),
        Some(known_rmcs),
        Some(local_forkers),
    );
    write_line(format!(
        "\"name\":\"DetectFork\",\"nid\":{},\"forker\":{},\"uNew\":{},\"uCanon\":{},\"state\":{}",
        node.0, forker.0, unew, ucan, state
    ));
}

pub fn emit_receive_alert<H: Hasher, D: Data, S: Signature>(
    node: NodeIndex,
    alert: &Alert<H, D, S>,
    repeated: bool,
    known_alerts: u64,
    known_rmcs: u64,
    local_forkers: u64,
) {
    if writer().is_none() {
        return;
    }
    let alert_str = alert_json(alert);
    let state = state_for_node(
        node,
        None,
        None,
        Some(known_alerts),
        Some(known_rmcs),
        Some(local_forkers),
    );
    write_line(format!(
        "\"name\":\"ReceiveAlert\",\"nid\":{},\"alert\":{},\"repeated\":{},\"state\":{}",
        node.0, alert_str, repeated, state
    ));
}

pub fn emit_confirm_alert<H: Hasher, D: Data, S: Signature>(
    node: NodeIndex,
    alert: &Alert<H, D, S>,
    ok: bool,
) {
    if writer().is_none() {
        return;
    }
    let alert_str = alert_json(alert);
    let outcome = if ok { "ok" } else { "badCommitment" };
    let state = state_for_node(node, None, None, None, None, None);
    write_line(format!(
        "\"name\":\"ConfirmAlert\",\"nid\":{},\"alert\":{},\"outcome\":{},\"state\":{}",
        node.0,
        alert_str,
        json_str(outcome),
        state
    ));
}

pub fn emit_apply_forking_units<H: Hasher, D: Data, S: Signature>(
    node: NodeIndex,
    alert: &Alert<H, D, S>,
    all_units: u64,
) {
    if writer().is_none() {
        return;
    }
    let alert_str = alert_json(alert);
    let state = state_for_node(node, None, Some(all_units), None, None, None);
    write_line(format!(
        "\"name\":\"ApplyForkingNotificationUnits\",\"nid\":{},\"alert\":{},\"state\":{}",
        node.0, alert_str, state
    ));
}

pub fn emit_run_election(
    node: NodeIndex,
    round: Round,
    head_creator: NodeIndex,
    head_round: Round,
) {
    if writer().is_none() {
        return;
    }
    write_line(format!(
        "\"name\":\"RunElection\",\"nid\":{},\"round\":{},\"head\":{{\"creator\":{},\"round\":{}}},\"state\":{{\"decided\":{{\"creator\":{},\"round\":{}}}}}",
        node.0, round, head_creator.0, head_round, head_creator.0, head_round
    ));
}

pub fn emit_crash(node: NodeIndex) {
    if writer().is_none() {
        return;
    }
    write_line(format!(
        "\"name\":\"Crash\",\"nid\":{},\"state\":{{\"crashed\":true}}",
        node.0
    ));
}

pub fn emit_restart_load_backup(node: NodeIndex, last_signed_round: i32, all_units: u64) {
    if writer().is_none() {
        return;
    }
    write_line(format!(
        "\"name\":\"RestartLoadBackup\",\"nid\":{},\"state\":{{\"lastSignedRound\":{},\"allUnitsCount\":{}}}",
        node.0, last_signed_round, all_units
    ));
}

pub fn emit_restart_starting_round(node: NodeIndex, refused: bool) {
    if writer().is_none() {
        return;
    }
    write_line(format!(
        "\"name\":\"RestartStartingRound\",\"nid\":{},\"state\":{{\"refused\":{},\"crashed\":false}}",
        node.0, refused
    ));
}

pub fn emit_record_newest_response_honest(node: NodeIndex, peer: NodeIndex) {
    if writer().is_none() {
        return;
    }
    write_line(format!(
        "\"name\":\"RecordNewestResponseHonest\",\"nid\":{},\"peer\":{},\"state\":{{}}",
        node.0, peer.0
    ));
}

#[allow(dead_code)]
pub fn emit_record_newest_response_byz(node: NodeIndex, peer: NodeIndex, round: i32) {
    if writer().is_none() {
        return;
    }
    write_line(format!(
        "\"name\":\"RecordNewestResponseByz\",\"nid\":{},\"peer\":{},\"round\":{},\"state\":{{}}",
        node.0, peer.0, round
    ));
}
