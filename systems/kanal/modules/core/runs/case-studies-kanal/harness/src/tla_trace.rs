//! TLA+ Trace emission for kanal MPMC channel.
//!
//! Category B (concurrent): per-thread timebox traces with [start, end] intervals.
//! Each thread writes to its own NDJSON file. A preprocessor merges and compresses
//! timestamps before TLC ingestion.
//!
//! Activated by setting `KANAL_TRACE_DIR` environment variable.

use std::cell::RefCell;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

/// Global monotonic clock baseline for ns-precision timestamps.
static CLOCK_BASE: OnceLock<Instant> = OnceLock::new();

/// Whether tracing is active (set once at init).
static ACTIVE: AtomicBool = AtomicBool::new(false);

/// Trace output directory.
static TRACE_DIR: OnceLock<String> = OnceLock::new();

/// Global thread counter for assigning stable thread IDs.
static THREAD_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Per-thread state: file writer + assigned thread ID.
thread_local! {
    static TL_WRITER: RefCell<Option<BufWriter<File>>> = const { RefCell::new(None) };
    static TL_TID: RefCell<Option<u64>> = const { RefCell::new(None) };
}

/// Initialize tracing. Call once at test startup.
/// If `KANAL_TRACE_DIR` is set, enables per-thread trace files.
pub fn init() {
    if ACTIVE.load(Ordering::Relaxed) {
        return;
    }
    if let Ok(dir) = std::env::var("KANAL_TRACE_DIR") {
        std::fs::create_dir_all(&dir)
            .unwrap_or_else(|e| panic!("tla_trace: failed to create dir {}: {}", dir, e));
        let _ = TRACE_DIR.set(dir.clone());
        let _ = CLOCK_BASE.set(Instant::now());
        ACTIVE.store(true, Ordering::Release);
        eprintln!("[tla_trace] Tracing to directory: {}", dir);
    }
}

/// Returns true if tracing is active.
#[inline]
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

/// Get a high-resolution timestamp in nanoseconds (relative to CLOCK_BASE).
#[inline]
fn now_ns() -> u64 {
    CLOCK_BASE
        .get()
        .map(|base| base.elapsed().as_nanos() as u64)
        .unwrap_or(0)
}

/// Ensure the current thread has a writer and TID. Returns the TID.
fn ensure_thread_init() -> u64 {
    TL_TID.with(|tid_cell| {
        if let Some(tid) = *tid_cell.borrow() {
            return tid;
        }
        let tid = THREAD_COUNTER.fetch_add(1, Ordering::Relaxed);
        *tid_cell.borrow_mut() = Some(tid);

        let dir = TRACE_DIR.get().expect("trace dir not set");
        let path = format!("{}/trace-thread-{}.ndjson", dir, tid);
        let file = File::create(&path)
            .unwrap_or_else(|e| panic!("tla_trace: failed to create {}: {}", path, e));
        TL_WRITER.with(|w| {
            *w.borrow_mut() = Some(BufWriter::new(file));
        });
        tid
    })
}

/// Write a raw JSON line to the current thread's trace file.
fn emit_line(line: &str) {
    TL_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writeln!(writer, "{}", line);
            let _ = writer.flush();
        }
    });
}

/// Flush the current thread's trace file. Call at thread shutdown.
pub fn flush() {
    TL_WRITER.with(|w| {
        if let Some(ref mut writer) = *w.borrow_mut() {
            let _ = writer.flush();
        }
    });
}

// ============================================================================
// Channel State Snapshot
// ============================================================================

/// Captured channel state under the lock.
pub struct ChannelState {
    pub queue_len: usize,
    pub send_count: u32,
    pub recv_count: u32,
    pub wait_list_len: usize,
    pub recv_blocking: bool,
}

impl ChannelState {
    /// Format as JSON object fragment.
    fn to_json(&self) -> String {
        let channel_open = self.send_count > 0 || self.recv_count > 0;
        format!(
            "\"queueLen\":{},\"sendCount\":{},\"recvCount\":{},\"channelOpen\":{},\"waitListLen\":{},\"recvBlocking\":{}",
            self.queue_len, self.send_count, self.recv_count, channel_open,
            self.wait_list_len, self.recv_blocking
        )
    }
}

// ============================================================================
// Trace Emission Functions
// ============================================================================

/// Emit a channel event with full state and optional data field.
pub fn emit_channel_event(
    event: &str,
    start: u64,
    state: &ChannelState,
    data: Option<u64>,
) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let data_str = match data {
        Some(d) => format!(",\"data\":{}", d),
        None => String::new(),
    };
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{},"state":{{{}}}{}}}"#,
        event, tid, start, end, state.to_json(), data_str
    );
    emit_line(&line);
}

/// Emit a channel event with partial state (only sendCount + recvCount).
pub fn emit_channel_event_counts(
    event: &str,
    start: u64,
    send_count: u32,
    recv_count: u32,
    data: Option<u64>,
) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let channel_open = send_count > 0 || recv_count > 0;
    let data_str = match data {
        Some(d) => format!(",\"data\":{}", d),
        None => String::new(),
    };
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{},"state":{{"sendCount":{},"recvCount":{},"channelOpen":{}}}{}}}"#,
        event, tid, start, end, send_count, recv_count, channel_open, data_str
    );
    emit_line(&line);
}

/// Emit a ref-count event (sendCount + recvCount only, no channelOpen).
/// Used for drop_sender/drop_receiver where channelOpen is not modeled
/// by the spec action (only Close sets it).
pub fn emit_refcount_event(
    event: &str,
    start: u64,
    send_count: u32,
    recv_count: u32,
) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{},"state":{{"sendCount":{},"recvCount":{}}}}}"#,
        event, tid, start, end, send_count, recv_count
    );
    emit_line(&line);
}

/// Emit a signal lifecycle event (no channel state, only signal info).
pub fn emit_signal_event(event: &str, start: u64, signal_state: &str) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{},"signalState":"{}"}}"#,
        event, tid, start, end, signal_state
    );
    emit_line(&line);
}

/// Emit a simple event with no state (e.g., thread_reset, wait_timeout).
pub fn emit_simple_event(event: &str, start: u64) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{}}}"#,
        event, tid, start, end
    );
    emit_line(&line);
}

/// Emit a waitlist-related event (e.g., cancel with waitListLen).
pub fn emit_waitlist_event(event: &str, start: u64, wait_list_len: usize) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{},"state":{{"waitListLen":{}}}}}"#,
        event, tid, start, end, wait_list_len
    );
    emit_line(&line);
}

/// Emit a queue-related event (e.g., drop_recv_future_buffered with queueLen).
pub fn emit_queue_event(event: &str, start: u64, queue_len: usize) {
    if !is_active() {
        return;
    }
    let tid = ensure_thread_init();
    let end = now_ns();
    let line = format!(
        r#"{{"tag":"trace","event":"{}","thread":{},"start":{},"end":{},"state":{{"queueLen":{}}}}}"#,
        event, tid, start, end, queue_len
    );
    emit_line(&line);
}

/// Get a start timestamp for a timebox interval.
#[inline]
pub fn ts_start() -> u64 {
    now_ns()
}
