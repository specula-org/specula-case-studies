// SPDX-License-Identifier: MPL-2.0
//! Bounded, allocation-free observation buffers for the private futex campaign.

use core::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

use crate::{cpu::CpuId, task::Task};

pub const STREAMS: usize = 12;
pub const CAPACITY: usize = 4096;
const WORDS: usize = 32;
static ENABLED: AtomicBool = AtomicBool::new(false);
static NEXT: [AtomicUsize; STREAMS] = [const { AtomicUsize::new(0) }; STREAMS];
static LOST: [AtomicUsize; STREAMS] = [const { AtomicUsize::new(0) }; STREAMS];
static ACTIVE: [AtomicU64; STREAMS] = [const { AtomicU64::new(0) }; STREAMS];
static CALLS: [AtomicU64; STREAMS] = [const { AtomicU64::new(0) }; STREAMS];
static RECORDS: [[[AtomicU64; WORDS]; CAPACITY]; STREAMS] =
    [const { [const { [const { AtomicU64::new(0) }; WORDS] }; CAPACITY] }; STREAMS];

pub fn stamp() -> u64 {
    // SAFETY: The campaign runs on x86-64. Fences and TSC reads do not access memory.
    unsafe {
        core::arch::x86_64::_mm_lfence();
        core::arch::x86_64::_rdtsc()
    }
}
pub fn cpu() -> usize {
    u32::from(CpuId::current_racy()) as usize
}
pub fn stream() -> usize {
    if crate::irq::InterruptLevel::current().is_interrupt_context() {
        8 + cpu()
    } else {
        Task::current().map_or(0, |t| t.specula_stream.load(Ordering::Relaxed))
    }
}
pub fn register(s: usize) {
    assert!(s > 0 && s < 8);
    Task::current()
        .unwrap()
        .specula_stream
        .store(s, Ordering::Relaxed);
}
pub fn active() -> u64 {
    ACTIVE[stream().min(STREAMS - 1)].load(Ordering::Relaxed)
}
pub fn set_active(g: u64) {
    ACTIVE[stream()].store(g, Ordering::Relaxed);
}
pub fn next_id() -> u64 {
    let s = stream();
    if s == 0 || !ENABLED.load(Ordering::Acquire) {
        return 0;
    }
    let id = (s as u64) * 1000 + CALLS[s].fetch_add(1, Ordering::Relaxed) + 1;
    set_active(id);
    id
}
pub fn enabled() -> bool {
    ENABLED.load(Ordering::Acquire)
}
pub fn begin() {
    ENABLED.store(false, Ordering::Release);
    for s in 0..STREAMS {
        for record in &RECORDS[s] {
            record[0].store(0, Ordering::Relaxed);
        }
        NEXT[s].store(0, Ordering::Relaxed);
        LOST[s].store(0, Ordering::Relaxed);
        ACTIVE[s].store(0, Ordering::Relaxed);
        CALLS[s].store(0, Ordering::Relaxed);
    }
    ENABLED.store(true, Ordering::Release);
}
/// Records bounded numeric evidence. Each stream has its own reservation counter.
pub fn emit(event: &str, start: u64, data: &[u64], queue: &[u64]) -> usize {
    let end = stamp();
    let s = stream();
    if !enabled() || s == 0 || s >= STREAMS {
        return 0;
    }
    let i = NEXT[s].fetch_add(1, Ordering::Relaxed);
    if i >= CAPACITY || data.len() > 10 || queue.len() > 16 {
        LOST[s].fetch_add(1, Ordering::Relaxed);
        return 0;
    }
    let r = &RECORDS[s][i];
    let code = event_code(event);
    r[1].store(start, Ordering::Relaxed);
    r[2].store(end, Ordering::Relaxed);
    r[3].store(cpu() as u64, Ordering::Relaxed);
    r[4].store(active(), Ordering::Relaxed);
    r[5].store(data.len() as u64, Ordering::Relaxed);
    for (j, v) in data.iter().enumerate() {
        r[6 + j].store(*v, Ordering::Relaxed);
    }
    for j in 0..16 {
        r[16 + j].store(*queue.get(j).unwrap_or(&0), Ordering::Relaxed);
    }
    r[0].store(code, Ordering::Release);
    i + 1
}
pub fn dump() {
    ENABLED.store(false, Ordering::Release);
    for s in 1..STREAMS {
        let n = NEXT[s].load(Ordering::Acquire);
        let unfinished = RECORDS[s][..n.min(CAPACITY)]
            .iter()
            .filter(|r| r[0].load(Ordering::Acquire) == 0)
            .count();
        crate::early_println!(
            "SPECULA_BUFFER {} {} {}",
            s,
            n,
            LOST[s].load(Ordering::Acquire) + unfinished
        );
        for i in 0..n.min(CAPACITY) {
            let r = &RECORDS[s][i];
            crate::early_print!("SPECULA_RAW {} {}", s, i + 1);
            for word in r {
                crate::early_print!(" {}", word.load(Ordering::Acquire));
            }
            crate::early_println!("");
        }
    }
    for s in 1..STREAMS {
        crate::early_println!(
            "SPECULA_FINAL_COUNT {} {}",
            s,
            NEXT[s].load(Ordering::Acquire)
        );
    }
}

fn event_code(name: &str) -> u64 {
    match name {
        "SysFutexWait" => 1,
        "FutexWaitLock" => 2,
        "FutexWaitLoad" => 3,
        "FutexWaitFault" => 4,
        "FutexWaitFaultUnlock" => 5,
        "HandlePageFault" => 6,
        "FutexWaitCompare" => 7,
        "FutexWaitMismatchUnlock" => 8,
        "FutexBucketAddItem" => 9,
        "FutexWaitUnlock" => 10,
        "PauseTimeoutCheck" => 11,
        "TimerSetTimeout" => 12,
        "WakerDoWait" => 13,
        "WaiterPark" => 14,
        "PauseTimeoutTimerLock" => 15,
        "PauseTimeoutNoTimer" => 16,
        "PauseTimeoutRemain" => 17,
        "TimerCancel" => 18,
        "PauseTimeoutTimerUnlock" => 19,
        "PauseTimeoutTimerDrop" => 20,
        "TimerCollect" => 21,
        "TimerCallbackUpgrade" => 22,
        "TimerCallbackLock" => 23,
        "TimerCallbackCheck" => 24,
        "TimerCallbackWake" => 25,
        "TimerCallbackUnpark" => 26,
        "TimerCallbackFinish" => 27,
        "FutexCleanupLock" => 28,
        "FutexRemoveByWaker" => 29,
        "FutexCleanupUnlock" => 30,
        "FutexWaitDecide" => 31,
        "WaiterDrop" => 32,
        "SysFutexWaitReturn" => 33,
        "SysFutexControl" => 34,
        "LockBucketPairsFirst" => 35,
        "LockBucketPairsSecond" => 36,
        "FutexWakeStart" => 37,
        "FutexItemWake" => 38,
        "FutexWakeUnpark" => 39,
        "FutexWakeRetain" => 40,
        "FutexWakeEnd" => 41,
        "FutexUpdateItemKey" => 42,
        "FutexExtractItem" => 43,
        "FutexExtractedKey" => 44,
        "FutexAppendExtracted" => 45,
        "FutexMoveEnd" => 46,
        "FutexRequeueFinish" => 47,
        "FutexReleaseDest" => 48,
        "FutexReleaseSource" => 49,
        "SysFutexControlReturn" => 50,
        "UserStore" => 51,
        "TimerSetClock" => 52,
        "PauseTimeoutClock" => 53,
        "WaiterSpuriousReturn" => 54,
        "TimerCollectClock" => 55,
        "TimerCollectEnd" => 56,
        "ClockAdvance" => 57,
        "KeyIdentity" => 58,
        "ParkReturn" => 59,
        "QueueView" => 60,
        "ControlInput" => 61,
        "WaitInput" => 62,
        "TimerContext" => 63,
        "UserWord" => 64,
        "Attempt" => 65,
        "HeapView" => 66,
        "HarnessJoin" => 67,
        "HarnessEnrolled" => 68,
        _ => 0,
    }
}
