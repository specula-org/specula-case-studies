// SPDX-License-Identifier: MPL-2.0

//! Per-task trace storage for the bounded local-flock fixture.
//!
//! Events are copied into preallocated slots. Only the owning task changes its
//! local projection. Published events are immutable and can be drained even
//! when a fixture task is blocked inside a destructor.

use alloc::{boxed::Box, string::String, vec::Vec};
use core::{cell::UnsafeCell, fmt::Write, sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering}};
use crate::task::Task;

pub const THREADS: usize = 4;
const CAPACITY: usize = 2048;
pub const LIMIT: usize = 16;

#[derive(Clone, Copy, Debug, Default)]
pub struct Item { pub owner: usize, pub mode: &'static str, pub q: usize }
#[derive(Clone, Copy, Debug, Default)]
pub struct Items { pub entries: [Item; LIMIT], pub len: usize }
#[derive(Clone, Copy, Debug, Default)]
pub struct Queue { pub entries: [usize; LIMIT], pub len: usize }
#[derive(Clone, Copy, Debug, Default)]
pub struct Frame { resume: &'static str, target: usize, scan: usize, dtor: usize }
#[derive(Clone, Copy, Debug)]
struct Local {
    pc: &'static str, kind: &'static str, fd: usize, request: usize,
    captured: usize, call_ref: bool, pending: usize, temp: usize,
    mode: &'static str, nb: bool, rid: usize, target: usize, scan: usize,
    remove: bool, replace: usize, drain_q: usize, drain_to: &'static str,
    popped: usize, dtor: usize, stack: [Frame; 4], depth: usize, result: &'static str,
}
impl Default for Local {
    fn default() -> Self { Self { pc: "idle", kind: "none", fd: 0, request: 0,
        captured: 0, call_ref: false, pending: 0, temp: 0, mode: "UN", nb: false,
        rid: 0, target: 0, scan: 1, remove: false, replace: 0, drain_q: 0,
        drain_to: "idle", popped: 0, dtor: 0, stack: [Frame::default(); 4],
        depth: 0, result: "NONE" } }
}

/// Scalar outcomes and protected copies supplied by the actual operation.
#[derive(Clone, Copy, Debug, Default)]
pub struct Packet {
    pub ofd: usize, pub strong: usize, pub life: &'static str,
    pub fd: usize, pub owner: usize, pub id: usize, pub tid: usize,
    pub flag: bool, pub closed: bool, pub items: Items, pub queue: Queue,
    pub blocker: Item, pub mode: &'static str,
}
#[derive(Clone, Copy)]
struct Event { name: &'static str, start: u64, end: u64, args: [usize; 3], local: Local, packet: Packet }
struct Data { local: Local, token: usize, allocations: usize, saved: Packet, saved_start: u64, scan_items: Items, guard_depth: usize, rq_start: u64, replacement: (usize, usize) }
struct Buffer {
    data: UnsafeCell<Data>, events: Box<[UnsafeCell<Option<Event>>]>,
    published: AtomicUsize, dropped: AtomicUsize, last: AtomicUsize,
}
// SAFETY: only the registered task accesses data. Each event has one writer,
// and readers access it only after its release-published immutable boundary.
unsafe impl Sync for Buffer {}
struct Slot { task: AtomicUsize, buffer: AtomicPtr<Buffer> }
static SLOTS: [Slot; THREADS] = [const { Slot { task: AtomicUsize::new(0), buffer: AtomicPtr::new(core::ptr::null_mut()) } }; THREADS];
struct Owner { address: AtomicUsize, id: AtomicUsize, active: AtomicBool }
static OWNERS: [Owner; THREADS * LIMIT] = [const { Owner { address: AtomicUsize::new(0), id: AtomicUsize::new(0), active: AtomicBool::new(false) } }; THREADS * LIMIT];
static FDS: [AtomicUsize; 64] = [const { AtomicUsize::new(0) }; 64];
static ENABLED: AtomicBool = AtomicBool::new(false);
static GATE_OFD: AtomicUsize = AtomicUsize::new(0);
static GATE_RELEASED: AtomicBool = AtomicBool::new(true);

pub fn stamp() -> u64 {
    // SAFETY: the harness is restricted to x86-64. LFENCE bounds both compiler
    // and CPU motion around the TSC observation. The guest's clock is recorded.
    unsafe { core::arch::x86_64::_mm_lfence(); let t = core::arch::x86_64::_rdtsc(); core::arch::x86_64::_mm_lfence(); t }
}
fn task_address() -> usize { Task::current().map_or(0, |t| (&*t as *const Task) as usize) }
pub fn task_id(address: usize) -> usize { SLOTS.iter().position(|s| s.task.load(Ordering::Acquire) == address && address != 0).map_or(0, |i| i + 1) }
fn current<R>(f: impl FnOnce(usize, &Buffer, &mut Data) -> R) -> Option<R> {
    if !ENABLED.load(Ordering::Relaxed) { return None; }
    let _irq = crate::irq::disable_local();
    let tid = task_id(task_address());
    if tid == 0 { return None; }
    let ptr = SLOTS[tid - 1].buffer.load(Ordering::Acquire);
    if ptr.is_null() { return None; }
    // SAFETY: registration publishes a permanently allocated buffer. Interrupts
    // cannot reenter this task's writer while its local projection is borrowed.
    Some(unsafe { f(tid, &*ptr, &mut *(*ptr).data.get()) })
}
pub fn register(tid: usize) -> bool {
    if !(1..=THREADS).contains(&tid) { return false; }
    let slot = &SLOTS[tid - 1];
    if !slot.buffer.load(Ordering::Acquire).is_null() { return false; }
    let buffer = Box::new(Buffer { data: UnsafeCell::new(Data { local: Local::default(), token: 0, allocations: 0, saved: Packet::default(), saved_start: 0, scan_items: Items::default(), guard_depth: 0, rq_start: 0, replacement: (0, 0) }),
        events: (0..CAPACITY).map(|_| UnsafeCell::new(None)).collect::<Vec<_>>().into_boxed_slice(),
        published: AtomicUsize::new(0), dropped: AtomicUsize::new(0), last: AtomicUsize::new(0) });
    slot.buffer.store(Box::into_raw(buffer), Ordering::Release);
    slot.task.store(task_address(), Ordering::Release);
    ENABLED.store(true, Ordering::Release);
    true
}
pub fn active() -> bool { current(|_, _, _| true).unwrap_or(false) }
pub fn at(pc: &str) -> bool { current(|_, _, d| d.local.pc == pc).unwrap_or(false) }
pub fn rid() -> usize { current(|_, _, d| d.local.rid).unwrap_or(0) }
pub fn popped() -> usize { current(|_, _, d| d.local.popped).unwrap_or(0) }
pub fn drain_q() -> usize { current(|_, _, d| d.local.drain_q).unwrap_or(0) }
pub fn ofd(address: usize) -> usize {
    OWNERS.iter().filter(|o| o.active.load(Ordering::Acquire) && o.address.load(Ordering::Acquire) == address && address != 0)
        .map(|o| o.id.load(Ordering::Acquire)).max().unwrap_or(0)
}
pub fn fd_owner(fd: usize) -> usize { FDS.get(fd).map_or(0, |v| v.load(Ordering::Acquire)) }
pub fn set_fd(fd: usize, owner: usize) { if let Some(v) = FDS.get(fd) { v.store(owner, Ordering::Release); } }
pub fn new_ofd(address: usize) -> usize { current(|tid, b, d| {
    if d.allocations == LIMIT { b.dropped.fetch_add(1, Ordering::Relaxed); return 0; }
    let slot = (tid - 1) * LIMIT + d.allocations;
    d.allocations += 1;
    let id = tid * 1000 + d.allocations;
    OWNERS[slot].id.store(id, Ordering::Relaxed);
    OWNERS[slot].address.store(address, Ordering::Release);
    OWNERS[slot].active.store(true, Ordering::Release);
    id
}).unwrap_or(0) }
pub fn new_token() -> usize { current(|tid, _, d| { d.token += 1; tid * 1000 + d.token }).unwrap_or(0) }
pub fn save_blocker(blocker: Item) { current(|_, _, d| d.saved.blocker = blocker); }
pub fn save_lookup_start(start: u64) { current(|_, _, d| d.saved_start = start); }
pub fn lookup_start() -> u64 { current(|_, _, d| d.saved_start).unwrap_or(0) }
pub fn save_reference(packet: Packet) { current(|_, _, d| d.saved = packet); }
pub fn saved() -> Packet { current(|_, _, d| d.saved).unwrap_or_default() }
pub fn save_replacement(index: usize, queue: usize) { current(|_, _, d| d.replacement = (index, queue)); }
pub fn take_replacement(queue: usize) -> Option<usize> {
    current(|_, _, d| {
        if d.local.pc != "tryCheck" || d.replacement.1 != queue || queue == 0 { return None; }
        let index = d.replacement.0; d.replacement = (0, 0); Some(index)
    }).flatten()
}
pub fn set_scan_items(items: Items) { current(|_, _, d| d.scan_items = items); }
pub fn gate(ofd: usize) { GATE_OFD.store(ofd, Ordering::Release); GATE_RELEASED.store(false, Ordering::Release); }
static WAIT_GATE_TID: AtomicUsize = AtomicUsize::new(0);
pub fn gate_wait(tid: usize) { WAIT_GATE_TID.store(tid, Ordering::Release); GATE_RELEASED.store(false, Ordering::Release); }
pub fn await_wait_gate() {
    let tid = current(|tid, _, _| tid).unwrap_or(0);
    if tid != 0 && WAIT_GATE_TID.load(Ordering::Acquire) == tid { while !GATE_RELEASED.load(Ordering::Acquire) { core::hint::spin_loop(); } }
}
pub fn release_gate() { GATE_RELEASED.store(true, Ordering::Release); }
pub fn await_gate(owner: usize) { if owner != 0 && GATE_OFD.load(Ordering::Acquire) == owner { while !GATE_RELEASED.load(Ordering::Acquire) { core::hint::spin_loop(); } } }

fn drain(l: &mut Local, q: usize, to: &'static str) { l.drain_q = q; l.drain_to = to; l.popped = 0; l.pc = "drain"; }
fn put(l: &mut Local, p: &mut Packet, to: &'static str) {
    if p.strong == 0 {
        p.life = "destroying";
        l.stack[l.depth] = Frame { resume: to, target: l.target, scan: l.scan, dtor: l.dtor };
        l.depth += 1; l.dtor = p.ofd; l.pc = "dropEnter";
    } else { p.life = "live"; l.pc = to; }
}
fn record(tid: usize, b: &Buffer, d: &mut Data, start: u64, end: u64, name: &'static str, a: [usize; 3], mut p: Packet) {
    let l = &mut d.local;
    match name {
        "SysOpen" => { *l = Local::default(); l.kind = "open"; l.pending = p.ofd; l.pc = "openInsert"; }
        "FileTableInsert" => { l.fd = a[0]; l.pc = "openPut"; l.result = "OK"; }
        "ArcPutOpen" => { l.pending = 0; put(l, &mut p, "openReturn"); }
        "SysOpenReturn" => l.pc = "idle",
        "SysDup" => { *l = Local::default(); l.kind = "dup"; l.fd = a[1]; l.result = "OK"; }
        "SysClose" => { *l = Local::default(); l.kind = "close"; l.fd = a[0]; l.pending = p.ofd; l.pc = "closeTable"; }
        "CloseFileTableUnlock" => l.pc = "closedDrop",
        "ClosedFileDrop" => { l.pending = 0; put(l, &mut p, "closeReturn"); }
        "SysCloseReturn" => { l.pc = "idle"; l.result = "OK"; }
        "SysFlock" => { *l = Local::default(); l.kind = "flock"; l.fd = a[0]; l.mode = p.mode; l.nb = p.flag; l.pc = "lookup"; }
        "GetFileFast" => { l.request = p.ofd; l.captured = p.ofd; l.call_ref = p.flag; l.pc = "dispatch"; }
        "GetFileFastBadFd" => { l.result = "EBADF"; l.pc = "flockReturn"; }
        "UnlockFlock" => { l.target = l.request; l.result = "OK"; l.pc = if p.flag { "unlockEnter" } else { "callPut" }; }
        "FlockItemNew" => { l.rid = a[0]; l.pc = "context"; }
        "FsLockContextOrInit" => l.pc = if l.nb { "tryEnter" } else { "waiterNew" },
        "WaiterNewPair" => l.pc = "tryEnter",
        "TrySetLockEnter" => l.pc = "tryWait",
        "TrySetLockAcquire" => { d.guard_depth += 1; l.pc = "tryCheck"; }
        "TrySetLockNonblockingConflict" => { l.result = "EAGAIN"; l.pc = "tryReturn"; }
        "TrySetLockRegister" => { l.result = "WAIT"; l.pc = "tryReturn"; }
        "TrySetLockReplace" => { l.replace = p.owner; drain(l, p.id, "tryInstall"); }
        "TrySetLockAppend" | "TrySetLockInstall" => { l.result = "OK"; l.pc = "tryReturn"; }
        "TrySetLockUnlock" => { d.guard_depth -= 1; l.pc = if l.result == "WAIT" { "doWait" } else if l.nb { "requestDrop" } else { "waiterClose" }; }
        "WakerDoWait" => l.pc = if p.flag { "tryEnter" } else { "parkCheck" },
        "SchedulerParkCheck" => l.pc = if p.flag { "parkAbort" } else { "parkCommit" },
        "SchedulerParkCommit" => l.pc = "parked",
        "SchedulerParkAbort" | "SchedulerResume" => l.pc = "doWait",
        "WaiterClose" => l.pc = "requestDrop",
        "FlockItemDropRequest" => drain(l, p.id, "callPut"),
        "WaitQueuePop" => { l.popped = p.owner; l.pc = "wake"; }
        "WakerWakeUp" => { if p.flag { l.pc = "unpark"; } else { l.pc = "drain"; l.popped = 0; } }
        "SchedulerUnpark" => { l.popped = 0; l.pc = "drain"; }
        "WaitQueueFinish" => { l.pc = l.drain_to; l.drain_q = 0; l.popped = 0; }
        "FlockListUnlockEnter" => { p.flag = d.guard_depth > 0; l.pc = "unlockWait"; }
        "FlockListUnlockAcquire" => { d.guard_depth += 1; l.scan = 1; l.pc = "scan"; }
        "FlockOwnerUpgrade" => { l.temp = p.ofd; l.pc = "compareOwner"; }
        "FlockOwnerExpired" => l.pc = "removeItem",
        "FlockOwnerMatch" => { l.remove = true; drain(l, p.id, "tempPut"); }
        "FlockOwnerKeep" => { l.remove = false; l.pc = "tempPut"; }
        "ArcPutTemporary" => { l.temp = 0; put(l, &mut p, "afterTemp"); }
        "FlockRetainContinue" => { if l.remove { l.pc = "removeItem"; } else { l.scan += 1; l.pc = "scan"; } }
        "FlockItemDropRemoved" => {
            let i = d.scan_items.entries[..d.scan_items.len].iter().position(|item| item.q == p.id).expect("removed fixture item");
            for j in i..d.scan_items.len - 1 { d.scan_items.entries[j] = d.scan_items.entries[j + 1]; }
            d.scan_items.len -= 1; p.items = d.scan_items; drain(l, p.id, "scan");
        }
        "FlockListUnlockRelease" => { d.guard_depth -= 1; l.pc = if l.dtor == 0 { "callPut" } else { "dropFinish" }; }
        "ArcPutSyscall" => { let owned = l.call_ref; l.call_ref = false; if owned { put(l, &mut p, "flockReturn"); } else { l.pc = "flockReturn"; } }
        "InodeHandleDropEnter" => { l.target = l.dtor; l.pc = if p.flag { "unlockEnter" } else { "dropFinish" }; }
        "InodeHandleDropFinish" => { l.depth -= 1; let frame = l.stack[l.depth]; l.pc = frame.resume; l.target = frame.target; l.scan = frame.scan; l.dtor = frame.dtor; }
        "SysFlockReturn" => l.pc = "idle",
        _ => panic!("unknown flock trace event"),
    }
    let i = b.published.load(Ordering::Relaxed);
    if i == CAPACITY { b.dropped.fetch_add(1, Ordering::Relaxed); return; }
    let event = Event { name, start, end, args: a, local: *l, packet: p };
    // SAFETY: this is the sole producer and this slot is not yet published.
    unsafe { *b.events[i].get() = Some(event); }
    b.published.store(i + 1, Ordering::Release);
    let boundary = match name { "TrySetLockRegister" => 1, "FlockOwnerUpgrade" => 2, "FlockListUnlockEnter" if p.flag => 3, "SysFlockReturn" => 4, "SchedulerParkCommit" => 5, "WakerDoWait" if !p.flag => 6, "FileTableInsert" => 7, _ => 0 };
    if boundary != 0 { b.last.store(((i + 1) << 8) | boundary, Ordering::Release); }
    let _ = tid;
}
pub fn emit(start: u64, name: &'static str, args: [usize; 3], packet: Packet) {
    let end = stamp();
    current(|tid, b, d| record(tid, b, d, start, end, name, args, packet));
}
pub fn simple(name: &'static str) { let start = stamp(); emit(start, name, [0; 3], Packet::default()); }
pub fn arm_rq_release(start: u64) { current(|_, _, d| d.rq_start = start); }
pub fn after_rq_unlock() {
    let start = current(|_, _, d| d.rq_start).unwrap_or(0);
    if at("parkCommit") { let q = rid(); emit(start, "SchedulerParkCommit", [0; 3], Packet { id: q, ..Packet::default() }); }
    else if at("parkAbort") { let q = rid(); emit(start, "SchedulerParkAbort", [0; 3], Packet { id: q, flag: true, ..Packet::default() }); }
}

/// Captures a stable scalar token while the primitive still owns its input.
#[unsafe(no_mangle)]
pub extern "C" fn __specula_arc_identity(address: usize) -> usize {
    if ENABLED.load(Ordering::Relaxed) { ofd(address) } else { 0 }
}

/// Receives the values returned by the production Arc/Weak atomic primitives.
#[unsafe(no_mangle)]
pub extern "C" fn __specula_arc_observe(operation: usize, owner: usize, count: usize, start: u64) {
    if !ENABLED.load(Ordering::Relaxed) { return; }
    if owner == 0 { return; }
    let end = stamp();
    current(|tid, b, d| {
        let p = Packet { ofd: owner, strong: count, life: if operation == 4 { "dead" } else { "live" }, ..Packet::default() };
        let name = match operation {
            1 => { d.saved.ofd = owner; d.saved.strong = count; d.saved.life = "live"; d.saved_start = start; return; }
            2 => match d.local.pc {
                "openPut" if d.local.pending == owner => "ArcPutOpen",
                "closedDrop" if d.local.pending == owner => "ClosedFileDrop",
                "tempPut" if d.local.temp == owner => "ArcPutTemporary",
                "callPut" if d.local.request == owner && d.local.call_ref => "ArcPutSyscall",
                _ => { b.dropped.fetch_add(1, Ordering::Relaxed); return; }
            },
            3 if d.local.pc == "scan" => if count == 0 { "FlockOwnerExpired" } else { "FlockOwnerUpgrade" },
            4 if d.local.pc == "dropFinish" && d.local.dtor == owner => "InodeHandleDropFinish",
            _ => { b.dropped.fetch_add(1, Ordering::Relaxed); return; }
        };
        record(tid, b, d, start, end, name, [0; 3], p);
        if operation == 4 {
            for owner in &OWNERS {
                if owner.id.load(Ordering::Acquire) == p.ofd { owner.active.store(false, Ordering::Release); }
            }
        }
    });
}

pub fn info(tid: usize, what: usize) -> usize {
    if !(1..=THREADS).contains(&tid) { return 0; }
    let ptr = SLOTS[tid - 1].buffer.load(Ordering::Acquire);
    if ptr.is_null() { return 0; }
    // SAFETY: buffers are permanently allocated and these fields are atomic.
    let b = unsafe { &*ptr };
    match what { 0 => b.published.load(Ordering::Acquire), 1 => b.dropped.load(Ordering::Acquire), _ => b.last.load(Ordering::Acquire) }
}
fn item(out: &mut String, value: Item) { write!(out, "{{\"owner\":{},\"mode\":\"{}\",\"q\":{}}}", value.owner, value.mode, value.q).unwrap(); }
fn items(out: &mut String, values: Items) { out.push('['); for (i, value) in values.entries[..values.len].iter().enumerate() { if i > 0 { out.push(','); } item(out, *value); } out.push(']'); }
fn queue(out: &mut String, p: Packet) { write!(out, ",\"queue\":{{\"id\":{},\"entries\":[", p.id).unwrap(); for (i, q) in p.queue.entries[..p.queue.len].iter().enumerate() { if i > 0 { out.push(','); } write!(out, "{}", q).unwrap(); } out.push_str("]}"); }
fn waker(out: &mut String, p: Packet, notified: bool) { write!(out, ",\"waker\":{{\"id\":{},\"tid\":{},\"notified\":{},\"closed\":{}}}", p.id, p.tid, notified, p.closed).unwrap(); }
fn reference(out: &mut String, p: Packet, expired: bool) { write!(out, ",\"ref\":{{\"ofd\":{},\"strong\":{}", p.ofd, p.strong).unwrap(); if !expired { write!(out, ",\"life\":\"{}\"", p.life).unwrap(); } out.push('}'); }

pub fn read_event(tid: usize, index: usize) -> Option<String> {
    if !(1..=THREADS).contains(&tid) { return None; }
    let ptr = SLOTS[tid - 1].buffer.load(Ordering::Acquire);
    if ptr.is_null() { return None; }
    // SAFETY: the release-published slot is immutable for the life of the VM.
    let b = unsafe { &*ptr };
    if index >= b.published.load(Ordering::Acquire) { return None; }
    let e = unsafe { (*b.events[index].get())? };
    let p = e.packet; let l = e.local; let mut out = String::new();
    write!(out, "{{\"tag\":\"trace\",\"event\":\"{}\",\"tid\":{},\"inode\":\"fixture-inode\",\"start\":{},\"end\":{},\"args\":{{", e.name, tid, e.start, e.end).unwrap();
    match e.name {
        "SysOpen" => write!(out, "\"ofd\":{}", p.ofd).unwrap(),
        "FileTableInsert" | "SysClose" => write!(out, "\"fd\":{}", e.args[0]).unwrap(),
        "SysDup" => write!(out, "\"fd\":{},\"newfd\":{}", e.args[0], e.args[1]).unwrap(),
        "SysFlock" => write!(out, "\"fd\":{},\"mode\":\"{}\",\"nb\":{}", e.args[0], p.mode, p.flag).unwrap(),
        "FlockItemNew" => write!(out, "\"q\":{}", e.args[0]).unwrap(), _ => (),
    }
    write!(out, "}},\"state\":{{\"thread\":{{\"pc\":\"{}\",\"kind\":\"{}\",\"fd\":{},\"request\":{},\"captured\":{},\"callRef\":{},\"pending\":{},\"temp\":{},\"mode\":\"{}\",\"nb\":{},\"rid\":{},\"target\":{},\"scan\":{},\"remove\":{},\"replace\":{},\"drainQ\":{},\"drainTo\":\"{}\",\"popped\":{},\"dtor\":{},\"result\":\"{}\",\"stack\":[", l.pc,l.kind,l.fd,l.request,l.captured,l.call_ref,l.pending,l.temp,l.mode,l.nb,l.rid,l.target,l.scan,l.remove,l.replace,l.drain_q,l.drain_to,l.popped,l.dtor,l.result).unwrap();
    for (i, frame) in l.stack[..l.depth].iter().enumerate() { if i > 0 { out.push(','); } write!(out, "{{\"resume\":\"{}\",\"target\":{},\"scan\":{},\"dtor\":{}}}", frame.resume,frame.target,frame.scan,frame.dtor).unwrap(); } out.push_str("]}");
    match e.name {
        "SysOpen" | "ArcPutOpen" | "ClosedFileDrop" | "GetFileFast" | "FlockOwnerUpgrade" | "ArcPutTemporary" | "ArcPutSyscall" | "InodeHandleDropFinish" => reference(&mut out,p,false),
        "FlockOwnerExpired" => reference(&mut out,p,true),
        "FileTableInsert" | "SysDup" => { reference(&mut out,p,false); write!(out, ",\"fd\":{{\"fd\":{},\"owner\":{}}}",l.fd,p.ofd).unwrap(); }
        "SysClose" => write!(out, ",\"fd\":{{\"fd\":{},\"owner\":0}},\"tableOwner\":{}",l.fd,tid).unwrap(),
        "CloseFileTableUnlock" => out.push_str(",\"tableOwner\":0"),
        "FlockItemNew" => write!(out, ",\"token\":{},\"fresh\":true",l.rid).unwrap(),
        "FsLockContextOrInit" => out.push_str(",\"context\":true"),
        "TrySetLockAcquire" | "FlockListUnlockAcquire" => write!(out, ",\"listOwner\":{}",tid).unwrap(),
        "TrySetLockUnlock" | "FlockListUnlockRelease" => out.push_str(",\"listOwner\":0"),
        "TrySetLockNonblockingConflict" | "TrySetLockRegister" => { out.push_str(",\"blocker\":"); item(&mut out,p.blocker); if e.name == "TrySetLockRegister" { queue(&mut out,p); } }
        "TrySetLockAppend" | "TrySetLockInstall" | "FlockItemDropRemoved" => { out.push_str(",\"items\":"); items(&mut out,p.items); }
        "WaiterNewPair" => waker(&mut out,p,false),
        "WaiterClose" => waker(&mut out,p,true),
        "WakerDoWait" => { waker(&mut out,p,false); write!(out, ",\"consumed\":{}",p.flag).unwrap(); }
        "WakerWakeUp" => { waker(&mut out,p,true); write!(out, ",\"accepted\":{}",p.flag).unwrap(); }
        "WaitQueuePop" => queue(&mut out,p),
        "SchedulerParkCheck" | "SchedulerParkCommit" | "SchedulerParkAbort" | "SchedulerUnpark" => { write!(out, ",\"rq\":{{\"id\":{},\"owner\":{},\"runnable\":{}}}",p.id,if e.name == "SchedulerParkCheck" { tid } else { 0 },e.name != "SchedulerParkCommit").unwrap(); if e.name == "SchedulerParkCheck" { write!(out, ",\"sawNotification\":{}",p.flag).unwrap(); } }
        "FlockListUnlockEnter" => write!(out, ",\"selfHeld\":{}",p.flag).unwrap(), _ => (),
    }
    out.push_str("}}"); Some(out)
}

pub fn identities() -> String {
    let mut out = String::from("{\"threads\":[");
    for (i, slot) in SLOTS.iter().enumerate() {
        if i != 0 { out.push(','); }
        write!(&mut out, "{{\"id\":{},\"task_address\":{}}}",i+1,slot.task.load(Ordering::Acquire)).unwrap();
    }
    out.push_str("],\"ofds\":[");
    let mut first = true;
    for owner in &OWNERS {
        let id = owner.id.load(Ordering::Acquire);
        if id == 0 { continue; }
        if !first { out.push(','); } first = false;
        write!(&mut out, "{{\"id\":{},\"payload_address\":{}}}",id,owner.address.load(Ordering::Acquire)).unwrap();
    }
    out.push_str("],\"fd_normalization\":\"numeric FD minus two\",\"token_identity\":\"task slot times 1000 plus per-task request allocation number\"}"); out
}

static OPEN_WINDOW: AtomicBool = AtomicBool::new(false);
static OPEN_STAGE: AtomicUsize = AtomicUsize::new(0);
static OPEN_RELEASE_GUARD: AtomicBool = AtomicBool::new(false);
static OPEN_RELEASE_ORIGINAL: AtomicBool = AtomicBool::new(false);

/// Starts the fixture that observes open entry while another insertion holds the table.
pub fn start_open_window() { OPEN_WINDOW.store(true, Ordering::Release); }
pub fn open_stage() -> usize { OPEN_STAGE.load(Ordering::Acquire) }
pub fn release_open_guard() { OPEN_RELEASE_GUARD.store(true, Ordering::Release); }
pub fn release_open_original() { OPEN_RELEASE_ORIGINAL.store(true, Ordering::Release); }
pub fn open_table_attempt() {
    if OPEN_WINDOW.load(Ordering::Acquire) && task_id(task_address()) == 3 {
        OPEN_STAGE.store(2, Ordering::Release);
        // The controller shares this CPU. Wait before the measured insertion
        // and before taking its preemption-disabling table guard.
        while !OPEN_RELEASE_GUARD.load(Ordering::Acquire) { Task::yield_now(); }
    }
}
pub fn open_guard_window() {
    if OPEN_WINDOW.load(Ordering::Acquire) && task_id(task_address()) == 2 {
        OPEN_STAGE.store(1, Ordering::Release);
        while !OPEN_RELEASE_GUARD.load(Ordering::Acquire) { core::hint::spin_loop(); }
    }
}
pub fn pause_open_original() {
    if OPEN_WINDOW.load(Ordering::Acquire) {
        while !OPEN_RELEASE_ORIGINAL.load(Ordering::Acquire) { Task::yield_now(); }
    }
}
