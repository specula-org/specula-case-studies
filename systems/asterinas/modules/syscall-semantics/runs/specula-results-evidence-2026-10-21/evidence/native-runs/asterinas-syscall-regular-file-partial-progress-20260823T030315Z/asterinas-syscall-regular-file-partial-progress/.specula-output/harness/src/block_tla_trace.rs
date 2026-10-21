// SPDX-License-Identifier: MPL-2.0

//! Allocation-free completion-side tracing for the Specula regular-file harness.

use core::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, fence};

use ostd::{prelude::println, util::id_set::Id};

use crate::prelude::*;

const MAX_CPUS: usize = 8;
const MAX_EVENTS: usize = 64;
const EVENT_FIELDS: usize = 8;

pub const SUBMITTED_BIO_COMPLETE_EVENT: u8 = 35;

#[derive(Clone, Copy, Debug)]
pub struct TraceIdentity {
    pub owner: u8,
    pub attempt: u64,
    pub effect: u64,
    pub vector_entry: u64,
    pub segment: u64,
    pub range_start_bytes: u64,
}

#[derive(Clone, Copy)]
pub struct CompletionSpan {
    cpu: usize,
    identity: TraceIdentity,
    start: u64,
}

struct TraceSlot {
    kind: AtomicU8,
    start: AtomicU64,
    end: AtomicU64,
    order: AtomicU64,
    fields: [AtomicU64; EVENT_FIELDS],
}

impl TraceSlot {
    const fn new() -> Self {
        Self {
            kind: AtomicU8::new(0),
            start: AtomicU64::new(0),
            end: AtomicU64::new(0),
            order: AtomicU64::new(0),
            fields: [const { AtomicU64::new(0) }; EVENT_FIELDS],
        }
    }

    fn write(&self, kind: u8, start: u64, end: u64, order: u64, fields: [u64; EVENT_FIELDS]) {
        self.kind.store(0, Ordering::Relaxed);
        self.start.store(start, Ordering::Relaxed);
        self.end.store(end, Ordering::Relaxed);
        self.order.store(order, Ordering::Relaxed);
        for (target, value) in self.fields.iter().zip(fields) {
            target.store(value, Ordering::Relaxed);
        }
        self.kind.store(kind, Ordering::Release);
    }

    fn field(&self, index: usize) -> u64 {
        self.fields[index].load(Ordering::Relaxed)
    }
}

struct TraceBuffer {
    next: AtomicUsize,
    overflow: AtomicBool,
    slots: [TraceSlot; MAX_EVENTS],
}

impl TraceBuffer {
    const fn new() -> Self {
        Self {
            next: AtomicUsize::new(0),
            overflow: AtomicBool::new(false),
            slots: [const { TraceSlot::new() }; MAX_EVENTS],
        }
    }

    fn reset(&self) {
        self.next.store(0, Ordering::Relaxed);
        self.overflow.store(false, Ordering::Relaxed);
    }

    fn push(&self, kind: u8, start: u64, end: u64, order: u64, fields: [u64; EVENT_FIELDS]) {
        // Completion callbacks on one CPU are serialized by the device path.
        let index = self.next.fetch_add(1, Ordering::Relaxed);
        if index >= MAX_EVENTS {
            self.overflow.store(true, Ordering::Release);
            return;
        }
        self.slots[index].write(kind, start, end, order, fields);
    }
}

static BUFFERS: [TraceBuffer; MAX_CPUS] = [const { TraceBuffer::new() }; MAX_CPUS];
static ENABLED: AtomicBool = AtomicBool::new(false);
static BAD_CPU: AtomicBool = AtomicBool::new(false);
static SHADOW_ORDER: AtomicU64 = AtomicU64::new(0);
static DATA_EPOCH: AtomicU64 = AtomicU64::new(0);

fn timestamp() -> u64 {
    fence(Ordering::SeqCst);
    let value = ostd::arch::read_tsc();
    fence(Ordering::SeqCst);
    value
}

pub fn reset() {
    ENABLED.store(false, Ordering::Release);
    BAD_CPU.store(false, Ordering::Relaxed);
    SHADOW_ORDER.store(0, Ordering::Relaxed);
    DATA_EPOCH.store(0, Ordering::Relaxed);
    for buffer in &BUFFERS {
        buffer.reset();
    }
}

pub fn set_enabled(enabled: bool) {
    ENABLED.store(enabled, Ordering::Release);
}

pub fn next_shadow_order() -> u64 {
    SHADOW_ORDER.fetch_add(1, Ordering::Relaxed) + 1
}

pub fn sample_data_epoch() -> u64 {
    DATA_EPOCH.load(Ordering::Acquire)
}

pub fn publish_data_effect() -> u64 {
    DATA_EPOCH.fetch_add(1, Ordering::AcqRel) + 1
}

pub fn begin_completion(identity: Option<TraceIdentity>) -> Option<CompletionSpan> {
    let identity = identity?;
    if !ENABLED.load(Ordering::Acquire) {
        return None;
    }
    let cpu = ostd::cpu::CpuId::current_racy().as_usize();
    if cpu >= MAX_CPUS {
        BAD_CPU.store(true, Ordering::Release);
        return None;
    }
    Some(CompletionSpan {
        cpu,
        identity,
        start: timestamp(),
    })
}

pub fn finish_completion(span: Option<CompletionSpan>) {
    let Some(span) = span else {
        return;
    };
    if !ENABLED.load(Ordering::Acquire) {
        return;
    }

    let epoch = publish_data_effect();
    let order = next_shadow_order();
    let end = timestamp();
    let identity = span.identity;
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = identity.owner.into();
    fields[1] = identity.attempt;
    fields[2] = identity.effect;
    fields[3] = identity.vector_entry;
    fields[4] = identity.segment;
    fields[5] = identity.range_start_bytes;
    fields[6] = epoch;
    BUFFERS[span.cpu].push(SUBMITTED_BIO_COMPLETE_EVENT, span.start, end, order, fields);
}

pub fn flush() {
    if BAD_CPU.load(Ordering::Acquire) {
        println!("SPECULA_TRACE_ERROR completion-cpu-out-of-range");
    }
    for (cpu, buffer) in BUFFERS.iter().enumerate() {
        if buffer.overflow.load(Ordering::Acquire) {
            println!("SPECULA_TRACE_ERROR completion-buffer-overflow-{}", cpu);
        }
        let count = buffer.next.load(Ordering::Acquire).min(MAX_EVENTS);
        for slot in buffer.slots.iter().take(count) {
            println!(
                "SPECULA_RAW {{\"tag\":\"raw\",\"kind\":{},\"tid\":\"bio-cpu-{}\",\"start\":{},\"end\":{},\"shadow_order\":{},\"attempt\":{},\"effect\":{},\"raw\":[{},{},{},{},{},{},{},{}]}}",
                slot.kind.load(Ordering::Acquire),
                cpu,
                slot.start.load(Ordering::Relaxed),
                slot.end.load(Ordering::Relaxed),
                slot.order.load(Ordering::Relaxed),
                slot.field(1),
                slot.field(2),
                slot.field(0),
                slot.field(1),
                slot.field(2),
                slot.field(3),
                slot.field(4),
                slot.field(5),
                slot.field(6),
                slot.field(7),
            );
        }
    }
}
