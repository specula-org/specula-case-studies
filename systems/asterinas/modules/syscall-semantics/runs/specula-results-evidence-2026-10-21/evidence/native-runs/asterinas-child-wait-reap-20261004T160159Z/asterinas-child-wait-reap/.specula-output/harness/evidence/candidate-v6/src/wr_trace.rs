// SPDX-License-Identifier: MPL-2.0

//! Bounded, single-writer capture for the wait/reap fixture.

use core::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

use crate::task::Task;

pub type Call = [u64; 2];
const CAPACITY: usize = 1024;
const WORDS: usize = 40;
pub const NO_CALL: Call = [0, 0];

struct Record {
    words: [AtomicU64; WORDS],
}

#[repr(align(64))]
struct Stream {
    task: AtomicUsize,
    tid: AtomicU64,
    count: AtomicUsize,
    dropped: AtomicUsize,
    generation: AtomicU64,
    active: AtomicBool,
    created: AtomicBool,
    outcome: AtomicU64,
    arm_pair: AtomicBool,
    read_code: AtomicU64,
    remaining: AtomicU64,
    channel: AtomicU64,
    park: AtomicBool,
    dequeue_start: AtomicU64,
    output_delay: AtomicU64,
    records: [Record; CAPACITY],
}

impl Stream {
    const fn new() -> Self {
        Self {
            task: AtomicUsize::new(0), tid: AtomicU64::new(0),
            count: AtomicUsize::new(0), dropped: AtomicUsize::new(0),
            generation: AtomicU64::new(0), active: AtomicBool::new(false),
            created: AtomicBool::new(false), outcome: AtomicU64::new(0),
            arm_pair: AtomicBool::new(false), read_code: AtomicU64::new(0),
            remaining: AtomicU64::new(0), channel: AtomicU64::new(0),
            park: AtomicBool::new(false), dequeue_start: AtomicU64::new(0),
            output_delay: AtomicU64::new(0),
            records: [const { Record { words: [const { AtomicU64::new(0) }; WORDS] } }; CAPACITY],
        }
    }
}

// Each registered task owns one cache-separated stream. Atomic storage also
// makes final inspection safe if a failed fixture leaves a writer running.
static STREAMS: [Stream; 3] = [const { Stream::new() }; 3];
static CHILD_PID: AtomicU64 = AtomicU64::new(0);
static PARENT_PID: AtomicU64 = AtomicU64::new(0);
static QUEUE: AtomicUsize = AtomicUsize::new(0);
static EXIT_DONE: AtomicBool = AtomicBool::new(false);

#[inline(always)]
pub fn stamp() -> u64 {
    let lo: u32;
    let hi: u32;
    // LFENCE orders execution on the admitted Intel CPUs without draining
    // stores. These are local execution intervals, not publication bounds.
    // Omitting nomem/readonly also keeps compiler memory operations inside.
    unsafe {
        core::arch::asm!(
            "lfence", "rdtsc", "lfence",
            out("eax") lo, out("edx") hi,
            options(nostack, preserves_flags),
        );
    }
    ((hi as u64) << 32) | lo as u64
}

pub fn actor() -> usize {
    if !crate::irq::InterruptLevel::current().is_task_context() { return 0; }
    let Some(task) = Task::current() else { return 0; };
    let ptr = task.as_ref() as *const Task as usize;
    STREAMS.iter().position(|s| s.task.load(Ordering::Relaxed) == ptr)
        .map_or(0, |i| i + 1)
}

pub fn actor_for_tid(tid: u64) -> usize {
    STREAMS[..2].iter().position(|s| s.tid.load(Ordering::Relaxed) == tid)
        .map_or(0, |i| i + 1)
}

fn local() -> Option<&'static Stream> {
    let a = actor();
    (a != 0).then(|| &STREAMS[a - 1])
}

pub fn child() -> bool { actor() == 3 }
pub fn child_pid() -> u64 { CHILD_PID.load(Ordering::Relaxed) }
pub fn parent_pid() -> u64 { PARENT_PID.load(Ordering::Relaxed) }
pub fn queue(ptr: usize) -> bool { ptr != 0 && ptr == QUEUE.load(Ordering::Relaxed) }
pub fn call() -> Call {
    let a = actor();
    if !(1..=2).contains(&a) || !STREAMS[a - 1].active.load(Ordering::Relaxed) {
        return NO_CALL;
    }
    [a as u64, STREAMS[a - 1].generation.load(Ordering::Relaxed)]
}
pub fn waiting() -> bool { call() != NO_CALL }

pub fn reset() {
    // The fixture invokes reset before fork or registration, after the prior
    // fixture has joined its worker and observed the notifier's completion.
    for s in &STREAMS {
        s.task.store(0, Ordering::Relaxed);
        s.tid.store(0, Ordering::Relaxed);
        s.count.store(0, Ordering::Relaxed);
        s.dropped.store(0, Ordering::Relaxed);
        s.generation.store(0, Ordering::Relaxed);
        s.active.store(false, Ordering::Relaxed);
        s.park.store(false, Ordering::Relaxed);
        s.dequeue_start.store(0, Ordering::Relaxed);
    }
    EXIT_DONE.store(false, Ordering::Relaxed);
    QUEUE.store(0, Ordering::Relaxed);
}

pub fn register(a: usize, tid: u64, pid: u64, parent: u64, queue: usize, delay: u64) -> bool {
    if !(1..=3).contains(&a) { return false; }
    let Some(task) = Task::current() else { return false; };
    let s = &STREAMS[a - 1];
    let ptr = task.as_ref() as *const Task as usize;
    if s.task.compare_exchange(0, ptr, Ordering::Relaxed, Ordering::Relaxed).is_err() {
        return false;
    }
    s.tid.store(tid, Ordering::Relaxed);
    s.output_delay.store(delay.min(100_000_000), Ordering::Relaxed);
    if a == 1 {
        CHILD_PID.store(pid, Ordering::Relaxed);
        PARENT_PID.store(parent, Ordering::Relaxed);
        QUEUE.store(queue, Ordering::Relaxed);
    }
    true
}

pub fn delay_output() {
    if !waiting() { return; }
    let delay = local().unwrap().output_delay.load(Ordering::Relaxed);
    let start = stamp();
    // Selection already returned its retained Arc and released the children
    // mutex. This bounded scheduling delay cannot hold a protocol lock.
    while stamp().wrapping_sub(start) < delay { core::hint::spin_loop(); }
}

pub fn emit(event: u64, start: u64, end: u64, key: Call, data: &[u64]) {
    let Some(s) = local() else { return; };
    let index = s.count.load(Ordering::Relaxed);
    if index >= CAPACITY || data.len() + 6 > WORDS {
        s.dropped.store(s.dropped.load(Ordering::Relaxed) + 1, Ordering::Relaxed);
        return;
    }
    let record = &s.records[index].words;
    for (i, value) in [event, start, end, key[0], key[1], data.len() as u64].iter().chain(data).enumerate() {
        record[i].store(*value, Ordering::Relaxed);
    }
    s.count.store(index + 1, Ordering::Release);
}

pub fn waiter_event(event: u64, start: u64, data: &[u64]) {
    let key = call();
    if key != NO_CALL { emit(event, start, stamp(), key, data); }
}

pub fn begin(start: u64, data: &[u64]) {
    let a = actor();
    if !(1..=2).contains(&a) { return; }
    let s = &STREAMS[a - 1];
    s.generation.store(s.generation.load(Ordering::Relaxed) + 1, Ordering::Relaxed);
    s.active.store(true, Ordering::Relaxed);
    s.created.store(false, Ordering::Relaxed);
    s.outcome.store(0, Ordering::Relaxed);
    waiter_event(1, start, data);
}

pub fn finish(ret: i64) {
    let start = stamp();
    waiter_event(29, start, &[ret as u64]);
    if let Some(s) = local() { s.active.store(false, Ordering::Relaxed); }
}

pub fn decision(event: u64, start: u64) {
    if !waiting() { return; }
    let s = local().unwrap();
    s.outcome.store(event, Ordering::Relaxed);
    waiter_event(event, start, &[s.created.load(Ordering::Relaxed) as u64]);
}
pub fn arm_pair() {
    if waiting() { local().unwrap().arm_pair.store(true, Ordering::Relaxed); }
}
pub fn pair(start: u64) -> Call {
    if !waiting() { return NO_CALL; }
    let s = local().unwrap();
    if !s.arm_pair.swap(false, Ordering::Relaxed) { return NO_CALL; }
    s.created.store(true, Ordering::Relaxed);
    waiter_event(14, start, &[]);
    call()
}
pub fn close(start: u64, key: Call) {
    if key == NO_CALL || key != call() { return; }
    emit(24, start, stamp(), key, &[local().unwrap().outcome.load(Ordering::Relaxed)]);
}
pub fn save_code(code: u64) {
    if waiting() { local().unwrap().read_code.store(code, Ordering::Relaxed); }
}
pub fn read_code() -> u64 { local().map_or(0, |s| s.read_code.load(Ordering::Relaxed)) }

pub fn signal_enqueued(start: u64) {
    if !child() { return; }
    local().unwrap().remaining.store(3, Ordering::Relaxed);
    emit(32, start, stamp(), NO_CALL, &[3]);
}
pub fn signal_get(start: u64, a: usize, key: Call) {
    if !child() || !(1..=2).contains(&a) { return; }
    let s = local().unwrap();
    let remaining = s.remaining.load(Ordering::Relaxed) & !(1 << (a - 1));
    s.remaining.store(remaining, Ordering::Relaxed);
    s.channel.store(1, Ordering::Relaxed);
    emit(if key == NO_CALL { 33 } else { 34 }, start, stamp(), key, &[a as u64, remaining]);
}
pub fn wake_finish(start: u64, key: Call, channel: u64) {
    if child() && key != NO_CALL { emit(38, start, stamp(), key, &[channel]); }
}
pub fn set_park(active: bool) {
    if let Some(s) = local() { s.park.store(active, Ordering::Relaxed); }
}
pub fn parking() -> bool { local().is_some_and(|s| s.park.load(Ordering::Relaxed)) }
pub fn dequeue_pending(start: u64) {
    if parking() { local().unwrap().dequeue_start.store(start, Ordering::Relaxed); }
}
pub fn park_released() {
    if !parking() { return; }
    let s = local().unwrap();
    let start = s.dequeue_start.swap(0, Ordering::Relaxed);
    if start != 0 { waiter_event(20, start, &[]); }
}
pub fn exit_done() {
    if child() { EXIT_DONE.store(true, Ordering::Release); }
}

pub fn dump() -> bool {
    if !EXIT_DONE.load(Ordering::Acquire) { return false; }
    for (a, s) in STREAMS.iter().enumerate() {
        if s.active.load(Ordering::Acquire) { return false; }
        let count = s.count.load(Ordering::Acquire);
        crate::early_println!("WR_STREAM {} {} {}", a + 1, count, s.dropped.load(Ordering::Relaxed));
        for r in &s.records[..count.min(CAPACITY)] {
            let len = r.words[5].load(Ordering::Relaxed) as usize + 6;
            let mut line = alloc::string::String::new();
            use core::fmt::Write;
            for w in &r.words[..len] { let _ = write!(line, " {}", w.load(Ordering::Relaxed)); }
            crate::early_println!("WR_RAW {}{}", a + 1, line);
        }
    }
    true
}
