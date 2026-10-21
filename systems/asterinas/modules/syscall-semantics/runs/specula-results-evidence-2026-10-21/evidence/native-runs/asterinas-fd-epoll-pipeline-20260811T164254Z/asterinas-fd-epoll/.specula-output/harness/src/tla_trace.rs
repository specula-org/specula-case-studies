// SPDX-License-Identifier: MPL-2.0

//! Test-only, allocation-free timebox tracing for the Specula FD/epoll harness.

use core::sync::atomic::{
    AtomicBool, AtomicU8, AtomicU32, AtomicU64, AtomicUsize, Ordering, fence,
};

use crate::{
    fs::file::{
        FileLike,
        file_table::{FdFlags, FileDesc},
    },
    prelude::*,
    process::posix_thread::AsPosixThread,
    thread::AsThread,
};

const ACTORS: usize = 2;
const FDS: usize = 3;
const OFDS: usize = 3;
const EPOLLS: usize = 2;
const MAX_EVENTS: usize = 64;
const EVENT_FIELDS: usize = 24;

const T1: u8 = 0;
const T2: u8 = 1;
const NO_ACTOR: u8 = 2;

const FD0: u8 = 0;
const FD1: u8 = 1;
const FD2: u8 = 2;
const NO_FD: u8 = 3;

const TIMER_OFD: u8 = 0;
const SIGNAL_OFD: u8 = 1;
const EVENT_OFD: u8 = 2;
const NO_OFD: u8 = 3;

const EP0: u8 = 0;
const EP1: u8 = 1;
const NO_EPOLL: u8 = 2;

const CMD_ADD: u8 = 1;

const TRIGGER_LT: u8 = 0;
const TRIGGER_ET: u8 = 1;
const TRIGGER_ONESHOT: u8 = 2;

const CTL_NONE: u8 = 0;
const CTL_OFD: u8 = 1;
const CTL_NESTED: u8 = 2;

const EV_FCNTL_SETFL_CAPTURE: u8 = 1;
const EV_FCNTL_SETFL_USE: u8 = 2;
const EV_DUP2_EQUAL: u8 = 3;
const EV_DUP3_VALIDATE: u8 = 4;
const EV_DUP_EXACT: u8 = 5;
const EV_DUP_CLEANUP: u8 = 6;
const EV_FCNTL_SETFD: u8 = 7;
const EV_CLOSE_REMOVE: u8 = 8;
const EV_CLOSED_DROP: u8 = 9;
const EV_DUP_CEIL: u8 = 10;
const EV_CLOSE_RANGE_CLOEXEC: u8 = 11;
const EV_EVENTFD_ADD: u8 = 12;
const EV_EVENTFD_READ: u8 = 13;
const EV_EVENTFD_NOTIFY: u8 = 14;
const EV_EVENTFD_NOTIFY_RETURN: u8 = 15;
const EV_SIGNALFD_MASK: u8 = 16;
const EV_EPOLL_CAPTURE: u8 = 17;
const EV_ENTRY_UPDATE: u8 = 18;
const EV_EPOLL_ADD: u8 = 19;
const EV_EPOLL_PUSH: u8 = 20;
const EV_EPOLL_NESTED: u8 = 21;

pub(crate) const EPOLL_COMMAND_ADD: u8 = CMD_ADD;
pub(crate) const EPOLL_TRIGGER_LT: u8 = TRIGGER_LT;
pub(crate) const EPOLL_TRIGGER_ET: u8 = TRIGGER_ET;
pub(crate) const EPOLL_TRIGGER_ONESHOT: u8 = TRIGGER_ONESHOT;

#[derive(Clone, Copy)]
pub(crate) struct Span {
    actor: u8,
    start: u64,
}

struct TraceSlot {
    kind: AtomicU8,
    start: AtomicU64,
    end: AtomicU64,
    fields: [AtomicU64; EVENT_FIELDS],
}

impl TraceSlot {
    const fn new() -> Self {
        Self {
            kind: AtomicU8::new(0),
            start: AtomicU64::new(0),
            end: AtomicU64::new(0),
            fields: [const { AtomicU64::new(0) }; EVENT_FIELDS],
        }
    }

    fn write(&self, kind: u8, start: u64, end: u64, fields: [u64; EVENT_FIELDS]) {
        self.kind.store(0, Ordering::Relaxed);
        self.start.store(start, Ordering::Relaxed);
        self.end.store(end, Ordering::Relaxed);
        for (dst, value) in self.fields.iter().zip(fields) {
            dst.store(value, Ordering::Relaxed);
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

    fn push(&self, kind: u8, start: u64, end: u64, fields: [u64; EVENT_FIELDS]) {
        // This cursor is actor-local. It is not a cross-thread ordering source.
        let index = self.next.fetch_add(1, Ordering::Relaxed);
        if index >= MAX_EVENTS {
            self.overflow.store(true, Ordering::Release);
            return;
        }
        self.slots[index].write(kind, start, end, fields);
    }
}

struct ActorState {
    captured_fd: AtomicU8,
    captured_ofd: AtomicU8,
    captured_epoch: AtomicU64,
    captured_status: AtomicBool,
    close_pending: AtomicU8,
    replacement_source_fd: AtomicU8,
    replacement_target_fd: AtomicU8,
    replacement_cloexec: AtomicBool,
    ctl_kind: AtomicU8,
    ctl_epoll: AtomicU8,
    ctl_fd: AtomicU8,
    ctl_target: AtomicU8,
    ctl_inner: AtomicU8,
    ctl_trigger: AtomicU8,
    ctl_slot_epoch: AtomicU64,
    ctl_observed: AtomicBool,
    terminal_start: AtomicU64,
}

impl ActorState {
    const fn new() -> Self {
        Self {
            captured_fd: AtomicU8::new(NO_FD),
            captured_ofd: AtomicU8::new(NO_OFD),
            captured_epoch: AtomicU64::new(0),
            captured_status: AtomicBool::new(false),
            close_pending: AtomicU8::new(NO_OFD),
            replacement_source_fd: AtomicU8::new(NO_FD),
            replacement_target_fd: AtomicU8::new(NO_FD),
            replacement_cloexec: AtomicBool::new(false),
            ctl_kind: AtomicU8::new(CTL_NONE),
            ctl_epoll: AtomicU8::new(NO_EPOLL),
            ctl_fd: AtomicU8::new(NO_FD),
            ctl_target: AtomicU8::new(NO_OFD),
            ctl_inner: AtomicU8::new(NO_EPOLL),
            ctl_trigger: AtomicU8::new(TRIGGER_LT),
            ctl_slot_epoch: AtomicU64::new(0),
            ctl_observed: AtomicBool::new(false),
            terminal_start: AtomicU64::new(0),
        }
    }

    fn reset(&self) {
        self.captured_fd.store(NO_FD, Ordering::Relaxed);
        self.captured_ofd.store(NO_OFD, Ordering::Relaxed);
        self.captured_epoch.store(0, Ordering::Relaxed);
        self.captured_status.store(false, Ordering::Relaxed);
        self.close_pending.store(NO_OFD, Ordering::Relaxed);
        self.replacement_source_fd.store(NO_FD, Ordering::Relaxed);
        self.replacement_target_fd.store(NO_FD, Ordering::Relaxed);
        self.replacement_cloexec.store(false, Ordering::Relaxed);
        self.clear_ctl();
    }

    fn clear_ctl(&self) {
        self.ctl_kind.store(CTL_NONE, Ordering::Relaxed);
        self.ctl_epoll.store(NO_EPOLL, Ordering::Relaxed);
        self.ctl_fd.store(NO_FD, Ordering::Relaxed);
        self.ctl_target.store(NO_OFD, Ordering::Relaxed);
        self.ctl_inner.store(NO_EPOLL, Ordering::Relaxed);
        self.ctl_trigger.store(TRIGGER_LT, Ordering::Relaxed);
        self.ctl_slot_epoch.store(0, Ordering::Relaxed);
        self.ctl_observed.store(false, Ordering::Relaxed);
        self.terminal_start.store(0, Ordering::Relaxed);
    }
}

static BUFFERS: [TraceBuffer; ACTORS] = [const { TraceBuffer::new() }; ACTORS];
static ACTOR_STATE: [ActorState; ACTORS] = [const { ActorState::new() }; ACTORS];
static ACTOR_TIDS: [AtomicU32; ACTORS] = [const { AtomicU32::new(0) }; ACTORS];
static FD_NUMBERS: [AtomicU32; FDS] = [const { AtomicU32::new(u32::MAX) }; FDS];
static OFD_ADDRESSES: [AtomicUsize; OFDS] = [const { AtomicUsize::new(0) }; OFDS];
static EPOLL_ADDRESSES: [AtomicUsize; EPOLLS] = [const { AtomicUsize::new(0) }; EPOLLS];

static SLOT_OFD: [AtomicU8; FDS] = [
    AtomicU8::new(TIMER_OFD),
    AtomicU8::new(SIGNAL_OFD),
    AtomicU8::new(EVENT_OFD),
];
static SLOT_CLOEXEC: [AtomicBool; FDS] = [const { AtomicBool::new(false) }; FDS];
static SLOT_EPOCH: [AtomicU64; FDS] = [const { AtomicU64::new(0) }; FDS];
static OFD_ALIVE: [AtomicBool; OFDS] = [const { AtomicBool::new(true) }; OFDS];
static OFD_STATUS: [AtomicBool; OFDS] = [const { AtomicBool::new(false) }; OFDS];
static SOURCE_EPOCH: [AtomicU64; OFDS] = [const { AtomicU64::new(0) }; OFDS];
static EVENT_COUNTER: AtomicU64 = AtomicU64::new(0);
static SIGNAL_MASK: AtomicBool = AtomicBool::new(false);
static EVENT_KEY_REGISTERED: AtomicBool = AtomicBool::new(false);
static EVENT_KEY_INTEREST: AtomicBool = AtomicBool::new(false);
static EVENT_KEY_ENABLED: AtomicBool = AtomicBool::new(false);
static EVENT_KEY_TRIGGER: AtomicU8 = AtomicU8::new(TRIGGER_LT);
static EPOLL_GRAPH_SIZE: AtomicU64 = AtomicU64::new(0);

static INITIALIZED: AtomicBool = AtomicBool::new(false);
static ENABLED: AtomicBool = AtomicBool::new(false);
static UNSUPPORTED: AtomicBool = AtomicBool::new(false);

fn raw_file_address(file: &Arc<dyn FileLike>) -> usize {
    Arc::as_ptr(file) as *const () as usize
}

fn timestamp() -> u64 {
    // SeqCst fences compile to the required x86_64 ordering barriers around RDTSC.
    fence(Ordering::SeqCst);
    let value = ostd::arch::read_tsc();
    fence(Ordering::SeqCst);
    value
}

fn actor_for_tid(tid: u32) -> Option<u8> {
    if !ENABLED.load(Ordering::Acquire) {
        return None;
    }
    if ACTOR_TIDS[T1 as usize].load(Ordering::Relaxed) == tid {
        Some(T1)
    } else if ACTOR_TIDS[T2 as usize].load(Ordering::Relaxed) == tid {
        Some(T2)
    } else {
        None
    }
}

fn current_actor() -> Option<u8> {
    let task = ostd::task::Task::current()?;
    let tid = task.as_thread()?.as_posix_thread()?.tid();
    actor_for_tid(tid)
}

pub(crate) fn begin(tid: u32) -> Option<Span> {
    actor_for_tid(tid).map(|actor| Span {
        actor,
        start: timestamp(),
    })
}

pub(crate) fn begin_current() -> Option<Span> {
    current_actor().map(|actor| Span {
        actor,
        start: timestamp(),
    })
}

fn record(span: Option<Span>, kind: u8, fields: [u64; EVENT_FIELDS]) {
    let Some(span) = span else {
        return;
    };
    let end = timestamp();
    BUFFERS[span.actor as usize].push(kind, span.start, end, fields);
}

fn record_at(span: Span, end: u64, kind: u8, fields: [u64; EVENT_FIELDS]) {
    BUFFERS[span.actor as usize].push(kind, span.start, end, fields);
}

fn fd_label(raw_fd: i32) -> Option<u8> {
    FD_NUMBERS.iter().enumerate().find_map(|(index, value)| {
        (value.load(Ordering::Relaxed) == raw_fd.cast_unsigned()).then_some(index as u8)
    })
}

fn ofd_label(file: &Arc<dyn FileLike>) -> Option<u8> {
    let address = raw_file_address(file);
    ofd_label_from_address(address)
}

fn ofd_label_from_address(address: usize) -> Option<u8> {
    OFD_ADDRESSES.iter().enumerate().find_map(|(index, value)| {
        (value.load(Ordering::Relaxed) == address).then_some(index as u8)
    })
}

fn epoll_label(address: usize) -> Option<u8> {
    EPOLL_ADDRESSES
        .iter()
        .enumerate()
        .find_map(|(index, value)| {
            (value.load(Ordering::Relaxed) == address).then_some(index as u8)
        })
}

pub(crate) fn mapped_ofd(file: &Arc<dyn FileLike>) -> Option<u8> {
    ofd_label(file)
}

fn reset_model() {
    for actor in 0..ACTORS {
        BUFFERS[actor].reset();
        ACTOR_STATE[actor].reset();
    }
    ACTOR_TIDS[T2 as usize].store(0, Ordering::Relaxed);
    for fd in 0..FDS {
        SLOT_OFD[fd].store(fd as u8, Ordering::Relaxed);
        SLOT_CLOEXEC[fd].store(false, Ordering::Relaxed);
        SLOT_EPOCH[fd].store(0, Ordering::Relaxed);
    }
    for ofd in 0..OFDS {
        OFD_ALIVE[ofd].store(true, Ordering::Relaxed);
        OFD_STATUS[ofd].store(false, Ordering::Relaxed);
        SOURCE_EPOCH[ofd].store(0, Ordering::Relaxed);
    }
    EVENT_COUNTER.store(0, Ordering::Relaxed);
    SIGNAL_MASK.store(false, Ordering::Relaxed);
    EVENT_KEY_REGISTERED.store(false, Ordering::Relaxed);
    EVENT_KEY_INTEREST.store(false, Ordering::Relaxed);
    EVENT_KEY_ENABLED.store(false, Ordering::Relaxed);
    EVENT_KEY_TRIGGER.store(TRIGGER_LT, Ordering::Relaxed);
    EPOLL_GRAPH_SIZE.store(0, Ordering::Relaxed);
    UNSUPPORTED.store(false, Ordering::Relaxed);
}

fn command_matches(bytes: &[u8], command: &[u8]) -> bool {
    bytes.get(..command.len()) == Some(command)
        && bytes.get(command.len()).copied().unwrap_or(0) == 0
}

pub(crate) fn control_name(ctx: &Context<'_>, name: &[u8]) {
    if command_matches(name, b"specula-t1") {
        ENABLED.store(false, Ordering::Release);
        INITIALIZED.store(false, Ordering::Release);
        reset_model();

        let file_table = ctx.thread_local.borrow_file_table();
        let table = file_table.unwrap().read();
        for index in 0..FDS {
            let fd: FileDesc = (index as i32).try_into().unwrap();
            let Ok(file) = table.get_file(fd) else {
                return;
            };
            FD_NUMBERS[index].store(index as u32, Ordering::Relaxed);
            OFD_ADDRESSES[index].store(raw_file_address(file), Ordering::Relaxed);
        }
        for index in 0..EPOLLS {
            let fd: FileDesc = ((FDS + index) as i32).try_into().unwrap();
            let Ok(file) = table.get_file(fd) else {
                return;
            };
            EPOLL_ADDRESSES[index].store(raw_file_address(file), Ordering::Relaxed);
        }
        drop(table);
        drop(file_table);

        ACTOR_TIDS[T1 as usize].store(ctx.posix_thread.tid(), Ordering::Relaxed);
        INITIALIZED.store(true, Ordering::Release);
    } else if command_matches(name, b"specula-t2") {
        if INITIALIZED.load(Ordering::Acquire) {
            ACTOR_TIDS[T2 as usize].store(ctx.posix_thread.tid(), Ordering::Relaxed);
            ENABLED.store(true, Ordering::Release);
        }
    } else if command_matches(name, b"specula-flush") {
        ENABLED.store(false, Ordering::Release);
        flush();
    }
}

pub(crate) fn record_fcntl_setfl_capture(
    span: Option<Span>,
    fd: FileDesc,
    file: &Arc<dyn FileLike>,
    status: bool,
) {
    let (Some(span), Some(fd), Some(ofd)) = (span, fd_label(fd.into()), ofd_label(file)) else {
        return;
    };
    let epoch = SLOT_EPOCH[fd as usize].load(Ordering::Relaxed);
    let state = &ACTOR_STATE[span.actor as usize];
    state.captured_fd.store(fd, Ordering::Relaxed);
    state.captured_ofd.store(ofd, Ordering::Relaxed);
    state.captured_epoch.store(epoch, Ordering::Relaxed);
    state.captured_status.store(status, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = fd.into();
    fields[1] = ofd.into();
    fields[2] = status.into();
    fields[3] = epoch;
    record(Some(span), EV_FCNTL_SETFL_CAPTURE, fields);
}

pub(crate) fn record_fcntl_setfl_use(span: Option<Span>) {
    let Some(span) = span else {
        return;
    };
    let state = &ACTOR_STATE[span.actor as usize];
    let fd = state.captured_fd.swap(NO_FD, Ordering::Relaxed);
    let ofd = state.captured_ofd.swap(NO_OFD, Ordering::Relaxed);
    if fd == NO_FD || ofd == NO_OFD {
        return;
    }
    let status = state.captured_status.swap(false, Ordering::Relaxed);
    let capture_epoch = state.captured_epoch.load(Ordering::Relaxed);
    let slot_ofd = SLOT_OFD[fd as usize].load(Ordering::Relaxed);
    let slot_epoch = SLOT_EPOCH[fd as usize].load(Ordering::Relaxed);
    OFD_STATUS[ofd as usize].store(status, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = ofd.into();
    fields[1] = slot_ofd.into();
    fields[2] = capture_epoch;
    fields[3] = slot_epoch;
    fields[4] = status.into();
    fields[5] = OFD_ALIVE[ofd as usize].load(Ordering::Relaxed).into();
    record(Some(span), EV_FCNTL_SETFL_USE, fields);
}

pub(crate) fn record_dup2_equal(span: Option<Span>, fd: FileDesc, file: &Arc<dyn FileLike>) {
    let (Some(fd), Some(ofd)) = (fd_label(fd.into()), ofd_label(file)) else {
        return;
    };
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = fd.into();
    fields[1] = ofd.into();
    record(span, EV_DUP2_EQUAL, fields);
}

pub(crate) fn record_dup3_validate(
    span: Option<Span>,
    source_fd: FileDesc,
    target_fd: FileDesc,
    flags: FdFlags,
) {
    let Some(span) = span else {
        return;
    };
    let (Some(source), Some(target)) = (fd_label(source_fd.into()), fd_label(target_fd.into()))
    else {
        return;
    };
    let cloexec = flags.contains(FdFlags::CLOEXEC);
    let state = &ACTOR_STATE[span.actor as usize];
    state.replacement_source_fd.store(source, Ordering::Relaxed);
    state.replacement_target_fd.store(target, Ordering::Relaxed);
    state.replacement_cloexec.store(cloexec, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = source.into();
    fields[1] = target.into();
    fields[2] = cloexec.into();
    record(Some(span), EV_DUP3_VALIDATE, fields);
}

pub(crate) fn record_dup_exact(
    span: Option<Span>,
    source_file: &Arc<dyn FileLike>,
    replaced_file: Option<&Arc<dyn FileLike>>,
) {
    let Some(span) = span else {
        return;
    };
    let state = &ACTOR_STATE[span.actor as usize];
    let source_fd = state.replacement_source_fd.load(Ordering::Relaxed);
    let target_fd = state.replacement_target_fd.load(Ordering::Relaxed);
    let cloexec = state.replacement_cloexec.load(Ordering::Relaxed);
    let (Some(source_ofd), Some(target_index)) = (
        ofd_label(source_file),
        (target_fd != NO_FD).then_some(target_fd as usize),
    ) else {
        return;
    };
    let replaced_ofd = replaced_file.and_then(ofd_label).unwrap_or(NO_OFD);
    let epoch = SLOT_EPOCH[target_index].fetch_add(1, Ordering::Relaxed) + 1;
    SLOT_OFD[target_index].store(source_ofd, Ordering::Relaxed);
    SLOT_CLOEXEC[target_index].store(cloexec, Ordering::Relaxed);
    state.close_pending.store(replaced_ofd, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = source_fd.into();
    fields[1] = target_fd.into();
    fields[2] = source_ofd.into();
    fields[3] = replaced_ofd.into();
    fields[4] = cloexec.into();
    fields[5] = (replaced_ofd != NO_OFD).into();
    fields[6] = epoch;
    record(Some(span), EV_DUP_EXACT, fields);
}

pub(crate) fn record_dup_cleanup(span: Option<Span>, ofd: u8, alive_after: bool) {
    let Some(span) = span else {
        return;
    };
    if ofd >= NO_OFD {
        return;
    }
    OFD_ALIVE[ofd as usize].store(alive_after, Ordering::Relaxed);
    let state = &ACTOR_STATE[span.actor as usize];
    state.close_pending.store(NO_OFD, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = ofd.into();
    fields[1] = alive_after.into();
    record(Some(span), EV_DUP_CLEANUP, fields);
}

pub(crate) fn record_fcntl_setfd(span: Option<Span>, fd: FileDesc, cloexec: bool) {
    let (Some(span), Some(fd)) = (span, fd_label(fd.into())) else {
        return;
    };
    let ofd = SLOT_OFD[fd as usize].load(Ordering::Relaxed);
    let peer = (0..FDS)
        .find(|peer| *peer != fd as usize && SLOT_OFD[*peer].load(Ordering::Relaxed) == ofd)
        .map(|peer| peer as u8)
        .unwrap_or(NO_FD);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = fd.into();
    fields[1] = cloexec.into();
    if peer != NO_FD {
        fields[2] = 1;
        fields[3] = fd.into();
        fields[4] = peer.into();
        fields[5] = ofd.into();
        fields[6] = cloexec.into();
        fields[7] = SLOT_CLOEXEC[peer as usize].load(Ordering::Relaxed).into();
        fields[8] = SLOT_EPOCH[fd as usize].load(Ordering::Relaxed);
        fields[9] = SLOT_EPOCH[peer as usize].load(Ordering::Relaxed);
    } else {
        fields[3] = NO_FD.into();
        fields[4] = NO_FD.into();
        fields[5] = NO_OFD.into();
    }
    SLOT_CLOEXEC[fd as usize].store(cloexec, Ordering::Relaxed);
    record(Some(span), EV_FCNTL_SETFD, fields);
}

pub(crate) fn record_close_remove(span: Option<Span>, fd: FileDesc, file: &Arc<dyn FileLike>) {
    let (Some(span), Some(fd), Some(ofd)) = (span, fd_label(fd.into()), ofd_label(file)) else {
        return;
    };
    let epoch = SLOT_EPOCH[fd as usize].fetch_add(1, Ordering::Relaxed) + 1;
    SLOT_OFD[fd as usize].store(NO_OFD, Ordering::Relaxed);
    SLOT_CLOEXEC[fd as usize].store(false, Ordering::Relaxed);
    ACTOR_STATE[span.actor as usize]
        .close_pending
        .store(ofd, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = fd.into();
    fields[1] = ofd.into();
    fields[2] = epoch;
    record(Some(span), EV_CLOSE_REMOVE, fields);
}

pub(crate) fn record_closed_drop(span: Option<Span>, ofd: u8, alive_after: bool) {
    let Some(span) = span else {
        return;
    };
    if ofd >= NO_OFD {
        return;
    }
    OFD_ALIVE[ofd as usize].store(alive_after, Ordering::Relaxed);
    ACTOR_STATE[span.actor as usize]
        .close_pending
        .store(NO_OFD, Ordering::Relaxed);
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = ofd.into();
    fields[1] = alive_after.into();
    record(Some(span), EV_CLOSED_DROP, fields);
}

pub(crate) fn record_dup_ceil(
    span: Option<Span>,
    source_fd: FileDesc,
    target_fd: FileDesc,
    target_file: &Arc<dyn FileLike>,
    flags: FdFlags,
) {
    let (Some(source), Some(target), Some(ofd)) = (
        fd_label(source_fd.into()),
        fd_label(target_fd.into()),
        ofd_label(target_file),
    ) else {
        return;
    };
    let cloexec = flags.contains(FdFlags::CLOEXEC);
    let epoch = SLOT_EPOCH[target as usize].fetch_add(1, Ordering::Relaxed) + 1;
    SLOT_OFD[target as usize].store(ofd, Ordering::Relaxed);
    SLOT_CLOEXEC[target as usize].store(cloexec, Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = source.into();
    fields[1] = target.into();
    fields[2] = ofd.into();
    fields[3] = cloexec.into();
    fields[4] = epoch;
    record(span, EV_DUP_CEIL, fields);
}

pub(crate) fn record_close_range_cloexec(span: Option<Span>, first: u32, last: u32) {
    let (Some(first_fd), Some(last_fd)) = (fd_label(first as i32), fd_label(last as i32)) else {
        return;
    };
    for fd in 0..FDS {
        let raw = FD_NUMBERS[fd].load(Ordering::Relaxed);
        if first <= raw && raw <= last && SLOT_OFD[fd].load(Ordering::Relaxed) != NO_OFD {
            SLOT_CLOEXEC[fd].store(true, Ordering::Relaxed);
        }
    }
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = first_fd.into();
    fields[1] = last_fd.into();
    fields[2] = SLOT_CLOEXEC[FD0 as usize].load(Ordering::Relaxed).into();
    fields[3] = SLOT_CLOEXEC[FD1 as usize].load(Ordering::Relaxed).into();
    fields[4] = SLOT_CLOEXEC[FD2 as usize].load(Ordering::Relaxed).into();
    record(span, EV_CLOSE_RANGE_CLOEXEC, fields);
}

pub(crate) fn record_eventfd_add(span: Option<Span>, address: usize, counter: u64) {
    let Some(span) = span else {
        return;
    };
    if ofd_label_from_address(address) != Some(EVENT_OFD) {
        return;
    }
    EVENT_COUNTER.store(counter, Ordering::Relaxed);
    let epoch = SOURCE_EPOCH[EVENT_OFD as usize].fetch_add(1, Ordering::Relaxed) + 1;
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = counter;
    fields[1] = epoch;
    fields[2] = span.actor.into();
    record(Some(span), EV_EVENTFD_ADD, fields);
}

pub(crate) fn record_eventfd_read(span: Option<Span>, address: usize, counter: u64) {
    let Some(span) = span else {
        return;
    };
    if ofd_label_from_address(address) != Some(EVENT_OFD) {
        return;
    }
    EVENT_COUNTER.store(counter, Ordering::Relaxed);
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = counter;
    fields[1] = span.actor.into();
    record(Some(span), EV_EVENTFD_READ, fields);
}

pub(crate) fn record_eventfd_notify_return(span: Option<Span>, address: usize, counter: u64) {
    let Some(span) = span else {
        return;
    };
    if ofd_label_from_address(address) != Some(EVENT_OFD) {
        return;
    }
    if EVENT_KEY_REGISTERED.load(Ordering::Relaxed) {
        UNSUPPORTED.store(true, Ordering::Release);
        return;
    }

    let notify_end = timestamp();
    let return_end = timestamp();
    let mut notify_fields = [0; EVENT_FIELDS];
    notify_fields[0] = span.actor.into();
    notify_fields[1] = counter;
    record_at(span, notify_end, EV_EVENTFD_NOTIFY, notify_fields);

    let mut return_fields = [0; EVENT_FIELDS];
    return_fields[0] = NO_ACTOR.into();
    record_at(
        Span {
            actor: span.actor,
            start: notify_end,
        },
        return_end,
        EV_EVENTFD_NOTIFY_RETURN,
        return_fields,
    );
}

pub(crate) fn record_signalfd_mask(span: Option<Span>, file: &Arc<dyn FileLike>, enabled: bool) {
    if ofd_label(file) != Some(SIGNAL_OFD) {
        return;
    }
    SIGNAL_MASK.store(enabled, Ordering::Relaxed);
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = enabled.into();
    fields[1] = SOURCE_EPOCH[SIGNAL_OFD as usize].load(Ordering::Relaxed);
    record(span, EV_SIGNALFD_MASK, fields);
}

pub(crate) fn record_epoll_capture(
    span: Option<Span>,
    epoll_address: usize,
    fd: FileDesc,
    file: &Arc<dyn FileLike>,
    command: u8,
    trigger: u8,
) {
    let Some(span) = span else {
        return;
    };
    if command != CMD_ADD {
        return;
    }
    let Some(epoll) = epoll_label(epoll_address) else {
        return;
    };
    let state = &ACTOR_STATE[span.actor as usize];
    state.ctl_epoll.store(epoll, Ordering::Relaxed);
    state.ctl_trigger.store(trigger, Ordering::Relaxed);
    state.ctl_observed.store(false, Ordering::Relaxed);

    if let (Some(fd), Some(ofd)) = (fd_label(fd.into()), ofd_label(file)) {
        let epoch = SLOT_EPOCH[fd as usize].load(Ordering::Relaxed);
        state.ctl_kind.store(CTL_OFD, Ordering::Relaxed);
        state.ctl_fd.store(fd, Ordering::Relaxed);
        state.ctl_target.store(ofd, Ordering::Relaxed);
        state.ctl_slot_epoch.store(epoch, Ordering::Relaxed);

        let mut fields = [0; EVENT_FIELDS];
        fields[0] = epoll.into();
        fields[1] = fd.into();
        fields[2] = ofd.into();
        fields[3] = trigger.into();
        fields[4] = epoch;
        record(Some(span), EV_EPOLL_CAPTURE, fields);
    } else if let Some(inner) = epoll_label(raw_file_address(file)) {
        state.ctl_kind.store(CTL_NESTED, Ordering::Relaxed);
        state.ctl_inner.store(inner, Ordering::Relaxed);
        state.terminal_start.store(span.start, Ordering::Relaxed);
    }
}

pub(crate) fn record_entry_update(span: Option<Span>, observed: bool) {
    let Some(span) = span else {
        return;
    };
    let state = &ACTOR_STATE[span.actor as usize];
    if state.ctl_kind.load(Ordering::Relaxed) != CTL_OFD {
        return;
    }
    let ofd = state.ctl_target.load(Ordering::Relaxed);
    if ofd == EVENT_OFD && observed {
        UNSUPPORTED.store(true, Ordering::Release);
        return;
    }
    state.ctl_observed.store(observed, Ordering::Relaxed);
    EVENT_KEY_REGISTERED.store(true, Ordering::Relaxed);
    EVENT_KEY_ENABLED.store(true, Ordering::Relaxed);
    EVENT_KEY_TRIGGER.store(state.ctl_trigger.load(Ordering::Relaxed), Ordering::Relaxed);

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = state.ctl_epoll.load(Ordering::Relaxed).into();
    fields[1] = state.ctl_fd.load(Ordering::Relaxed).into();
    fields[2] = ofd.into();
    fields[3] = state.ctl_trigger.load(Ordering::Relaxed).into();
    fields[4] = state.ctl_slot_epoch.load(Ordering::Relaxed);
    fields[5] = observed.into();
    record(Some(span), EV_ENTRY_UPDATE, fields);
}

pub(crate) fn record_epoll_add(span: Option<Span>) {
    let Some(span) = span else {
        return;
    };
    let state = &ACTOR_STATE[span.actor as usize];
    if state.ctl_kind.load(Ordering::Relaxed) != CTL_OFD {
        return;
    }
    EVENT_KEY_INTEREST.store(true, Ordering::Relaxed);
    let mut fields = [0; EVENT_FIELDS];
    fields[0] = state.ctl_epoll.load(Ordering::Relaxed).into();
    fields[1] = state.ctl_fd.load(Ordering::Relaxed).into();
    fields[2] = state.ctl_target.load(Ordering::Relaxed).into();
    fields[3] = state.ctl_trigger.load(Ordering::Relaxed).into();
    fields[4] = state.ctl_slot_epoch.load(Ordering::Relaxed);
    record(Some(span), EV_EPOLL_ADD, fields);
}

pub(crate) fn epoll_terminal_begin() {
    let Some(actor) = current_actor() else {
        return;
    };
    let state = &ACTOR_STATE[actor as usize];
    if state.ctl_kind.load(Ordering::Relaxed) == CTL_OFD {
        state.terminal_start.store(timestamp(), Ordering::Relaxed);
    }
}

pub(crate) fn epoll_control_finish(epoll_address: usize) {
    let Some(actor) = current_actor() else {
        return;
    };
    let state = &ACTOR_STATE[actor as usize];
    let kind = state.ctl_kind.load(Ordering::Relaxed);
    let Some(epoll) = epoll_label(epoll_address) else {
        state.clear_ctl();
        return;
    };
    if epoll != state.ctl_epoll.load(Ordering::Relaxed) {
        state.clear_ctl();
        return;
    }
    let start = state.terminal_start.swap(0, Ordering::Relaxed);
    if start == 0 {
        state.clear_ctl();
        return;
    }
    let span = Span { actor, start };

    match kind {
        CTL_OFD => {
            let mut fields = [0; EVENT_FIELDS];
            fields[0] = epoll.into();
            fields[1] = state.ctl_fd.load(Ordering::Relaxed).into();
            fields[2] = state.ctl_target.load(Ordering::Relaxed).into();
            record(Some(span), EV_EPOLL_PUSH, fields);
        }
        CTL_NESTED => {
            let graph_size = EPOLL_GRAPH_SIZE.fetch_add(1, Ordering::Relaxed) + 1;
            let mut fields = [0; EVENT_FIELDS];
            fields[0] = epoll.into();
            fields[1] = state.ctl_inner.load(Ordering::Relaxed).into();
            fields[2] = graph_size;
            record(Some(span), EV_EPOLL_NESTED, fields);
        }
        _ => {}
    }
    state.clear_ctl();
}

pub(crate) fn epoll_control_abort() {
    let Some(actor) = current_actor() else {
        return;
    };
    ACTOR_STATE[actor as usize].clear_ctl();
}

fn actor_name(actor: u8) -> &'static str {
    match actor {
        T1 => "t1",
        T2 => "t2",
        _ => "no_thread",
    }
}

fn fd_name(fd: u8) -> &'static str {
    match fd {
        FD0 => "fd0",
        FD1 => "fd1",
        FD2 => "fd2",
        _ => "no_fd",
    }
}

fn ofd_name(ofd: u8) -> &'static str {
    match ofd {
        TIMER_OFD => "timer",
        SIGNAL_OFD => "signal",
        EVENT_OFD => "event",
        _ => "no_ofd",
    }
}

fn epoll_name(epoll: u8) -> &'static str {
    match epoll {
        EP0 => "ep0",
        EP1 => "ep1",
        _ => "no_epoll",
    }
}

fn trigger_name(trigger: u8) -> &'static str {
    match trigger {
        TRIGGER_ET => "ET",
        TRIGGER_ONESHOT => "ONESHOT",
        _ => "LT",
    }
}

fn bool_at(slot: &TraceSlot, index: usize) -> bool {
    slot.field(index) != 0
}

fn print_event(actor: u8, slot: &TraceSlot) {
    let tid = actor_name(actor);
    let start = slot.start.load(Ordering::Relaxed);
    let end = slot.end.load(Ordering::Relaxed);
    match slot.kind.load(Ordering::Acquire) {
        EV_FCNTL_SETFL_CAPTURE => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"FcntlSetFlCapture\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"fd\":\"{}\",\"status\":{}}},\"state\":{{\"captured_ofd\":\"{}\",\"capture_epoch\":{},\"last_captured\":\"{}\",\"acted_ofd\":\"no_ofd\",\"acted_slot_ofd\":\"no_ofd\",\"acted_capture_epoch\":0,\"acted_slot_epoch\":0}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            bool_at(slot, 2),
            ofd_name(slot.field(1) as u8),
            slot.field(3),
            ofd_name(slot.field(1) as u8),
        ),
        EV_FCNTL_SETFL_USE => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"FcntlSetFlUse\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{}},\"state\":{{\"acted_ofd\":\"{}\",\"acted_slot_ofd\":\"{}\",\"acted_capture_epoch\":{},\"acted_slot_epoch\":{},\"ofd_status\":{},\"ofd_alive\":{},\"captured_ofd\":\"no_ofd\",\"captured_fd\":\"no_fd\",\"captured_status\":false}}}}",
            tid,
            start,
            end,
            ofd_name(slot.field(0) as u8),
            ofd_name(slot.field(1) as u8),
            slot.field(2),
            slot.field(3),
            bool_at(slot, 4),
            bool_at(slot, 5),
        ),
        EV_DUP2_EQUAL => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"SysDup2Equal\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"fd\":\"{}\"}},\"state\":{{\"acted_ofd\":\"{}\",\"last_captured\":\"{}\"}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            ofd_name(slot.field(1) as u8),
            ofd_name(slot.field(1) as u8),
        ),
        EV_DUP3_VALIDATE => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"SysDup3Validate\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"source_fd\":\"{}\",\"target_fd\":\"{}\",\"cloexec\":{}}},\"state\":{{\"replacement_phase\":\"validated\",\"replacement_source_ofd\":\"no_ofd\",\"replacement_replaced_ofd\":\"no_ofd\",\"replacement_removed_count\":0}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            bool_at(slot, 2),
        ),
        EV_DUP_EXACT => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"FileTableDupExact\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"target_fd\":\"{}\"}},\"state\":{{\"slot_ofd\":\"{}\",\"slot_cloexec\":{},\"slot_epoch\":{},\"slot_map_audit\":\"{}\",\"fd_flag_audit_active\":false,\"replacement_phase\":\"cleanup\",\"replacement_source_fd\":\"{}\",\"replacement_source_ofd\":\"{}\",\"replacement_replaced_ofd\":\"{}\",\"replacement_new_cloexec\":{},\"replacement_removed_count\":{},\"close_pending\":\"{}\"}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            bool_at(slot, 4),
            slot.field(6),
            ofd_name(slot.field(2) as u8),
            fd_name(slot.field(0) as u8),
            ofd_name(slot.field(2) as u8),
            ofd_name(slot.field(3) as u8),
            bool_at(slot, 4),
            slot.field(5),
            ofd_name(slot.field(3) as u8),
        ),
        EV_DUP_CLEANUP => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"DupReplacementCleanup\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"ofd\":\"{}\"}},\"state\":{{\"replacement_phase\":\"done\",\"close_pending\":\"no_ofd\",\"ofd_alive\":{}}}}}",
            tid,
            start,
            end,
            ofd_name(slot.field(0) as u8),
            bool_at(slot, 1),
        ),
        EV_FCNTL_SETFD => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"FcntlSetFd\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"fd\":\"{}\",\"cloexec\":{}}},\"state\":{{\"slot_cloexec\":{},\"fd_flag_audit_active\":{},\"fd_flag_target\":\"{}\",\"fd_flag_peer\":\"{}\",\"fd_flag_ofd\":\"{}\",\"fd_flag_requested\":{},\"fd_flag_peer_before\":{},\"fd_flag_target_epoch\":{},\"fd_flag_peer_epoch\":{}}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            bool_at(slot, 1),
            bool_at(slot, 1),
            bool_at(slot, 2),
            fd_name(slot.field(3) as u8),
            fd_name(slot.field(4) as u8),
            ofd_name(slot.field(5) as u8),
            bool_at(slot, 6),
            bool_at(slot, 7),
            slot.field(8),
            slot.field(9),
        ),
        EV_CLOSE_REMOVE => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"SysCloseRemove\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"fd\":\"{}\"}},\"state\":{{\"slot_ofd\":\"no_ofd\",\"slot_cloexec\":false,\"slot_epoch\":{},\"slot_map_audit\":\"no_ofd\",\"fd_flag_audit_active\":false,\"close_pending\":\"{}\"}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            slot.field(2),
            ofd_name(slot.field(1) as u8),
        ),
        EV_CLOSED_DROP => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"ClosedFileDrop\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"ofd\":\"{}\"}},\"state\":{{\"close_pending\":\"no_ofd\",\"ofd_alive\":{}}}}}",
            tid,
            start,
            end,
            ofd_name(slot.field(0) as u8),
            bool_at(slot, 1),
        ),
        EV_DUP_CEIL => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"FileTableDupCeil\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"source_fd\":\"{}\",\"target_fd\":\"{}\",\"cloexec\":{}}},\"state\":{{\"slot_ofd\":\"{}\",\"slot_cloexec\":{},\"slot_epoch\":{},\"slot_map_audit\":\"{}\",\"fd_flag_audit_active\":false,\"exec_before_dup\":false,\"exec_after_dup\":false,\"exec_before_cloexec\":false,\"exec_after_cloexec\":false,\"exec_old_table_retained\":false}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            bool_at(slot, 3),
            ofd_name(slot.field(2) as u8),
            bool_at(slot, 3),
            slot.field(4),
            ofd_name(slot.field(2) as u8),
        ),
        EV_CLOSE_RANGE_CLOEXEC => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"SysCloseRangeCloexec\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"first_fd\":\"{}\",\"last_fd\":\"{}\"}},\"state\":{{\"fd0_cloexec\":{},\"fd1_cloexec\":{},\"fd2_cloexec\":{},\"fd_flag_audit_active\":false,\"exec_before_dup\":false,\"exec_after_dup\":false,\"exec_before_cloexec\":false,\"exec_after_cloexec\":false,\"exec_old_table_retained\":false}}}}",
            tid,
            start,
            end,
            fd_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            bool_at(slot, 2),
            bool_at(slot, 3),
            bool_at(slot, 4),
        ),
        EV_EVENTFD_ADD => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EventfdAddCounter\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{}},\"state\":{{\"event_counter\":{},\"source_ready\":true,\"source_epoch\":{},\"producer_phase\":\"event_notify\",\"eventfd_owner\":\"{}\",\"eventfd_counter_snapshot\":{},\"ready_epoch_changes\":[],\"consumer_epoch_changes\":[]}}}}",
            tid,
            start,
            end,
            slot.field(0),
            slot.field(1),
            actor_name(slot.field(2) as u8),
            slot.field(0),
        ),
        EV_EVENTFD_READ => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EventfdTryRead\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{}},\"state\":{{\"event_counter\":{},\"source_ready\":false,\"producer_phase\":\"event_notify\",\"eventfd_owner\":\"{}\",\"eventfd_counter_snapshot\":{}}}}}",
            tid,
            start,
            end,
            slot.field(0),
            actor_name(slot.field(1) as u8),
            slot.field(0),
        ),
        EV_EVENTFD_NOTIFY => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EventfdNotify\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{}},\"state\":{{\"cache_state\":\"invalid\",\"producer_phase\":\"event_callbacks\",\"eventfd_owner\":\"{}\",\"eventfd_counter_snapshot\":{},\"callbacks\":[],\"wake_callbacks\":[]}}}}",
            tid,
            start,
            end,
            actor_name(slot.field(0) as u8),
            slot.field(1),
        ),
        EV_EVENTFD_NOTIFY_RETURN => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EventfdNotifyReturn\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{}},\"state\":{{\"producer_phase\":\"idle\",\"eventfd_owner\":\"no_thread\",\"eventfd_pending_key_count\":0,\"eventfd_pending_waiter_count\":0,\"eventfd_counter_snapshot\":0}}}}",
            tid, start, end,
        ),
        EV_SIGNALFD_MASK => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"SignalfdUpdateMask\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"enabled\":{}}},\"state\":{{\"signal_mask\":{},\"source_epoch\":{},\"ready_epoch_changes\":[],\"consumer_epoch_changes\":[]}}}}",
            tid,
            start,
            end,
            bool_at(slot, 0),
            bool_at(slot, 0),
            slot.field(1),
        ),
        EV_EPOLL_CAPTURE => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EpollControlCaptureTarget\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"epoll\":\"{}\",\"fd\":\"{}\",\"ofd\":\"{}\",\"command\":\"add\",\"trigger\":\"{}\"}},\"state\":{{\"ctl_phase\":\"apply\",\"ctl_command\":\"add\",\"ctl_epoll\":\"{}\",\"ctl_fd\":\"{}\",\"ctl_target\":\"{}\",\"ctl_slot_epoch\":{},\"ctl_trigger\":\"{}\",\"ctl_observed\":false}}}}",
            tid,
            start,
            end,
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            trigger_name(slot.field(3) as u8),
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            slot.field(4),
            trigger_name(slot.field(3) as u8),
        ),
        EV_ENTRY_UPDATE => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EntryUpdatePoll\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"epoll\":\"{}\",\"fd\":\"{}\",\"ofd\":\"{}\",\"consumer\":\"no_thread\"}},\"state\":{{\"ctl_phase\":\"insert\",\"ctl_command\":\"add\",\"ctl_epoll\":\"{}\",\"ctl_fd\":\"{}\",\"ctl_target\":\"{}\",\"ctl_slot_epoch\":{},\"ctl_trigger\":\"{}\",\"ctl_observed\":{},\"epoll_waiter\":\"no_thread\",\"key_enabled\":true,\"key_trigger\":\"{}\",\"key_slot_epoch\":{},\"key_registered\":true,\"key_faulted\":false,\"key_binding_count\":0,\"key_bound_to_actor\":false,\"key_bound_to_consumer\":false,\"ready_epoch\":0,\"consumer_ready_epoch\":0}}}}",
            tid,
            start,
            end,
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            slot.field(4),
            trigger_name(slot.field(3) as u8),
            bool_at(slot, 5),
            trigger_name(slot.field(3) as u8),
            slot.field(4),
        ),
        EV_EPOLL_ADD => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EpollAddInterest\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"epoll\":\"{}\",\"fd\":\"{}\",\"ofd\":\"{}\"}},\"state\":{{\"ctl_phase\":\"push\",\"ctl_command\":\"add\",\"ctl_epoll\":\"{}\",\"ctl_fd\":\"{}\",\"ctl_target\":\"{}\",\"ctl_slot_epoch\":{},\"ctl_trigger\":\"{}\",\"ctl_observed\":false,\"key_in_interest\":true,\"key_enabled\":true,\"key_trigger\":\"{}\",\"key_registered\":true,\"key_faulted\":false,\"key_binding_count\":0,\"key_in_ready\":false,\"key_slot_epoch\":{},\"identity_active\":true,\"identity_fd\":\"{}\",\"identity_ofd\":\"{}\",\"identity_slot_epoch\":{},\"queued_epoch\":0,\"key_delivered\":false,\"interest_count\":1,\"ready_count\":0}}}}",
            tid,
            start,
            end,
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            slot.field(4),
            trigger_name(slot.field(3) as u8),
            trigger_name(slot.field(3) as u8),
            slot.field(4),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
            slot.field(4),
        ),
        EV_EPOLL_PUSH => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EpollControlPushReady\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"epoll\":\"{}\",\"fd\":\"{}\",\"ofd\":\"{}\"}},\"state\":{{\"ctl_phase\":\"idle\",\"ctl_command\":\"none\",\"ctl_epoll\":\"no_epoll\",\"ctl_fd\":\"no_fd\",\"ctl_target\":\"no_ofd\",\"ctl_slot_epoch\":0,\"ctl_trigger\":\"LT\",\"ctl_observed\":false,\"key_in_ready\":false,\"queued_epoch\":0,\"epoll_wake\":false,\"epoll_ready_epoch\":0,\"ofd_alive\":true}}}}",
            tid,
            start,
            end,
            epoll_name(slot.field(0) as u8),
            fd_name(slot.field(1) as u8),
            ofd_name(slot.field(2) as u8),
        ),
        EV_EPOLL_NESTED => println!(
            "SPECULA_TRACE {{\"tag\":\"trace\",\"event\":\"EpollAddNestedInterest\",\"tid\":\"{}\",\"start\":{},\"end\":{},\"args\":{{\"outer\":\"{}\",\"inner\":\"{}\"}},\"state\":{{\"edge_present\":true,\"graph_size\":{}}}}}",
            tid,
            start,
            end,
            epoll_name(slot.field(0) as u8),
            epoll_name(slot.field(1) as u8),
            slot.field(2),
        ),
        _ => println!("SPECULA_TRACE_ERROR unknown-event-kind"),
    }
}

fn flush() {
    println!("SPECULA_TRACE_BEGIN");
    if !INITIALIZED.load(Ordering::Acquire) {
        println!("SPECULA_TRACE_ERROR not-initialized");
    }
    if UNSUPPORTED.load(Ordering::Acquire) {
        println!("SPECULA_TRACE_ERROR unsupported-observer-state");
    }
    for actor in 0..ACTORS {
        if BUFFERS[actor].overflow.load(Ordering::Acquire) {
            println!("SPECULA_TRACE_ERROR actor-buffer-overflow-{}", actor + 1);
        }
        let count = BUFFERS[actor].next.load(Ordering::Acquire).min(MAX_EVENTS);
        for slot in BUFFERS[actor].slots.iter().take(count) {
            print_event(actor as u8, slot);
        }
    }
    println!("SPECULA_TRACE_END");
}
