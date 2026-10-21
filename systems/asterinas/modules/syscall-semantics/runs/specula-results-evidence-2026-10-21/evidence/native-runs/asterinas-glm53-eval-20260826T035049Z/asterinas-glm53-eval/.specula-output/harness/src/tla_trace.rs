// SPDX-License-Identifier: MPL-2.0

//! Specula timebox tracing for regular-file I/O.
//!
//! The hot path records fixed-size events in the current POSIX thread. Events
//! are printed only when the thread exits, so console serialization cannot
//! become a linearization point for the operations under test.

use core::{
    fmt,
    sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering, fence},
};

use ostd::task::Task;

use crate::{
    fs::{
        file::{FileLike, InodeHandle},
        vfs::path::Path,
    },
    prelude::*,
    process::posix_thread::{AsPosixThread, ThreadLocal},
    thread::AsThread,
};

const TRACE_UNIT_BYTES: usize = PAGE_SIZE / 2;
const TRACE_REQUEST_BYTES: usize = PAGE_SIZE;
const MAX_EVENTS: usize = 128;

const IDLE: &str = "Idle";
const NEED_OFFSET_START: &str = "NeedOffsetStart";
const NEED_POSITIONAL_START: &str = "NeedPositionalStart";
const NEED_ADAPTER: &str = "NeedAdapter";
const NEED_COPY: &str = "NeedCopy";
const NEED_TUPLE_CONVERSION: &str = "NeedTupleConversion";
const NEED_FILE_OPS_RETURN: &str = "NeedFileOpsReturn";
const NEED_HANDLE_RETURN: &str = "NeedHandleReturn";
const NEED_OFFSET_RELEASE: &str = "NeedOffsetRelease";
const NEED_VECTOR_DISPATCH: &str = "NeedVectorDispatch";
const NEED_SYSCALL_FINISH: &str = "NeedSyscallFinish";
const NEED_SIGNAL: &str = "NeedSignal";
const NEED_RESTART: &str = "NeedRestart";
const DONE: &str = "Done";

const NONE: &str = "None";
const OK: &str = "Ok";
const EFAULT: &str = "EFAULT";
const EINTR: &str = "EINTR";
const ERESTARTSYS: &str = "ERESTARTSYS";
const PENDING: &str = "Pending";

pub(crate) const READ_KIND: &str = "Read";
pub(crate) const WRITE_KIND: &str = "Write";
pub(crate) const PREAD_KIND: &str = "Pread64";
pub(crate) const PWRITE_KIND: &str = "Pwrite64";
pub(crate) const READV_KIND: &str = "Readv";
pub(crate) const WRITEV_KIND: &str = "Writev";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Progress {
    None,
    Zero,
    Prefix,
    Complete,
}

impl Progress {
    const fn as_str(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Zero => "Zero",
            Self::Prefix => "Prefix",
            Self::Complete => "Complete",
        }
    }

    const fn units(self) -> usize {
        match self {
            Self::None | Self::Zero => 0,
            Self::Prefix => 1,
            Self::Complete => 2,
        }
    }
}

fn units(bytes: usize) -> usize {
    bytes.div_ceil(TRACE_UNIT_BYTES)
}

fn progress(bytes: usize) -> Progress {
    if bytes == 0 {
        Progress::Zero
    } else if bytes < TRACE_REQUEST_BYTES {
        Progress::Prefix
    } else {
        Progress::Complete
    }
}

fn available(start: usize, bound: usize) -> Progress {
    if bound <= start {
        Progress::Zero
    } else if bound - start < 2 {
        Progress::Prefix
    } else {
        Progress::Complete
    }
}

fn is_read(kind: &str) -> bool {
    matches!(kind, READ_KIND | PREAD_KIND | READV_KIND)
}

fn is_write(kind: &str) -> bool {
    matches!(kind, WRITE_KIND | PWRITE_KIND | WRITEV_KIND)
}

fn is_vector(kind: &str) -> bool {
    matches!(kind, READV_KIND | WRITEV_KIND)
}

fn uses_shared_offset(kind: &str) -> bool {
    matches!(kind, READ_KIND | WRITE_KIND | READV_KIND | WRITEV_KIND)
}

fn start_phase(kind: &str) -> &'static str {
    if uses_shared_offset(kind) {
        NEED_OFFSET_START
    } else {
        NEED_POSITIONAL_START
    }
}

#[derive(Clone, Copy)]
struct OpState {
    phase: &'static str,
    kind: &'static str,
    uses_shared_offset: bool,
    explicit_offset: usize,
    entry_start: usize,
    logical_avail: Progress,
    copy_limit: Progress,
    iov_index: usize,
    requested: usize,
    entry_copied: usize,
    entry_returned: usize,
    copied: usize,
    committed: usize,
    reported: usize,
    offset_advanced: usize,
    entry_status: &'static str,
    result: &'static str,
    last_fault_progress: Progress,
    published_eof: Progress,
    read_past_eof: bool,
    size_at_entry: usize,
    syscall_id: usize,
    attempt_id: usize,
    restart_pending: bool,
    signal_pending: bool,
    sa_restart: bool,
}

impl OpState {
    const fn idle() -> Self {
        Self {
            phase: IDLE,
            kind: NONE,
            uses_shared_offset: false,
            explicit_offset: 0,
            entry_start: 0,
            logical_avail: Progress::Zero,
            copy_limit: Progress::Zero,
            iov_index: 1,
            requested: 0,
            entry_copied: 0,
            entry_returned: 0,
            copied: 0,
            committed: 0,
            reported: 0,
            offset_advanced: 0,
            entry_status: NONE,
            result: PENDING,
            last_fault_progress: Progress::None,
            published_eof: Progress::Zero,
            read_past_eof: false,
            size_at_entry: 0,
            syscall_id: 0,
            attempt_id: 0,
            restart_pending: false,
            signal_pending: false,
            sa_restart: false,
        }
    }

    fn begin(&mut self, kind: &'static str, explicit_offset: usize) {
        let syscall_id = self.syscall_id + 1;
        *self = Self {
            phase: start_phase(kind),
            kind,
            uses_shared_offset: uses_shared_offset(kind),
            explicit_offset,
            iov_index: 1,
            requested: if is_vector(kind) { 4 } else { 2 },
            syscall_id,
            attempt_id: 1,
            ..Self::idle()
        };
    }
}

/// Per-open-description state shared only by trace hooks.
pub(crate) struct TraceFileState {
    profile: &'static str,
    force_vector_boundary: bool,
    vector_boundary_ready: AtomicBool,
    started: AtomicBool,
    initial_shared_offset: AtomicUsize,
    initial_file_size: usize,
    initial_cache_capacity: usize,
    shared_offset: AtomicUsize,
    offset_owner: AtomicU32,
    file_size: AtomicUsize,
    cache_capacity: AtomicUsize,
    effect_log_len: AtomicUsize,
    commit_log_len: AtomicUsize,
}

impl TraceFileState {
    fn new(
        profile: &'static str,
        force_vector_boundary: bool,
        file_size: usize,
        cache_capacity: usize,
    ) -> Self {
        Self {
            profile,
            force_vector_boundary,
            vector_boundary_ready: AtomicBool::new(false),
            started: AtomicBool::new(false),
            initial_shared_offset: AtomicUsize::new(0),
            initial_file_size: file_size,
            initial_cache_capacity: cache_capacity,
            shared_offset: AtomicUsize::new(0),
            offset_owner: AtomicU32::new(0),
            file_size: AtomicUsize::new(file_size),
            cache_capacity: AtomicUsize::new(cache_capacity),
            effect_log_len: AtomicUsize::new(0),
            commit_log_len: AtomicUsize::new(0),
        }
    }

    pub(crate) fn sync_seek(&self, byte_offset: usize) {
        let offset = units(byte_offset);
        self.shared_offset.store(offset, Ordering::Relaxed);
        if !self.started.load(Ordering::Relaxed) {
            self.initial_shared_offset.store(offset, Ordering::Relaxed);
        }
    }

    fn set_sizes(&self, file_size: usize, cache_capacity: usize) {
        self.file_size.store(units(file_size), Ordering::Relaxed);
        self.cache_capacity
            .store(units(cache_capacity), Ordering::Relaxed);
    }
}

pub(crate) fn trace_file_for_path(path: &Path) -> Option<Arc<TraceFileState>> {
    let name = path.name();
    let force_vector_boundary = name.starts_with(".specula_ramfs_fault_vector");
    let profile = if name.starts_with(".specula_correct_") {
        "Correct"
    } else if name.starts_with(".specula_ramfs_") {
        "RamFs"
    } else if name.starts_with(".specula_exfat_") {
        "Exfat"
    } else {
        return None;
    };

    let file_size = path.size();
    let cache_capacity = path
        .inode()
        .page_cache()
        .map(|vmo| vmo.size())
        .unwrap_or(file_size);
    Some(Arc::new(TraceFileState::new(
        profile,
        force_vector_boundary,
        units(file_size),
        units(cache_capacity),
    )))
}

#[derive(Clone, Copy)]
enum EventArgs {
    Empty,
    Begin {
        signal_pending: bool,
        sa_restart: bool,
    },
    PositionalBegin {
        explicit_offset: usize,
        signal_pending: bool,
        sa_restart: bool,
    },
    Copy {
        progress: Progress,
    },
}

#[derive(Clone, Copy)]
struct StateSnapshot {
    shared_offset: usize,
    offset_owner: u32,
    file_size: usize,
    cache_capacity: usize,
    adapter_profile: &'static str,
    op: OpState,
    effect_log_len: usize,
    commit_log_len: usize,
}

#[derive(Clone, Copy)]
struct TraceEvent {
    name: &'static str,
    raw_tid: u32,
    start: u64,
    end: u64,
    args: EventArgs,
    state: StateSnapshot,
}

pub(crate) struct ThreadTrace {
    raw_tid: u32,
    file: Option<Arc<TraceFileState>>,
    op: OpState,
    events: Vec<TraceEvent>,
    dropped: usize,
    suppress_next_begin: bool,
}

impl ThreadTrace {
    pub(crate) fn new() -> Self {
        Self {
            raw_tid: 0,
            file: None,
            op: OpState::idle(),
            events: Vec::with_capacity(MAX_EVENTS),
            dropped: 0,
            suppress_next_begin: false,
        }
    }

    fn append(&mut self, name: &'static str, start: u64, end: u64, args: EventArgs) {
        let Some(file) = self.file.as_ref() else {
            return;
        };
        let state = StateSnapshot {
            shared_offset: file.shared_offset.load(Ordering::Relaxed),
            offset_owner: file.offset_owner.load(Ordering::Relaxed),
            file_size: file.file_size.load(Ordering::Relaxed),
            cache_capacity: file.cache_capacity.load(Ordering::Relaxed),
            adapter_profile: file.profile,
            op: self.op,
            effect_log_len: file.effect_log_len.load(Ordering::Relaxed),
            commit_log_len: file.commit_log_len.load(Ordering::Relaxed),
        };
        if self.events.len() == MAX_EVENTS {
            self.dropped += 1;
            return;
        }
        self.events.push(TraceEvent {
            name,
            raw_tid: self.raw_tid,
            start,
            end,
            args,
            state,
        });
    }

    fn is_active_file(&self, file: &TraceFileState) -> bool {
        self.file
            .as_ref()
            .is_some_and(|active| core::ptr::eq(active.as_ref(), file))
    }

    fn flush(&mut self) {
        let Some(file) = self.file.as_ref() else {
            return;
        };
        println!(
            "SPECULA_CONFIG {{\"tag\":\"config\",\"raw_tid\":\"k{}\",\"initial_state\":{{\"shared_offset\":{},\"file_size\":{},\"cache_capacity\":{},\"adapter_profile\":\"{}\"}},\"dropped\":{}}}",
            self.raw_tid,
            file.initial_shared_offset.load(Ordering::Relaxed),
            file.initial_file_size,
            file.initial_cache_capacity,
            file.profile,
            self.dropped,
        );
        for event in &self.events {
            println!("SPECULA_TRACE {}", EventDisplay(event));
        }
        self.events.clear();
    }
}

struct EventDisplay<'a>(&'a TraceEvent);

impl fmt::Display for EventDisplay<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let event = self.0;
        write!(
            f,
            "{{\"tag\":\"trace\",\"event\":\"{}\",\"tid\":\"k{}\",\"start\":{},\"end\":{},\"args\":",
            event.name, event.raw_tid, event.start, event.end,
        )?;
        match event.args {
            EventArgs::Empty => write!(f, "{{}}")?,
            EventArgs::Begin {
                signal_pending,
                sa_restart,
            } => write!(
                f,
                "{{\"signal_pending\":{},\"sa_restart\":{}}}",
                signal_pending, sa_restart,
            )?,
            EventArgs::PositionalBegin {
                explicit_offset,
                signal_pending,
                sa_restart,
            } => write!(
                f,
                "{{\"explicit_offset\":{},\"signal_pending\":{},\"sa_restart\":{}}}",
                explicit_offset, signal_pending, sa_restart,
            )?,
            EventArgs::Copy { progress } => {
                write!(f, "{{\"progress\":\"{}\"}}", progress.as_str())?
            }
        }

        let state = event.state;
        write!(
            f,
            ",\"state\":{{\"shared_offset\":{},\"offset_owner\":",
            state.shared_offset
        )?;
        if state.offset_owner == 0 {
            write!(f, "\"none\"")?;
        } else {
            write!(f, "\"k{}\"", state.offset_owner)?;
        }
        write!(
            f,
            ",\"file_size\":{},\"cache_capacity\":{},\"adapter_profile\":\"{}\",\"phase\":\"{}\",\"kind\":\"{}\",\"uses_shared_offset\":{},\"explicit_offset\":{},\"entry_start\":{},\"logical_avail\":\"{}\",\"copy_limit\":\"{}\",\"iov_index\":{},\"requested\":{},\"entry_copied\":{},\"entry_returned\":{},\"copied\":{},\"committed\":{},\"reported\":{},\"offset_advanced\":{},\"entry_status\":\"{}\",\"result\":\"{}\",\"last_fault_progress\":\"{}\",\"published_eof\":\"{}\",\"read_past_eof\":{},\"size_at_entry\":{},\"syscall_id\":{},\"attempt_id\":{},\"restart_pending\":{},\"signal_pending\":{},\"sa_restart\":{},\"effect_log_len\":{},\"commit_log_len\":{}}}}}",
            state.file_size,
            state.cache_capacity,
            state.adapter_profile,
            state.op.phase,
            state.op.kind,
            state.op.uses_shared_offset,
            state.op.explicit_offset,
            state.op.entry_start,
            state.op.logical_avail.as_str(),
            state.op.copy_limit.as_str(),
            state.op.iov_index,
            state.op.requested,
            state.op.entry_copied,
            state.op.entry_returned,
            state.op.copied,
            state.op.committed,
            state.op.reported,
            state.op.offset_advanced,
            state.op.entry_status,
            state.op.result,
            state.op.last_fault_progress.as_str(),
            state.op.published_eof.as_str(),
            state.op.read_past_eof,
            state.op.size_at_entry,
            state.op.syscall_id,
            state.op.attempt_id,
            state.op.restart_pending,
            state.op.signal_pending,
            state.op.sa_restart,
            state.effect_log_len,
            state.commit_log_len,
        )
    }
}

fn current_tid() -> Option<u32> {
    let task = Task::current()?;
    let thread = task.as_thread()?;
    Some(thread.as_posix_thread()?.tid())
}

fn with_trace_mut<R>(f: impl FnOnce(&mut ThreadTrace) -> R) -> Option<R> {
    let task = Task::current()?;
    let thread_local = task.as_thread_local()?;
    Some(f(&mut thread_local.tla_trace().borrow_mut()))
}

/// Returns a fenced real TSC timestamp. The harness runs only on x86-64.
pub(crate) fn timestamp() -> u64 {
    fence(Ordering::SeqCst);
    let value = ostd::arch::read_tsc();
    fence(Ordering::SeqCst);
    value
}

pub(crate) fn wait_for_vector_boundary(file: &TraceFileState) {
    let should_wait = file.force_vector_boundary
        && with_trace_mut(|trace| trace.is_active_file(file) && trace.op.kind == WRITE_KIND)
            .unwrap_or(false);
    while should_wait && !file.vector_boundary_ready.load(Ordering::Acquire) {
        Task::yield_now();
    }
}

pub(crate) fn flush_thread(thread_local: &ThreadLocal) {
    thread_local.tla_trace().borrow_mut().flush();
}

fn begin_operation(
    file: &dyn FileLike,
    kind: &'static str,
    explicit_offset_bytes: usize,
    event: &'static str,
) {
    let Some(handle) = file.downcast_ref::<InodeHandle>() else {
        return;
    };
    let Some(trace_file) = handle.tla_trace_file() else {
        return;
    };
    let Some(raw_tid) = current_tid() else {
        return;
    };
    let trace_file = trace_file.clone();
    let _ = with_trace_mut(|trace| {
        trace.raw_tid = raw_tid;
        trace.file = Some(trace_file.clone());
        if trace.suppress_next_begin {
            trace.suppress_next_begin = false;
            return;
        }
        trace_file.started.store(true, Ordering::Relaxed);
        let start = timestamp();
        trace.op.begin(kind, units(explicit_offset_bytes));
        let end = timestamp();
        let args = if uses_shared_offset(kind) {
            EventArgs::Begin {
                signal_pending: false,
                sa_restart: false,
            }
        } else {
            EventArgs::PositionalBegin {
                explicit_offset: units(explicit_offset_bytes),
                signal_pending: false,
                sa_restart: false,
            }
        };
        trace.append(event, start, end, args);
    });
}

pub(crate) fn sys_read_begin(file: &dyn FileLike) {
    begin_operation(file, READ_KIND, 0, "SysReadBegin");
}

pub(crate) fn sys_write_begin(file: &dyn FileLike) {
    begin_operation(file, WRITE_KIND, 0, "SysWriteBegin");
}

pub(crate) fn sys_pread64_begin(file: &dyn FileLike, offset: usize) {
    begin_operation(file, PREAD_KIND, offset, "SysPread64Begin");
}

pub(crate) fn sys_pwrite64_begin(file: &dyn FileLike, offset: usize) {
    begin_operation(file, PWRITE_KIND, offset, "SysPwrite64Begin");
}

pub(crate) fn sys_readv_begin(file: &dyn FileLike) {
    begin_operation(file, READV_KIND, 0, "DoSysReadvBegin");
}

pub(crate) fn sys_writev_begin(file: &dyn FileLike) {
    begin_operation(file, WRITEV_KIND, 0, "DoSysWritevBegin");
}

pub(crate) fn restart_syscall_if_pending(kind: Option<&'static str>) {
    let Some(kind) = kind else {
        return;
    };
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_RESTART || !trace.op.restart_pending || trace.op.kind != kind {
            return;
        }
        let start = timestamp();
        trace.op.phase = start_phase(trace.op.kind);
        trace.op.entry_start = 0;
        trace.op.logical_avail = Progress::Zero;
        trace.op.copy_limit = Progress::Zero;
        trace.op.iov_index = 1;
        trace.op.entry_copied = 0;
        trace.op.entry_returned = 0;
        trace.op.reported = 0;
        trace.op.entry_status = NONE;
        trace.op.result = PENDING;
        trace.op.last_fault_progress = Progress::None;
        trace.op.published_eof = Progress::Zero;
        trace.op.size_at_entry = 0;
        trace.op.attempt_id += 1;
        trace.op.restart_pending = false;
        trace.suppress_next_begin = true;
        let end = timestamp();
        trace.append("RestartSyscall", start, end, EventArgs::Empty);
    });
}

fn acquire_offset(file: &TraceFileState, byte_offset: usize, start: u64, event: &'static str) {
    let _ = with_trace_mut(|trace| {
        if !trace.is_active_file(file) || trace.op.phase != NEED_OFFSET_START {
            return;
        }
        file.shared_offset
            .store(units(byte_offset), Ordering::Relaxed);
        file.offset_owner.store(trace.raw_tid, Ordering::Relaxed);
        trace.op.entry_start = units(byte_offset);
        trace.op.phase = NEED_ADAPTER;
        let end = timestamp();
        trace.append(event, start, end, EventArgs::Empty);
    });
}

pub(crate) fn read_acquire_offset(file: &TraceFileState, byte_offset: usize, start: u64) {
    acquire_offset(file, byte_offset, start, "InodeHandleReadAcquireOffset");
}

pub(crate) fn write_acquire_offset(file: &TraceFileState, byte_offset: usize, start: u64) {
    acquire_offset(file, byte_offset, start, "InodeHandleWriteAcquireOffset");
}

fn positional_start(file: &TraceFileState, byte_offset: usize, event: &'static str) {
    let _ = with_trace_mut(|trace| {
        if !trace.is_active_file(file) || trace.op.phase != NEED_POSITIONAL_START {
            return;
        }
        let start = timestamp();
        trace.op.entry_start = units(byte_offset);
        trace.op.phase = NEED_ADAPTER;
        let end = timestamp();
        trace.append(event, start, end, EventArgs::Empty);
    });
}

pub(crate) fn read_at_start(file: &TraceFileState, byte_offset: usize) {
    positional_start(file, byte_offset, "InodeHandleReadAtStart");
}

pub(crate) fn write_at_start(file: &TraceFileState, byte_offset: usize) {
    positional_start(file, byte_offset, "InodeHandleWriteAtStart");
}

fn read_compute_limit(
    event: &'static str,
    expected_profile: &'static str,
    file_size_bytes: usize,
    cache_capacity_bytes: usize,
    bounded_to_eof: bool,
    start: u64,
) {
    let _ = with_trace_mut(|trace| {
        let Some(file) = trace.file.as_ref() else {
            return;
        };
        if trace.op.phase != NEED_ADAPTER || !is_read(trace.op.kind) {
            return;
        }
        if expected_profile == "Correct" {
            if file.profile != "Correct" {
                return;
            }
        } else if !matches!(file.profile, "RamFs" | "Exfat") {
            return;
        }
        file.set_sizes(file_size_bytes, cache_capacity_bytes);
        let file_size = units(file_size_bytes);
        let cache_capacity = units(cache_capacity_bytes);
        trace.op.logical_avail = available(trace.op.entry_start, file_size);
        trace.op.copy_limit = if bounded_to_eof {
            trace.op.logical_avail
        } else {
            available(trace.op.entry_start, cache_capacity)
        };
        trace.op.size_at_entry = file_size;
        trace.op.phase = NEED_COPY;
        let end = timestamp();
        trace.append(event, start, end, EventArgs::Empty);
    });
}

pub(crate) fn correct_read_compute_limit(file_size: usize, cache_capacity: usize, start: u64) {
    read_compute_limit(
        "Ext2VirtioFsReadComputeLimit",
        "Correct",
        file_size,
        cache_capacity,
        true,
        start,
    );
}

pub(crate) fn ramfs_exfat_read_compute_limit(file_size: usize, cache_capacity: usize, start: u64) {
    read_compute_limit(
        "RamFsExfatReadComputeLimit",
        "RamFsOrExfat",
        file_size,
        cache_capacity,
        false,
        start,
    );
}

pub(crate) fn ramfs_write_publish_requested_end(
    old_size: usize,
    new_size: usize,
    cache_capacity: usize,
    start: u64,
) {
    let _ = with_trace_mut(|trace| {
        let Some(file) = trace.file.as_ref() else {
            return;
        };
        if file.profile != "RamFs" || trace.op.phase != NEED_ADAPTER || !is_write(trace.op.kind) {
            return;
        }
        file.set_sizes(new_size, cache_capacity);
        trace.op.logical_avail = Progress::Complete;
        trace.op.copy_limit = Progress::Complete;
        trace.op.size_at_entry = units(old_size);
        trace.op.published_eof = if new_size > old_size {
            Progress::Complete
        } else {
            Progress::Zero
        };
        trace.op.phase = NEED_COPY;
        let end = timestamp();
        trace.append(
            "RamFsWritePublishRequestedEnd",
            start,
            end,
            EventArgs::Empty,
        );
    });
}

pub(crate) fn deferred_write_prepare(old_size: usize, cache_capacity: usize, start: u64) {
    let _ = with_trace_mut(|trace| {
        let Some(file) = trace.file.as_ref() else {
            return;
        };
        if !matches!(file.profile, "Correct" | "Exfat")
            || trace.op.phase != NEED_ADAPTER
            || !is_write(trace.op.kind)
        {
            return;
        }
        file.set_sizes(old_size, cache_capacity);
        trace.op.logical_avail = Progress::Complete;
        trace.op.copy_limit = Progress::Complete;
        trace.op.size_at_entry = units(old_size);
        trace.op.published_eof = Progress::Zero;
        trace.op.phase = NEED_COPY;
        let end = timestamp();
        trace.append("DeferredWritePrepare", start, end, EventArgs::Empty);
    });
}

#[derive(Clone, Copy)]
pub(crate) struct VmoProbe {
    start: u64,
    before: usize,
    read: bool,
}

fn vmo_start(before: usize, read: bool) -> Option<VmoProbe> {
    with_trace_mut(|trace| {
        if trace.op.phase != NEED_COPY
            || (read && !is_read(trace.op.kind))
            || (!read && !is_write(trace.op.kind))
        {
            return None;
        }
        Some(VmoProbe {
            start: timestamp(),
            before,
            read,
        })
    })?
}

pub(crate) fn vmo_read_start(before_avail: usize) -> Option<VmoProbe> {
    vmo_start(before_avail, true)
}

pub(crate) fn vmo_write_start(before_remain: usize) -> Option<VmoProbe> {
    vmo_start(before_remain, false)
}

fn vmo_finish(probe: Option<VmoProbe>, after: usize, faulted: bool) {
    let Some(probe) = probe else {
        return;
    };
    let moved = probe.before.saturating_sub(after);
    let progress = progress(moved);
    let amount = progress.units();
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_COPY {
            return;
        }
        trace.op.entry_copied = amount;
        trace.op.copied += amount;
        trace.op.committed += amount;
        trace.op.last_fault_progress = if faulted { progress } else { Progress::None };
        if probe.read {
            trace.op.read_past_eof |= amount > trace.op.logical_avail.units();
        }
        trace.op.phase = if faulted {
            NEED_TUPLE_CONVERSION
        } else {
            NEED_FILE_OPS_RETURN
        };
        if amount > 0 {
            trace
                .file
                .as_ref()
                .unwrap()
                .effect_log_len
                .fetch_add(1, Ordering::Relaxed);
        }
        let end = timestamp();
        trace.append(
            if probe.read { "VmoRead" } else { "VmoWrite" },
            probe.start,
            end,
            EventArgs::Copy { progress },
        );
    });
}

pub(crate) fn vmo_read_finish(probe: Option<VmoProbe>, after_avail: usize, faulted: bool) {
    vmo_finish(probe, after_avail, faulted);
}

pub(crate) fn vmo_write_finish(probe: Option<VmoProbe>, after_remain: usize, faulted: bool) {
    vmo_finish(probe, after_remain, faulted);
}

pub(crate) fn error_from_tuple(start: u64) {
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_TUPLE_CONVERSION {
            return;
        }
        trace.op.entry_status = EFAULT;
        trace.op.phase = NEED_HANDLE_RETURN;
        let end = timestamp();
        trace.append("ErrorFromTuple", start, end, EventArgs::Empty);
    });
}

pub(crate) fn file_ops_read_return(
    returned_bytes: usize,
    file_size: usize,
    cache_capacity: usize,
    start: u64,
) {
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_FILE_OPS_RETURN || !is_read(trace.op.kind) {
            return;
        }
        trace
            .file
            .as_ref()
            .unwrap()
            .set_sizes(file_size, cache_capacity);
        trace.op.entry_returned = progress(returned_bytes).units();
        trace.op.entry_status = OK;
        trace.op.phase = NEED_HANDLE_RETURN;
        let end = timestamp();
        trace.append("FileOpsReadReturn", start, end, EventArgs::Empty);
    });
}

pub(crate) fn file_ops_write_return(
    returned_bytes: usize,
    file_size: usize,
    cache_capacity: usize,
    start: u64,
) {
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_FILE_OPS_RETURN || !is_write(trace.op.kind) {
            return;
        }
        trace
            .file
            .as_ref()
            .unwrap()
            .set_sizes(file_size, cache_capacity);
        trace.op.entry_returned = progress(returned_bytes).units();
        trace.op.entry_status = OK;
        trace.op.published_eof = if units(file_size) > trace.op.size_at_entry {
            Progress::Complete
        } else {
            Progress::Zero
        };
        trace.op.phase = NEED_HANDLE_RETURN;
        let end = timestamp();
        trace.append("FileOpsWriteReturn", start, end, EventArgs::Empty);
    });
}

pub(crate) fn commit_offset(
    file: &TraceFileState,
    new_byte_offset: usize,
    returned_bytes: usize,
    start: u64,
) {
    let _ = with_trace_mut(|trace| {
        if !trace.is_active_file(file)
            || trace.op.phase != NEED_HANDLE_RETURN
            || trace.op.entry_status != OK
        {
            return;
        }
        let amount = progress(returned_bytes).units();
        file.shared_offset
            .store(units(new_byte_offset), Ordering::Relaxed);
        trace.op.offset_advanced += amount;
        trace.op.phase = NEED_OFFSET_RELEASE;
        if amount > 0 {
            file.commit_log_len.fetch_add(1, Ordering::Relaxed);
        }
        let end = timestamp();
        trace.append("InodeHandleCommitOffset", start, end, EventArgs::Empty);
    });
}

pub(crate) fn propagate_error(file: &TraceFileState, errno: Errno, start: u64) {
    let _ = with_trace_mut(|trace| {
        if !trace.is_active_file(file) || trace.op.phase != NEED_HANDLE_RETURN {
            return;
        }
        trace.op.entry_status = if errno == Errno::EINTR { EINTR } else { EFAULT };
        trace.op.phase = NEED_OFFSET_RELEASE;
        let end = timestamp();
        trace.append("InodeHandlePropagateError", start, end, EventArgs::Empty);
    });
}

pub(crate) fn positional_return(file: &TraceFileState, errno: Option<Errno>, start: u64) {
    let _ = with_trace_mut(|trace| {
        if !trace.is_active_file(file) || trace.op.phase != NEED_HANDLE_RETURN {
            return;
        }
        if let Some(errno) = errno {
            trace.op.entry_status = if errno == Errno::EINTR { EINTR } else { EFAULT };
        }
        trace.op.phase = NEED_SYSCALL_FINISH;
        let end = timestamp();
        trace.append("InodeHandlePositionalReturn", start, end, EventArgs::Empty);
    });
}

pub(crate) fn release_offset(file: &TraceFileState, start: u64) {
    let _ = with_trace_mut(|trace| {
        if !trace.is_active_file(file) || trace.op.phase != NEED_OFFSET_RELEASE {
            return;
        }
        file.offset_owner.store(0, Ordering::Relaxed);
        trace.op.phase = if is_vector(trace.op.kind) {
            NEED_VECTOR_DISPATCH
        } else {
            NEED_SYSCALL_FINISH
        };
        let end = timestamp();
        trace.append("InodeHandleReleaseOffset", start, end, EventArgs::Empty);
    });
}

pub(crate) fn vector_handle_entry(continue_to_next: bool, start: u64) {
    let competitor = with_trace_mut(|trace| {
        if trace.op.phase != NEED_VECTOR_DISPATCH {
            return None;
        }
        let event = if trace.op.kind == READV_KIND {
            "DoSysReadvHandleEntry"
        } else if trace.op.kind == WRITEV_KIND {
            "DoSysWritevHandleEntry"
        } else {
            return None;
        };
        if trace.op.entry_status == OK {
            trace.op.reported += trace.op.entry_returned;
        }
        if continue_to_next {
            trace.op.iov_index += 1;
            trace.op.entry_start = 0;
            trace.op.logical_avail = Progress::Zero;
            trace.op.copy_limit = Progress::Zero;
            trace.op.entry_copied = 0;
            trace.op.entry_returned = 0;
            trace.op.entry_status = NONE;
            trace.op.last_fault_progress = Progress::None;
            trace.op.published_eof = Progress::Zero;
            trace.op.size_at_entry = 0;
            trace.op.phase = NEED_OFFSET_START;
        } else {
            trace.op.phase = NEED_SYSCALL_FINISH;
        }
        let end = timestamp();
        trace.append(event, start, end, EventArgs::Empty);
        let file = trace.file.as_ref()?;
        if continue_to_next && file.force_vector_boundary {
            file.vector_boundary_ready.store(true, Ordering::Release);
            Some((file.clone(), trace.raw_tid))
        } else {
            None
        }
    })
    .flatten();

    if let Some((file, own_tid)) = competitor {
        loop {
            let owner = file.offset_owner.load(Ordering::Acquire);
            if owner != 0 && owner != own_tid {
                break;
            }
            Task::yield_now();
        }
    }
}

fn scalar_finish(event: &'static str, kind: &'static str, result: &Result<usize>) {
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_SYSCALL_FINISH || trace.op.kind != kind {
            return;
        }
        let start = timestamp();
        match result {
            Ok(returned) => {
                trace.op.reported = progress(*returned).units();
                trace.op.result = OK;
            }
            Err(err) => {
                trace.op.reported = 0;
                trace.op.result = if matches!(kind, READ_KIND | WRITE_KIND)
                    && err.error() == Errno::ERESTARTSYS
                {
                    ERESTARTSYS
                } else if err.error() == Errno::EINTR {
                    EINTR
                } else {
                    EFAULT
                };
            }
        }
        trace.op.phase = NEED_SIGNAL;
        let end = timestamp();
        trace.append(event, start, end, EventArgs::Empty);
    });
}

pub(crate) fn sys_read_finish(result: &Result<usize>) {
    scalar_finish("SysReadFinish", READ_KIND, result);
}

pub(crate) fn sys_write_finish(result: &Result<usize>) {
    scalar_finish("SysWriteFinish", WRITE_KIND, result);
}

pub(crate) fn sys_pread64_finish(result: &Result<usize>) {
    scalar_finish("SysPread64Finish", PREAD_KIND, result);
}

pub(crate) fn sys_pwrite64_finish(result: &Result<usize>) {
    scalar_finish("SysPwrite64Finish", PWRITE_KIND, result);
}

fn vector_finish(event: &'static str, kind: &'static str, result: &Result<usize>) {
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_SYSCALL_FINISH || trace.op.kind != kind {
            return;
        }
        let start = timestamp();
        trace.op.result = if result.is_ok() {
            OK
        } else {
            trace.op.entry_status
        };
        trace.op.phase = NEED_SIGNAL;
        let end = timestamp();
        trace.append(event, start, end, EventArgs::Empty);
    });
}

pub(crate) fn sys_readv_finish(result: &Result<usize>) {
    vector_finish("SysReadvFinish", READV_KIND, result);
}

pub(crate) fn sys_writev_finish(result: &Result<usize>) {
    vector_finish("SysWritevFinish", WRITEV_KIND, result);
}

pub(crate) fn handle_pending_signal(restartable: bool) {
    let _ = with_trace_mut(|trace| {
        if trace.op.phase != NEED_SIGNAL {
            return;
        }
        let start = timestamp();
        if trace.op.result == ERESTARTSYS {
            trace.op.result = EINTR;
        }
        trace.op.restart_pending = restartable;
        trace.op.signal_pending = false;
        trace.op.phase = if restartable { NEED_RESTART } else { DONE };
        let end = timestamp();
        trace.append("HandlePendingSignal", start, end, EventArgs::Empty);
    });
}
