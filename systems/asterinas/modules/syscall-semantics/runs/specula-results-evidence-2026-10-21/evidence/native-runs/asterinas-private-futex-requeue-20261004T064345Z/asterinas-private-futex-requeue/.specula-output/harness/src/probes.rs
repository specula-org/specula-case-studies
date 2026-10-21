// SPDX-License-Identifier: MPL-2.0
//! Observation-only campaign control. All measured operations use normal futex dispatch.
use core::sync::atomic::{AtomicU64, Ordering};

use ostd::specula_trace as tr;

use crate::prelude::*;

pub static KEYS: [AtomicU64; 3] = [const { AtomicU64::new(0) }; 3];
pub static VMAR: AtomicU64 = AtomicU64::new(0);
static ENQUEUED: [AtomicU64; 8] = [const { AtomicU64::new(0) }; 8];
pub fn key(addr: usize) -> u64 {
    KEYS.iter()
        .position(|v| v.load(Ordering::Relaxed) == addr as u64)
        .map_or(0, |i| i as u64 + 1)
}
pub fn enrolled(g: u64) {
    ENQUEUED[(g / 1000) as usize].store(g, Ordering::Release);
}
pub fn count_enrolled() -> usize {
    ENQUEUED
        .iter()
        .filter(|v| v.load(Ordering::Acquire) > 0)
        .count()
}
pub fn reset() {
    for v in &ENQUEUED {
        v.store(0, Ordering::Relaxed);
    }
    tr::begin();
}
pub fn generation() -> u64 {
    if tr::stream() < 8 { tr::active() } else { 0 }
}
pub fn mark(event: &str, start: u64, data: &[u64], q: &[u64]) {
    if tr::active() != 0 {
        tr::emit(event, start, data, q);
    }
}
pub fn result_code(result: &Result<usize>) -> u64 {
    match result {
        Ok(n) => *n as u64,
        Err(e) => match e.error() {
            Errno::EAGAIN => 10001,
            Errno::ETIME | Errno::ETIMEDOUT => 10002,
            Errno::EINTR | Errno::ERESTARTSYS => 10003,
            _ => 19999,
        },
    }
}

pub const BUILD_ID: &str = "HARNESS_BUILD_ID";

pub fn enrollment_snapshot() -> [u64; 8] {
    core::array::from_fn(|i| ENQUEUED[i].load(Ordering::Acquire))
}
