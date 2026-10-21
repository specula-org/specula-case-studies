// SPDX-License-Identifier: MPL-2.0

//! Per-task receipts. User space arms and drains the buffer outside the attempt.

use ostd::{mm::{Infallible, VmIo}, task::Task};
use crate::prelude::*;

const LIMIT: usize = 2048;
#[derive(Clone, Copy)]
struct Receipt {
    name: &'static str,
    start: u64,
    end: u64,
    values: [usize; 8],
    data: [u8; 16],
}

pub(crate) struct Recorder {
    tid: usize,
    start: u64,
    blocks: usize,
    vmo: usize,
    zeros: usize,
    writer: bool,
    unit: usize,
    fault: usize,
    armed: bool,
    active: bool,
    overflow: bool,
    records: Vec<Receipt>,
}

impl Recorder {
    pub(crate) fn new() -> Self {
        Self { tid: 0, start: 0, blocks: 0, vmo: 0, zeros: 0, writer: false, unit: 2048, fault: 0, armed: false, active: false,
               overflow: false, records: Vec::new() }
    }
}

fn with<R>(f: impl FnOnce(&mut Recorder) -> R) -> Option<R> {
    let task = Task::current()?;
    let local = task.as_thread_local()?;
    let mut recorder = local.specula_trace.try_borrow_mut().ok()?;
    Some(f(&mut recorder))
}

pub(crate) fn active() -> bool { with(|r| r.active).unwrap_or(false) }
pub(crate) fn stamp() -> u64 {
    core::sync::atomic::fence(core::sync::atomic::Ordering::SeqCst);
    let time = ostd::arch::read_tsc();
    core::sync::atomic::fence(core::sync::atomic::Ordering::SeqCst);
    time
}

fn push(name: &'static str, start: u64, end: u64, values: [usize; 8], data: [u8; 16]) {
    with(|r| {
        if !r.active { return; }
        if r.records.len() == r.records.capacity() { r.overflow = true; return; }
        match name {
            "ExfatWriteAtPrepare" | "ExfatResizeUpgrade" | "ExfatWriteAtPublish" => r.writer = true,
            "ExfatWriteAtReleasePreparation" | "BackendReturn" => r.writer = false,
            _ => {}
        }
        r.records.push(Receipt { name, start, end, values, data });
    });
}

pub(crate) fn event(name: &'static str, start: u64, values: [usize; 8]) {
    let end = stamp();
    push(name, start, end, values, [255; 16]);
}

pub(crate) fn enter(start: u64, kind: usize, offset: usize, length: usize, target: usize) {
    let fault = with(|r| { r.active = r.armed; r.vmo = 0; r.fault.min(length) }).unwrap_or(0);
    event("SyscallEnter", start, [kind, offset, length, target, fault, 0, 0, 0]);
}

pub(crate) fn returned(name: &'static str, start: u64, result: &Result<usize>, position: usize) {
    let start = if name == "BackendReturn" { last_end() } else { start };
    let (count, errno) = match result {
        Ok(n) => (*n, 0),
        Err(e) => (usize::MAX, e.error() as usize),
    };
    event(name, start, [count, errno, position, 0, 0, 0, 0, 0]);
    if name == "InodeHandleReturn" { with(|r| r.active = false); }
}

// A tag is emitted only when every byte in its exact unit has that value.
fn tags(bytes: &[u8], unit: usize, out: &mut [u8; 16]) {
    if unit == 0 || bytes.len() % unit != 0 || bytes.len() / unit > out.len() {
        out[0] = 254; return;
    }
    for (i, cell) in bytes.chunks_exact(unit).enumerate() {
        out[i] = if cell.iter().all(|v| *v == cell[0]) { cell[0] } else { 254 };
    }
}

pub(crate) fn page(name: &'static str, start: u64, index: usize, state: usize,
                   mut reader: VmReader<Infallible>) {
    let end = stamp();
    if !active() { return; }
    let mut data = [255; 16];
    if state != 0 {
        let mut bytes = [0u8; 4096];
        reader.read(&mut VmWriter::from(&mut bytes[..]));
        tags(&bytes, with(|r| r.unit).unwrap(), &mut data);
    }
    push(name, start, end, [index, state, 0, 0, 0, 0, 0, 0], data);
}

pub(crate) fn copied(start: u64, index: usize, page_offset: usize, before: usize,
    after: usize, failed: bool, state: usize, reader: VmReader<Infallible>, destination: bool) {
    let end = stamp();
    if !active() { return; }
    let delta = after - before;
    let unit = with(|r| r.unit).unwrap();
    let mut data = [255; 16];
    if destination {
        let mut bytes = [0u8; 4096];
        if delta > bytes.len() { data[0] = 254; }
        else {
            let result = crate::context::current_userspace!().read_bytes(before, &mut bytes[..delta]);
            if result.is_err() { data[0] = 254; }
            else { tags(&bytes[..delta], unit, &mut data); }
        }
    } else {
        let mut bytes = [0u8; 4096];
        let mut reader = reader;
        if state != 0 {
            reader.read(&mut VmWriter::from(&mut bytes[..]));
            tags(&bytes, unit, &mut data);
        } else if delta > 0 {
            reader.skip(page_offset).read(&mut VmWriter::from(&mut bytes[..delta]));
            let mut prefix = [255; 16];
            tags(&bytes[..delta], unit, &mut prefix);
            if page_offset % unit != 0 { data[0] = 254; }
            else { for i in 0..delta / unit { data[page_offset / unit + i] = prefix[i]; } }
        }
    }
    push("VmoCopyPage", start, end,
         [index, page_offset, before, after, delta, usize::from(failed), state, usize::from(destination)], data);
}

pub(crate) fn control(option: i32, tid: usize, unit: usize, fault: usize) -> Result<usize> {
    if option == 0x53504543 {
        if tid > 2 || unit != 2048 { return_errno!(Errno::EINVAL); }
        with(|r| { *r = Recorder { tid, start: 0, blocks: 0, vmo: 0, zeros: 0, writer: false, unit, fault, armed: true, active: false,
            overflow: false, records: Vec::with_capacity(LIMIT) }; });
        return Ok(0);
    }
    let saved = with(|r| { r.active = false; r.armed = false;
        (r.tid, r.overflow, core::mem::take(&mut r.records)) }).unwrap();
    for e in &saved.2 {
        ostd::early_println!("SPECULA_RAW {{\"event\":\"{}\",\"tid\":{},\"start\":{},\"end\":{},\"v\":{:?},\"data\":{:?}}}",
            e.name, saved.0, e.start, e.end, e.values, e.data);
    }
    if saved.1 { return_errno!(Errno::EOVERFLOW); }
    Ok(saved.2.len())
}

pub(crate) fn last_end() -> u64 { with(|r| r.records.last().map(|e| e.end).unwrap_or_else(stamp)).unwrap_or_else(stamp) }
pub(crate) fn set_start(value: u64) { with(|r| r.start = value); }
pub(crate) fn take_start() -> u64 { with(|r| r.start).unwrap_or_else(stamp) }
pub(crate) fn blocks() -> usize { with(|r| r.blocks).unwrap_or(0) }
pub(crate) fn set_blocks(value: usize) { with(|r| r.blocks = value); }


pub(crate) fn bind_vmo(address: usize) { with(|r| if r.active { r.vmo = address; }); }
pub(crate) struct Scope(bool);
pub(crate) fn scope(address: usize) -> Scope {
    Scope(with(|r| { let old = r.active; r.active &= r.vmo == address; old }).unwrap_or(false))
}
impl Drop for Scope { fn drop(&mut self) { with(|r| r.active = self.0); } }

pub(crate) fn reset_zeros() { with(|r| r.zeros = 0); }
pub(crate) fn zero_receipt(bytes: usize) { with(|r| if r.active { r.zeros += bytes; }); }
pub(crate) fn zeros() -> usize { with(|r| r.zeros).unwrap_or(0) }
pub(crate) fn holds_writer() -> bool { with(|r| r.active && r.writer).unwrap_or(false) }
