//! NDJSON trace emission for mem2reg algorithm.
//!
//! Instrumentation drop-in. Activated by env var `CCC_TRACE_OUT=<path>`.
//! When unset, all `emit` calls become near-no-ops (a quick guard check).
//!
//! Schema: see `.specula-output/spec/Trace.tla`. Each line is
//!   {"tag":"trace","ts":<ns>,"event":{"name":"<Action>","state":{...}, ...}}

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static WRITER: Mutex<Option<BufWriter<File>>> = Mutex::new(None);
static ALLOCA_MAP: Mutex<Option<BTreeMap<u32, u32>>> = Mutex::new(None);
static NEXT_ALLOCA_ID: Mutex<u32> = Mutex::new(1);

/// Open the trace file. Subsequent emits write to it. Re-init clears state.
pub fn init(path: &str) {
    let f = File::create(path).expect("open trace file");
    *WRITER.lock().unwrap() = Some(BufWriter::new(f));
    *ALLOCA_MAP.lock().unwrap() = Some(BTreeMap::new());
    *NEXT_ALLOCA_ID.lock().unwrap() = 1;
}

/// Flush and close the trace file.
pub fn shutdown() {
    let mut g = WRITER.lock().unwrap();
    if let Some(mut w) = g.take() {
        w.flush().ok();
    }
    *ALLOCA_MAP.lock().unwrap() = None;
}

/// True if a trace is currently active.
#[inline]
pub fn enabled() -> bool {
    WRITER.lock().unwrap().is_some()
}

/// Map an LLVM `Value(u32)` for an alloca to a stable spec alloca id (1..).
/// First call assigns id 1, second call id 2, etc. Repeat calls return the
/// previously assigned id.
pub fn alloca_id(value_id: u32) -> u32 {
    let mut g = ALLOCA_MAP.lock().unwrap();
    let m = g.as_mut().expect("alloca_id called before init");
    if let Some(&id) = m.get(&value_id) {
        return id;
    }
    let mut next = NEXT_ALLOCA_ID.lock().unwrap();
    let id = *next;
    *next += 1;
    m.insert(value_id, id);
    id
}

/// Pre-register a set of candidate alloca value-ids in sorted order so they
/// receive deterministic spec ids (1..) regardless of later encounter order.
pub fn register_allocas_sorted(values: &[u32]) {
    let mut sorted = values.to_vec();
    sorted.sort();
    for v in sorted {
        let _ = alloca_id(v);
    }
}

/// Emit one event line. The `event_inner` string is a JSON object body
/// (without the outer braces) that names the action and adds fields.
pub fn emit_raw(event_inner: &str) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut g = WRITER.lock().unwrap();
    if let Some(w) = g.as_mut() {
        let line = format!("{{\"tag\":\"trace\",\"ts\":{},\"event\":{{{}}}}}\n", now, event_inner);
        w.write_all(line.as_bytes()).ok();
        w.flush().ok();
    }
}

// ── Helpers to format JSON fragments ─────────────────────────────────────

/// `{"k":n, "k":n, ...}` for a sorted-key map of u32 → u32.
pub fn json_map_u32(m: &BTreeMap<u32, u32>) -> String {
    let mut s = String::from("{");
    let mut first = true;
    for (k, v) in m {
        if !first { s.push(','); }
        first = false;
        s.push_str(&format!("\"{}\":{}", k, v));
    }
    s.push('}');
    s
}

/// `[a, b, c]` for a sorted-int sequence.
pub fn json_arr_u32(xs: &[u32]) -> String {
    let mut s = String::from("[");
    let mut first = true;
    for x in xs {
        if !first { s.push(','); }
        first = false;
        s.push_str(&format!("{}", x));
    }
    s.push(']');
    s
}

/// `[a, b, c]` from a usize slice.
pub fn json_arr_usize(xs: &[usize]) -> String {
    let mut s = String::from("[");
    let mut first = true;
    for x in xs {
        if !first { s.push(','); }
        first = false;
        s.push_str(&format!("{}", x));
    }
    s.push(']');
    s
}

/// `[1, 2, 3]` for a sorted set of alloca-ids (translated through `alloca_id`).
pub fn json_arr_alloca_ids(values: &[u32]) -> String {
    let mut ids: Vec<u32> = values.iter().map(|v| alloca_id(*v)).collect();
    ids.sort();
    json_arr_u32(&ids)
}

/// `[1, 2, 3]` from a usize iterator (sorted).
pub fn json_arr_blocks(values: &[usize]) -> String {
    let mut v: Vec<usize> = values.to_vec();
    v.sort();
    json_arr_usize(&v)
}
