// SPDX-License-Identifier: MPL-2.0

//! Per-task capture for the bounded memfd trace experiment.

use alloc::format;
use core::{
    fmt::Write,
    sync::atomic::{Ordering, fence},
};

use ostd::task::Task;

use crate::{fs::ramfs::memfd::MemfdInodeHandle, prelude::*, vm::perms::VmPerms};

pub(crate) const BASE: usize = 0x4000_0000;
pub(crate) const PAGES: usize = 3;
pub(crate) const CONTROL: i32 = 0x5350_4543;
const CAPACITY: usize = 2048;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Request {
    pub kind: &'static str,
    pub lo: usize,
    pub hi: usize,
    pub off: usize,
    pub fd: &'static str,
    pub shared: bool,
    pub perms: u32,
    pub fixed: bool,
    pub seals: u32,
}

impl Default for Request {
    fn default() -> Self {
        Self {
            kind: "get",
            lo: 0,
            hi: 1,
            off: 0,
            fd: "rw",
            shared: true,
            perms: 0,
            fixed: false,
            seals: 0,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Owner {
    pub id: u64,
    pub role: &'static str,
    pub lo: usize,
    pub hi: usize,
    pub off: usize,
    pub file: usize,
    pub vmo: usize,
    pub shared: bool,
    pub perms: u32,
    pub may: u32,
    pub tracked: bool,
    pub generations: [u64; PAGES],
}

impl Owner {
    pub(crate) const EMPTY: Self = Self {
        id: 0,
        role: "free",
        lo: 0,
        hi: 0,
        off: 0,
        file: 0,
        vmo: 0,
        shared: true,
        perms: 0,
        may: 0,
        tracked: false,
        generations: [0; PAGES],
    };
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Local {
    pub pc: &'static str,
    pub serial: usize,
    pub request: Request,
    pub result: &'static str,
    pub may: u32,
    pub tracked: bool,
    pub checked: bool,
    pub observed: u32,
    pub queue: [Owner; 6],
    pub index: usize,
    pub last_end: usize,
    pub cur: u64,
    pub tmp: u64,
    pub part_lo: usize,
    pub part_hi: usize,
    pub cut: usize,
    pub side: &'static str,
    pub rest: [u64; 2],
    pub done: u8,
    pub touched: u8,
    pub merge_side: &'static str,
    pub neighbor: u64,
    pub anchor: usize,
    pub generation: u64,
    pub deny_count: isize,
}

impl Default for Local {
    fn default() -> Self {
        Self {
            pc: "idle",
            serial: 0,
            request: Request::default(),
            result: "pending",
            may: 7,
            tracked: false,
            checked: false,
            observed: 0,
            queue: [Owner::EMPTY; 6],
            index: 1,
            last_end: 0,
            cur: 0,
            tmp: 0,
            part_lo: 0,
            part_hi: 0,
            cut: 0,
            side: "left",
            rest: [0; 2],
            done: 0,
            touched: 0,
            merge_side: "prev",
            neighbor: 0,
            anchor: 0,
            generation: 0,
            deny_count: 0,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Rmw {
    pub start: u64,
    pub end: u64,
    pub new: isize,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Event {
    pub cpu: u32,
    pub name: &'static str,
    pub start: u64,
    pub end: u64,
    pub local: Local,
    pub owners: [Owner; 6],
    pub tree: [Owner; 6],
    pub counter: Option<isize>,
    pub seals: Option<u32>,
    pub range: Option<(usize, usize)>,
    // Each PTE receipt contains an address, raw generation, and R/W/X mask.
    pub ptes: [(usize, u64, u32); PAGES],
    pub pte_count: usize,
    pub return_value: isize,
}

pub(crate) struct Buffer {
    enabled: bool,
    in_call: bool,
    thread: usize,
    fds: [u64; 3],
    files: [usize; 3],
    pub local: Local,
    events: Vec<Event>,
    dropped: usize,
    tokens: u64,
    pub rmw: Option<Rmw>,
    owner_box: Option<(u64, u64)>,
    pub drop_event: &'static str,
    pub fault_change: Option<(usize, u64, u32)>,
    selections: Vec<[usize; 4]>,
}

impl Default for Buffer {
    fn default() -> Self {
        Self {
            enabled: false,
            in_call: false,
            thread: 0,
            fds: [0; 3],
            files: [0; 3],
            local: Local::default(),
            events: Vec::new(),
            dropped: 0,
            tokens: 0,
            rmw: None,
            owner_box: None,
            drop_event: "",
            fault_change: None,
            selections: Vec::new(),
        }
    }
}

pub(crate) fn now() -> u64 {
    fence(Ordering::SeqCst);
    let value = ostd::arch::read_tsc();
    fence(Ordering::SeqCst);
    value
}

fn access<R>(f: impl FnOnce(&mut Buffer) -> R) -> Option<R> {
    let task = Task::current()?;
    let local = task.as_thread_local()?;
    Some(f(&mut local.tla_trace.borrow_mut()))
}

pub(crate) fn active() -> bool {
    access(|b| b.enabled && b.in_call).unwrap_or(false)
}

pub(crate) fn change(f: impl FnOnce(&mut Buffer)) {
    access(|b| {
        if b.enabled && b.in_call {
            f(b);
        }
    });
}

pub(crate) fn local() -> Local {
    access(|b| b.local).unwrap_or_default()
}

pub(crate) fn token() -> u64 {
    access(|b| {
        if !b.enabled || !b.in_call {
            return 0;
        }
        b.tokens += 1;
        ((b.thread as u64) << 32) | b.tokens
    })
    .unwrap_or(0)
}

pub(crate) fn page(addr: usize) -> usize {
    addr.saturating_sub(BASE) / PAGE_SIZE
}

pub(crate) fn span(lo: usize, hi: usize) -> u8 {
    assert!(lo <= hi && hi <= PAGES, "trace range outside abstraction");
    (lo..hi).fold(0, |bits, p| bits | (1 << p))
}

pub(crate) fn result<T>(r: &Result<T>) -> &'static str {
    match r {
        Ok(_) => "OK",
        Err(e) => match e.error() {
            Errno::EPERM => "EPERM",
            Errno::EACCES => "EACCES",
            Errno::EBUSY => "EBUSY",
            Errno::ENOMEM => "ENOMEM",
            _ => "UNSUPPORTED_ERROR",
        },
    }
}

pub(crate) fn emit(
    name: &'static str,
    pc: &'static str,
    start: u64,
    end: u64,
    f: impl FnOnce(&mut Buffer, &mut Event),
) {
    change(|b| {
        b.local.pc = pc;
        let mut e = Event {
            cpu: ostd::cpu::CpuId::current_racy().into(),
            name,
            start,
            end,
            local: b.local,
            owners: [Owner::EMPTY; 6],
            tree: [Owner::EMPTY; 6],
            counter: None,
            seals: None,
            range: None,
            ptes: [(0, 0, 0); PAGES],
            pte_count: 0,
            return_value: 0,
        };
        f(b, &mut e);
        e.local = b.local;
        if b.events.len() == CAPACITY {
            b.dropped += 1;
        } else {
            b.events.push(e);
        }
    });
}

pub(crate) fn simple(name: &'static str, pc: &'static str, start: u64) {
    emit(name, pc, start, now(), |_, _| {});
}

pub(crate) fn save_rmw(start: u64, end: u64, old: isize, new: isize) {
    let _ = old;
    change(|b| b.rmw = Some(Rmw { start, end, new }));
}

pub(crate) fn selected(addr: usize, len: usize) {
    change(|b| {
        assert!(
            b.selections.len() < 64,
            "trace selection capacity exhausted"
        );
        b.selections.push([
            b.local.serial,
            BASE + b.local.request.lo * PAGE_SIZE,
            addr,
            len,
        ]);
    });
}

pub(crate) fn save_owner_box(start: u64, end: u64) {
    change(|b| b.owner_box = Some((start, end)));
}

pub(crate) fn owner_event(
    name: &'static str,
    pc: &'static str,
    start: u64,
    end: u64,
    owner: Owner,
    f: impl FnOnce(&mut Local),
) {
    let rmw = access(|b| b.rmw.take()).flatten().filter(|_| owner.tracked);
    let (start, end) = access(|b| b.owner_box.take())
        .flatten()
        .unwrap_or((start, end));
    emit(
        name,
        pc,
        rmw.map_or(start, |r| r.start),
        rmw.map_or(end, |r| r.end),
        |b, e| {
            f(&mut b.local);
            e.owners[0] = owner;
            e.counter = rmw.map(|r| r.new);
        },
    );
}

pub(crate) fn set_drop(name: &'static str) {
    change(|b| b.drop_event = name);
}

pub(crate) fn dropped(id: u64, tracked: bool, start: u64, end: u64) {
    if id == 0 || !active() {
        return;
    }
    let c = local();
    let name = access(|b| b.drop_event).unwrap();
    let pc = match name {
        "MappedVmoDropUnmapped" => "remove_next",
        "MappedVmoDropMergeSelf" => "merge_drop_neighbor",
        "MappedVmoDropMergeNeighbor" => {
            if c.merge_side == "prev" {
                "merge_check"
            } else {
                "insert"
            }
        }
        _ => panic!("unclassified trace owner destruction"),
    };
    let rmw = access(|b| b.rmw.take()).flatten().filter(|_| tracked);
    emit(
        name,
        pc,
        rmw.map_or(start, |r| r.start),
        rmw.map_or(end, |r| r.end),
        |b, e| {
            e.counter = rmw.map(|r| r.new);
            e.owners[0] = Owner { id, ..Owner::EMPTY };
            match name {
                "MappedVmoDropUnmapped" => {
                    b.local.cur = 0;
                    b.local.index += 1;
                }
                "MappedVmoDropMergeSelf" => {
                    b.local.cur = b.local.tmp;
                    b.local.tmp = 0;
                }
                _ => {
                    b.local.neighbor = 0;
                    b.local.merge_side = "next";
                }
            }
        },
    );
}

pub(crate) fn amend_tree(tree: [Owner; 6]) {
    change(|b| {
        if let Some(e) = b.events.last_mut() {
            e.tree = tree;
        }
    });
}

pub(crate) fn enter(number: u64, a: [u64; 6]) {
    let start = now();
    access(|b| {
        if !b.enabled || b.in_call {
            return;
        }
        let mut request = Request::default();
        let pc;
        match number {
            9 if b.fds.contains(&a[4])
                && a[0] >= BASE as u64
                && a[0] < (BASE + PAGES * PAGE_SIZE) as u64 =>
            {
                request = Request {
                    kind: "map",
                    lo: page(a[0] as _),
                    hi: page((a[0] + a[1]) as _),
                    off: a[5] as usize / PAGE_SIZE,
                    fd: ["rw", "rw2", "ro"][b.fds.iter().position(|x| *x == a[4]).unwrap()],
                    shared: a[3] & 0xf == 1,
                    perms: a[2] as u32,
                    fixed: a[3] & 0x10 != 0,
                    seals: 0,
                };
                pc = "fd";
            }
            10 | 11 if a[0] >= BASE as u64 && a[0] < (BASE + PAGES * PAGE_SIZE) as u64 => {
                request.kind = if number == 10 { "protect" } else { "unmap" };
                request.lo = page(a[0] as _);
                request.hi = page((a[0] + a[1]) as _);
                request.perms = if number == 10 { a[2] as _ } else { 0 };
                pc = "vmar_lock";
            }
            72 if b.fds.contains(&a[0]) && (a[1] == 1033 || a[1] == 1034) => {
                request.kind = if a[1] == 1033 { "add" } else { "get" };
                request.seals = if a[1] == 1033 { a[2] as _ } else { 0 };
                pc = if a[1] == 1033 {
                    "seal_lock"
                } else {
                    "get_seals"
                };
            }
            _ => return,
        }
        b.local = Local {
            serial: b.local.serial + 1,
            request,
            pc,
            ..Local::default()
        };
        b.in_call = true;
    });
    if active() {
        simple("SyscallEnter", local().pc, start);
    }
}

pub(crate) fn syscall_return(value: isize) {
    if !active() {
        return;
    }
    let start = now();
    emit("SyscallReturn", "idle", start, now(), |_, e| {
        e.return_value = value
    });
    access(|b| b.in_call = false);
}

pub(crate) fn fd_mode(perms: VmPerms, denied: bool, start: u64) {
    emit(
        "MmapFdMode",
        if denied { "return" } else { "vmar_lock" },
        start,
        now(),
        |b, _| {
            b.local.may = (perms.bits() >> 3) & 7;
            if denied {
                b.local.result = "EACCES";
            }
        },
    );
}

pub(crate) fn vmar_lock(tree: [Owner; 6], start: u64, end: u64) {
    let r = local().request;
    let pc = if r.kind == "protect" {
        "protect_check"
    } else if r.kind == "unmap" || r.fixed {
        "remove_next"
    } else {
        "check_writable"
    };
    emit("VmarLock", pc, start, end, |b, e| {
        e.tree = tree;
        let mut i = 0;
        for o in tree
            .iter()
            .filter(|o| o.id != 0 && o.lo < r.hi && r.lo < o.hi)
        {
            b.local.queue[i] = *o;
            i += 1;
        }
        b.local.last_end = r.lo;
    });
}

pub(crate) fn vmar_unlock<T>(tree: [Owner; 6], start: u64, end: u64, r: &Result<T>) {
    emit("VmarUnlock", "return", start, end, |b, e| {
        b.local.result = result(r);
        e.tree = tree;
    });
}

pub(crate) fn detached(
    name: &'static str,
    tree: [Owner; 6],
    owner: Option<Owner>,
    lo: usize,
    hi: usize,
    start: u64,
    end: u64,
) {
    let pc = if owner.is_some() {
        "split_left"
    } else {
        "protect_check"
    };
    emit(name, pc, start, end, |b, e| {
        e.tree = tree;
        if let Some(owner) = owner {
            e.owners[0] = owner;
            b.local.cur = owner.id;
            b.local.part_lo = lo;
            b.local.part_hi = hi;
            b.local.rest = [0; 2];
        } else {
            b.local.done |= span(lo, hi);
            b.local.index += 1;
        }
    });
}

pub(crate) fn split_decision(side: &'static str, cut: usize, needed: bool, start: u64) {
    emit(
        "VmMappingSplitRange",
        if needed {
            "split_dup"
        } else if side == "left" {
            "split_right"
        } else {
            "put_rest"
        },
        start,
        now(),
        |b, _| {
            b.local.side = side;
            b.local.cut = cut;
        },
    );
}

pub(crate) fn split_done(left: Owner, right: Owner, start: u64, end: u64) {
    let side = local().side;
    emit(
        "VmMappingSplit",
        if side == "left" {
            "split_right"
        } else {
            "put_rest"
        },
        start,
        end,
        |b, e| {
            e.owners[0] = left;
            e.owners[1] = right;
            b.local.tmp = 0;
            let survivor = if side == "left" { left.id } else { right.id };
            let slot = if b.local.rest[0] == 0 { 0 } else { 1 };
            b.local.rest[slot] = survivor;
            b.local.cur = if side == "left" { right.id } else { left.id };
        },
    );
}

pub(crate) fn insert_rest(tree: [Owner; 6], owner: Option<Owner>, start: u64, end: u64) {
    let pc = if owner.is_some() {
        "put_rest"
    } else if local().request.kind == "protect" {
        "protect_pt"
    } else {
        "unmap_pt"
    };
    emit("VmarInsertRest", pc, start, end, |b, e| {
        e.tree = tree;
        if let Some(owner) = owner {
            e.owners[0] = owner;
            b.local.rest = [b.local.rest[1], 0];
        } else {
            b.local.touched = 0;
        }
    });
}

pub(crate) fn merge_check(neighbor: u64, compatible: bool, start: u64, end: u64) {
    let side = local().merge_side;
    let pc = if compatible {
        "merge_dup"
    } else if side == "prev" {
        "merge_check"
    } else {
        "insert"
    };
    emit("VmarTryMerge", pc, start, end, |b, _| {
        b.local.neighbor = neighbor;
        if !compatible {
            b.local.merge_side = "next";
        }
    });
}

pub(crate) fn inserted(tree: [Owner; 6], owner: Owner, start: u64, end: u64) {
    let is_map = local().request.kind == "map";
    emit(
        "VmarInsertMapping",
        if is_map {
            "vmar_unlock"
        } else {
            "protect_check"
        },
        start,
        end,
        |b, e| {
            e.tree = tree;
            e.owners[0] = owner;
            b.local.cur = 0;
            b.local.index += 1;
            b.local.result = if is_map { "OK" } else { "pending" };
        },
    );
}

pub(crate) fn cursor(
    name: &'static str,
    range: Option<(usize, usize)>,
    changed: Option<(usize, u64, u32)>,
    start: u64,
    end: u64,
) {
    let pc = if range.is_none() {
        "dispatch"
    } else if name == "CursorProtect" {
        "protect_pt"
    } else {
        "unmap_pt"
    };
    emit(name, pc, start, end, |b, e| {
        e.range = range;
        if let Some((lo, hi)) = range {
            b.local.touched |= span(lo, hi);
        }
        if let Some(pte) = changed {
            e.ptes[0] = pte;
            e.pte_count = 1;
        }
    });
}

pub(crate) fn fault_pte(addr: usize, generation: u64, flags: ostd::mm::PageFlags) {
    change(|b| {
        // The fault receipt is completed by the enclosing read-locked handler.
        if b.local.request.kind == "fault" {
            b.fault_change = Some((page(addr), generation, VmPerms::from(flags).bits()));
        }
    });
}

fn request_json(r: Request) -> String {
    format!(
        "{{\"kind\":\"{}\",\"lo\":{},\"hi\":{},\"off\":{},\"fd\":\"{}\",\"shared\":{},\"perms\":{},\"fixed\":{},\"seals\":{}}}",
        r.kind, r.lo, r.hi, r.off, r.fd, r.shared, r.perms, r.fixed, r.seals
    )
}

fn owners_json(owners: &[Owner]) -> String {
    let mut s = String::from("[");
    for o in owners.iter().filter(|o| o.id != 0) {
        if s.len() > 1 {
            s.push(',');
        }
        write!(s,"{{\"id\":{},\"role\":\"{}\",\"lo\":{},\"hi\":{},\"off\":{},\"file\":{},\"vmo\":{},\"shared\":{},\"perms\":{},\"may\":{},\"tracked\":{},\"generations\":{:?}}}",
            o.id,o.role,o.lo,o.hi,o.off,o.file,o.vmo,o.shared,o.perms,o.may,o.tracked,o.generations).unwrap();
    }
    s.push(']');
    s
}

fn local_json(c: Local) -> String {
    format!(
        "{{\"pc\":\"{}\",\"serial\":{},\"request\":{},\"result\":\"{}\",\"may\":{},\"tracked\":{},\"checked\":{},\"observed\":{},\"queue\":{},\"index\":{},\"last_end\":{},\"cur\":{},\"tmp\":{},\"part_lo\":{},\"part_hi\":{},\"cut\":{},\"side\":\"{}\",\"rest\":{:?},\"done\":{},\"touched\":{},\"merge_side\":\"{}\",\"neighbor\":{},\"anchor\":{},\"generation\":{},\"deny_count\":{}}}",
        c.pc,
        c.serial,
        request_json(c.request),
        c.result,
        c.may,
        c.tracked,
        c.checked,
        c.observed,
        owners_json(&c.queue),
        c.index,
        c.last_end,
        c.cur,
        c.tmp,
        c.part_lo,
        c.part_hi,
        c.cut,
        c.side,
        c.rest,
        c.done,
        c.touched,
        c.merge_side,
        c.neighbor,
        c.anchor,
        c.generation,
        c.deny_count
    )
}

pub(crate) fn control(thread: usize, fds: [u64; 3], ctx: &Context) -> Result<()> {
    if thread == 3 {
        let start = now();
        access(|b| {
            assert!(b.enabled && !b.in_call);
            b.in_call = true;
            b.fault_change = None;
            b.local = Local {
                serial: b.local.serial + 1,
                pc: "fault",
                request: Request {
                    kind: "fault",
                    lo: page(fds[0] as _),
                    hi: page(fds[0] as _) + 1,
                    perms: 3,
                    ..Request::default()
                },
                ..Local::default()
            };
        });
        simple("SyscallEnter", "fault", start);
        let r = ctx
            .user_space()
            .vmar()
            .handle_page_fault(&crate::vm::vmar::PageFaultInfo::new(
                fds[0] as _,
                VmPerms::READ | VmPerms::WRITE,
            ));
        syscall_return(r.as_ref().map_or_else(|e| -(e.error() as isize), |_| 0));
        return r;
    }
    if thread == 0 {
        let buffer = access(|b| core::mem::take(b)).unwrap();
        ostd::early_println!(
            "SPECULA_META {{\"thread\":{},\"events\":{},\"dropped\":{},\"files\":{:?},\"selections\":{:?}}}",
            buffer.thread,
            buffer.events.len(),
            buffer.dropped,
            buffer.files,
            buffer.selections
        );
        for e in buffer.events {
            let counter = e.counter.map_or(String::from("null"), |x| format!("{x}"));
            let seals = e.seals.map_or(String::from("null"), |x| format!("{x}"));
            let range = e
                .range
                .map_or(String::from("[]"), |(l, h)| format!("[{l},{h}]"));
            let ptes: Vec<_> = e.ptes[..e.pte_count]
                .iter()
                .map(|(a, g, p)| [*a as u64, *g, *p as u64])
                .collect();
            ostd::early_println!(
                "SPECULA_RAW {{\"tag\":\"trace\",\"cpu\":{},\"thread\":\"t{}\",\"event\":\"{}\",\"start\":{},\"end\":{},\"local\":{},\"owners\":{},\"tree\":{},\"counter\":{},\"seals\":{},\"range\":{},\"ptes\":{:?},\"return_value\":{}}}",
                e.cpu,
                buffer.thread,
                e.name,
                e.start,
                e.end,
                local_json(e.local),
                owners_json(&e.owners),
                owners_json(&e.tree),
                counter,
                seals,
                range,
                ptes,
                e.return_value
            );
        }
        return Ok(());
    }
    assert!(thread <= 2);
    let mut files = [0; 3];
    let mut inode_ids = [0; 3];
    let mut vmos = [0; 3];
    let mut modes = [0u32; 3];
    let mut seals = [0u32; 3];
    let mut counters = [0isize; 3];
    let table = ctx.thread_local.borrow_file_table();
    let table = table.unwrap().read();
    let handles = [
        table.get_file((fds[0] as i32).try_into()?)?.clone(),
        table.get_file((fds[1] as i32).try_into()?)?.clone(),
        table.get_file((fds[2] as i32).try_into()?)?.clone(),
    ];
    drop(table);
    for i in 0..3 {
        let file = &handles[i];
        files[i] = Arc::as_ptr(file) as *const () as usize;
        let inode = file.path().inode();
        inode_ids[i] = Arc::as_ptr(inode) as *const () as usize;
        vmos[i] = Arc::as_ptr(&inode.page_cache().unwrap()) as usize;
        modes[i] = file.access_mode() as u32;
        seals[i] = file.as_inode_handle_or_err()?.get_seals()?.bits();
        counters[i] = inode
            .page_cache()
            .unwrap()
            .writable_mapping_status()
            .trace_value();
    }
    ostd::early_println!(
        "SPECULA_ID {{\"thread\":{},\"fds\":{:?},\"files\":{:?},\"inodes\":{:?},\"vmos\":{:?},\"modes\":{:?},\"seals\":{:?},\"counters\":{:?},\"tsc_hz\":{},\"num_cpus\":{},\"cpu\":{}}}",
        thread,
        fds,
        files,
        inode_ids,
        vmos,
        modes,
        seals,
        counters,
        ostd::arch::tsc_freq(),
        ostd::cpu::num_cpus(),
        u32::from(ostd::cpu::CpuId::current_racy())
    );
    access(|b| {
        *b = Buffer {
            enabled: true,
            thread,
            fds,
            files,
            events: Vec::with_capacity(CAPACITY),
            selections: Vec::with_capacity(64),
            ..Buffer::default()
        }
    });
    Ok(())
}
