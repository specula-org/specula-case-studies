// SPDX-License-Identifier: MPL-2.0

//! Test-only timebox tracing for regular-file partial-progress validation.

use core::{
    hint::spin_loop,
    sync::atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering, fence},
};

use aster_block::{
    bio::TraceSubmitHandle,
    tla_trace::{self as block_trace, TraceIdentity},
};

use crate::{
    fs::{
        file::{FileLike, InodeHandle, StatusFlags},
        vfs::inode::FileOps,
    },
    prelude::*,
};

pub(crate) const EVENT_SYS_READ_START: u8 = 1;
pub(crate) const EVENT_SYS_WRITE_START: u8 = 2;
pub(crate) const EVENT_SYS_PREAD64_START: u8 = 3;
pub(crate) const EVENT_SYS_PWRITE64_START: u8 = 4;
pub(crate) const EVENT_DO_SYS_READV_START: u8 = 5;
pub(crate) const EVENT_DO_SYS_WRITEV_START: u8 = 6;
pub(crate) const EVENT_INODE_READ_ACQUIRE_OFFSET: u8 = 7;
pub(crate) const EVENT_INODE_WRITE_ACQUIRE_OFFSET: u8 = 8;
pub(crate) const EVENT_INODE_READ_AT_BEGIN: u8 = 9;
pub(crate) const EVENT_INODE_WRITE_AT_BEGIN: u8 = 10;
pub(crate) const EVENT_INODE_WRITE_CHOOSE_APPEND: u8 = 11;
pub(crate) const EVENT_RAM_READ_SNAPSHOT_SIZE: u8 = 12;
pub(crate) const EVENT_EXT2_ZERO_WRITE_RETURN: u8 = 13;
pub(crate) const EVENT_FILE_OPS_ACQUIRE_DATA: u8 = 14;
pub(crate) const EVENT_INODE_INNER_PREPARE_WRITE: u8 = 15;
pub(crate) const EVENT_RAM_PUBLISH_METADATA: u8 = 16;
pub(crate) const EVENT_FILE_READ_COPY_COMPLETE: u8 = 17;
pub(crate) const EVENT_FILE_READ_COPY_FAULT_ZERO: u8 = 18;
pub(crate) const EVENT_FILE_READ_COPY_FAULT_POSITIVE: u8 = 19;
pub(crate) const EVENT_FILE_WRITE_COPY_COMPLETE: u8 = 20;
pub(crate) const EVENT_FILE_WRITE_COPY_FAULT_ZERO: u8 = 21;
pub(crate) const EVENT_FILE_WRITE_COPY_FAULT_POSITIVE: u8 = 22;
pub(crate) const EVENT_BIO_SEGMENT_COPY_COMPLETE: u8 = 23;
pub(crate) const EVENT_BIO_SEGMENT_COPY_FAULT_ZERO: u8 = 24;
pub(crate) const EVENT_BIO_SEGMENT_COPY_FAULT_POSITIVE: u8 = 25;
pub(crate) const EVENT_INTERRUPTIBLE_BACKEND_EINTR: u8 = 26;
pub(crate) const EVENT_FILE_READ_FINISH: u8 = 27;
pub(crate) const EVENT_DIRECT_READ_FINISH: u8 = 28;
pub(crate) const EVENT_BUFFERED_WRITE_SUCCESS: u8 = 29;
pub(crate) const EVENT_BUFFERED_WRITE_FAULT_RETAIN: u8 = 30;
pub(crate) const EVENT_BUFFERED_WRITE_FAULT_DISCARD: u8 = 31;
pub(crate) const EVENT_ANON_WRITE_SUCCESS: u8 = 32;
pub(crate) const EVENT_ANON_WRITE_FAULT: u8 = 33;
pub(crate) const EVENT_BIO_SUBMIT: u8 = 34;
pub(crate) const EVENT_IO_BATCH_WAIT_ALL: u8 = 36;
pub(crate) const EVENT_DIRECT_WRITE_COMMIT: u8 = 37;
pub(crate) const EVENT_DIRECT_WRITE_ROLLBACK: u8 = 38;
pub(crate) const EVENT_FILE_OPS_RELEASE_DATA: u8 = 39;
pub(crate) const EVENT_INODE_READ_RETURN_OK: u8 = 40;
pub(crate) const EVENT_INODE_READ_RETURN_ERROR: u8 = 41;
pub(crate) const EVENT_INODE_WRITE_RETURN_OK: u8 = 42;
pub(crate) const EVENT_INODE_WRITE_RETURN_ERROR: u8 = 43;
pub(crate) const EVENT_READV_ENTRY_OK_CONTINUE: u8 = 44;
pub(crate) const EVENT_READV_ENTRY_OK_RETURN: u8 = 45;
pub(crate) const EVENT_READV_ENTRY_FAULT_RETURN: u8 = 46;
pub(crate) const EVENT_WRITEV_ENTRY_OK_CONTINUE: u8 = 47;
pub(crate) const EVENT_WRITEV_ENTRY_OK_RETURN: u8 = 48;
pub(crate) const EVENT_WRITEV_ENTRY_FAULT_RETURN: u8 = 49;
pub(crate) const EVENT_SYS_READ_RETURN: u8 = 50;
pub(crate) const EVENT_SYS_WRITE_RETURN: u8 = 51;
pub(crate) const EVENT_SYS_PREAD64_RETURN: u8 = 52;
pub(crate) const EVENT_SYS_PWRITE64_RETURN: u8 = 53;
pub(crate) const EVENT_SYS_READ_TRANSLATE_EINTR: u8 = 54;
pub(crate) const EVENT_SYS_WRITE_TRANSLATE_EINTR: u8 = 55;
pub(crate) const EVENT_SIGNAL_CLASSIFY: u8 = 56;
pub(crate) const EVENT_SIGNAL_RESTART: u8 = 57;
pub(crate) const EVENT_SIGNAL_NO_RESTART: u8 = 58;
pub(crate) const EVENT_TASK_RESTART_SYSCALL: u8 = 59;

const ACTORS: usize = 2;
const MAX_EVENTS: usize = 256;
const EVENT_FIELDS: usize = 16;
const MODE_NONE: u8 = 0;
const MODE_RAMFS: u8 = 1;
const MODE_EXT2_BUFFERED: u8 = 2;
const MODE_EXT2_DIRECT: u8 = 3;
const MODE_REFERENCE: u8 = 4;
const MODE_OVERLAP_PREFIX: u8 = 5;

pub(crate) const PAGE_UP_TO_DATE: u8 = 1;
pub(crate) const PAGE_UNINIT: u8 = 2;

#[derive(Clone, Copy)]
pub(crate) struct Span {
    actor: u8,
    start: u64,
}

#[derive(Clone, Copy)]
pub(crate) struct StampedSpan {
    span: Span,
    order: u64,
}

struct TraceSlot {
    kind: AtomicU8,
    start: AtomicU64,
    end: AtomicU64,
    order: AtomicU64,
    attempt: AtomicU64,
    effect: AtomicU64,
    fields: [AtomicU64; EVENT_FIELDS],
}

impl TraceSlot {
    const fn new() -> Self {
        Self {
            kind: AtomicU8::new(0),
            start: AtomicU64::new(0),
            end: AtomicU64::new(0),
            order: AtomicU64::new(0),
            attempt: AtomicU64::new(0),
            effect: AtomicU64::new(0),
            fields: [const { AtomicU64::new(0) }; EVENT_FIELDS],
        }
    }

    #[expect(clippy::too_many_arguments)]
    fn write(
        &self,
        kind: u8,
        start: u64,
        end: u64,
        order: u64,
        attempt: u64,
        effect: u64,
        fields: [u64; EVENT_FIELDS],
    ) {
        self.kind.store(0, Ordering::Relaxed);
        self.start.store(start, Ordering::Relaxed);
        self.end.store(end, Ordering::Relaxed);
        self.order.store(order, Ordering::Relaxed);
        self.attempt.store(attempt, Ordering::Relaxed);
        self.effect.store(effect, Ordering::Relaxed);
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

    #[expect(clippy::too_many_arguments)]
    fn push(
        &self,
        kind: u8,
        start: u64,
        end: u64,
        order: u64,
        attempt: u64,
        effect: u64,
        fields: [u64; EVENT_FIELDS],
    ) {
        // Each registered syscall actor is the only writer of its buffer.
        let index = self.next.fetch_add(1, Ordering::Relaxed);
        if index >= MAX_EVENTS {
            self.overflow.store(true, Ordering::Release);
            return;
        }
        self.slots[index].write(kind, start, end, order, attempt, effect, fields);
    }
}

struct ReferenceFileOps;

static BUFFERS: [TraceBuffer; ACTORS] = [const { TraceBuffer::new() }; ACTORS];
static ACTOR_ENABLED: [AtomicBool; ACTORS] = [const { AtomicBool::new(false) }; ACTORS];
static ATTEMPT: [AtomicU64; ACTORS] = [const { AtomicU64::new(0) }; ACTORS];
static EFFECT: [AtomicU64; ACTORS] = [const { AtomicU64::new(0) }; ACTORS];
static VECTOR_ENTRY: [AtomicU64; ACTORS] = [const { AtomicU64::new(1) }; ACTORS];
static DIRECT_PART: [AtomicU64; ACTORS] = [const { AtomicU64::new(1) }; ACTORS];
static START_KIND: [AtomicU8; ACTORS] = [const { AtomicU8::new(0) }; ACTORS];
static BACKEND_ACTIVE: [AtomicBool; ACTORS] = [const { AtomicBool::new(false) }; ACTORS];
static RETAINED_PREFIX: [AtomicU64; ACTORS] = [const { AtomicU64::new(0) }; ACTORS];
static FAULT_PAGE: [AtomicU8; ACTORS] = [const { AtomicU8::new(PAGE_UP_TO_DATE) }; ACTORS];
static REFERENCE_INJECTED: [AtomicBool; ACTORS] = [const { AtomicBool::new(false) }; ACTORS];
static RESTART_ENTRY_PENDING: [AtomicBool; ACTORS] = [const { AtomicBool::new(false) }; ACTORS];
static RESTART_SYSCALL: [AtomicU64; ACTORS] = [const { AtomicU64::new(u64::MAX) }; ACTORS];

static INITIALIZED: AtomicBool = AtomicBool::new(false);
static ENABLED: AtomicBool = AtomicBool::new(false);
static ERROR_CODE: AtomicU8 = AtomicU8::new(0);
static MODE: AtomicU8 = AtomicU8::new(MODE_NONE);
static TARGET_HANDLE: AtomicUsize = AtomicUsize::new(0);
static TARGET_INODE: AtomicUsize = AtomicUsize::new(0);
static TARGET_VMO: AtomicUsize = AtomicUsize::new(0);
static OBSERVED_OFD_OFFSET: AtomicU64 = AtomicU64::new(0);
static OVERLAP_START_READY: AtomicU8 = AtomicU8::new(0);
static OVERLAP_START_RECORDED: AtomicU8 = AtomicU8::new(0);

static REFERENCE_DATA: Mutex<[u8; PAGE_SIZE * 2]> = Mutex::new([0; PAGE_SIZE * 2]);
static REFERENCE_FILE_OPS: ReferenceFileOps = ReferenceFileOps;

fn timestamp() -> u64 {
    fence(Ordering::SeqCst);
    let value = ostd::arch::read_tsc();
    fence(Ordering::SeqCst);
    value
}

fn raw_handle_address(handle: &InodeHandle) -> usize {
    handle as *const InodeHandle as usize
}

fn raw_file_handle_address(file: &Arc<dyn FileLike>) -> Option<usize> {
    file.downcast_ref::<InodeHandle>().map(raw_handle_address)
}

fn command_matches(bytes: &[u8], command: &[u8]) -> bool {
    bytes.get(..command.len()) == Some(command)
        && bytes.get(command.len()).copied().unwrap_or(0) == 0
}

fn registered_actor() -> Option<u8> {
    let task = ostd::task::Task::current()?;
    let actor = task.as_thread_local()?.specula_trace_actor();
    (actor < ACTORS as u8).then_some(actor)
}

fn active_actor() -> Option<u8> {
    if !ENABLED.load(Ordering::Acquire) {
        return None;
    }
    let actor = registered_actor()?;
    ACTOR_ENABLED[actor as usize]
        .load(Ordering::Acquire)
        .then_some(actor)
}

fn reset() {
    ENABLED.store(false, Ordering::Release);
    INITIALIZED.store(false, Ordering::Release);
    ERROR_CODE.store(0, Ordering::Relaxed);
    TARGET_HANDLE.store(0, Ordering::Relaxed);
    TARGET_INODE.store(0, Ordering::Relaxed);
    TARGET_VMO.store(0, Ordering::Relaxed);
    OBSERVED_OFD_OFFSET.store(0, Ordering::Relaxed);
    OVERLAP_START_READY.store(0, Ordering::Relaxed);
    OVERLAP_START_RECORDED.store(0, Ordering::Relaxed);
    for actor in 0..ACTORS {
        BUFFERS[actor].reset();
        ACTOR_ENABLED[actor].store(false, Ordering::Relaxed);
        ATTEMPT[actor].store(0, Ordering::Relaxed);
        EFFECT[actor].store(0, Ordering::Relaxed);
        VECTOR_ENTRY[actor].store(1, Ordering::Relaxed);
        DIRECT_PART[actor].store(1, Ordering::Relaxed);
        START_KIND[actor].store(0, Ordering::Relaxed);
        BACKEND_ACTIVE[actor].store(false, Ordering::Relaxed);
        RETAINED_PREFIX[actor].store(0, Ordering::Relaxed);
        FAULT_PAGE[actor].store(PAGE_UP_TO_DATE, Ordering::Relaxed);
        REFERENCE_INJECTED[actor].store(false, Ordering::Relaxed);
        RESTART_ENTRY_PENDING[actor].store(false, Ordering::Relaxed);
        RESTART_SYSCALL[actor].store(u64::MAX, Ordering::Relaxed);
    }
    block_trace::reset();
}

fn set_error(code: u8) {
    let _ = ERROR_CODE.compare_exchange(0, code, Ordering::Release, Ordering::Relaxed);
}

fn push(span: Span, kind: u8, order: u64, end: u64, fields: [u64; EVENT_FIELDS]) {
    if !ENABLED.load(Ordering::Acquire)
        || !ACTOR_ENABLED[span.actor as usize].load(Ordering::Acquire)
    {
        return;
    }
    let actor = span.actor as usize;
    BUFFERS[actor].push(
        kind,
        span.start,
        end,
        order,
        ATTEMPT[actor].load(Ordering::Relaxed),
        EFFECT[actor].load(Ordering::Relaxed),
        fields,
    );
}

pub(crate) fn begin_current() -> Option<Span> {
    active_actor().map(|actor| Span {
        actor,
        start: timestamp(),
    })
}

pub(crate) fn begin_handle(handle: &InodeHandle) -> Option<Span> {
    (raw_handle_address(handle) == TARGET_HANDLE.load(Ordering::Acquire))
        .then(begin_current)
        .flatten()
}

pub(crate) fn begin_inode(address: usize) -> Option<Span> {
    (address == TARGET_INODE.load(Ordering::Acquire))
        .then(begin_current)
        .flatten()
}

pub(crate) fn begin_backend() -> Option<Span> {
    let actor = active_actor()?;
    BACKEND_ACTIVE[actor as usize]
        .load(Ordering::Acquire)
        .then(|| Span {
            actor,
            start: timestamp(),
        })
}

pub(crate) fn stamp(span: Option<Span>) -> Option<StampedSpan> {
    let span = span?;
    Some(StampedSpan {
        span,
        order: block_trace::next_shadow_order(),
    })
}

pub(crate) fn record(span: Option<Span>, kind: u8, fields: [u64; EVENT_FIELDS]) {
    let Some(span) = span else {
        return;
    };
    let order = block_trace::next_shadow_order();
    let end = timestamp();
    push(span, kind, order, end, fields);
}

pub(crate) fn record_stamped(stamped: Option<StampedSpan>, kind: u8, fields: [u64; EVENT_FIELDS]) {
    let Some(stamped) = stamped else {
        return;
    };
    let end = timestamp();
    push(stamped.span, kind, stamped.order, end, fields);
}

pub(crate) fn record_start(
    file: &Arc<dyn FileLike>,
    kind: u8,
    requested_bytes: usize,
    explicit_offset_bytes: usize,
    append: bool,
) {
    if raw_file_handle_address(file) != Some(TARGET_HANDLE.load(Ordering::Acquire)) {
        return;
    }
    let Some(actor) = active_actor() else {
        return;
    };
    let index = actor as usize;
    if RESTART_ENTRY_PENDING[index].swap(false, Ordering::AcqRel) {
        return;
    }
    let span = Span {
        actor,
        start: timestamp(),
    };
    let overlap_mode = MODE.load(Ordering::Acquire) == MODE_OVERLAP_PREFIX;
    if overlap_mode {
        OVERLAP_START_READY.fetch_add(1, Ordering::AcqRel);
        while OVERLAP_START_READY.load(Ordering::Acquire) < ACTORS as u8 {
            spin_loop();
        }
    }
    let attempt = ATTEMPT[index].fetch_add(1, Ordering::Relaxed) + 1;
    EFFECT[index].store(attempt, Ordering::Relaxed);
    VECTOR_ENTRY[index].store(1, Ordering::Relaxed);
    DIRECT_PART[index].store(1, Ordering::Relaxed);
    START_KIND[index].store(kind, Ordering::Relaxed);
    RETAINED_PREFIX[index].store(0, Ordering::Relaxed);
    FAULT_PAGE[index].store(PAGE_UP_TO_DATE, Ordering::Relaxed);
    if attempt > 4 {
        set_error(4);
    }
    #[cfg(target_arch = "x86_64")]
    if kind == EVENT_SYS_READ_START {
        RESTART_SYSCALL[index].store(0, Ordering::Relaxed);
    } else if kind == EVENT_SYS_WRITE_START {
        RESTART_SYSCALL[index].store(1, Ordering::Relaxed);
    }

    let mut fields = [0; EVENT_FIELDS];
    fields[0] = MODE.load(Ordering::Relaxed).into();
    fields[1] = requested_bytes as u64;
    fields[2] = explicit_offset_bytes as u64;
    fields[3] = append.into();
    fields[4] = file
        .downcast_ref::<InodeHandle>()
        .map(|handle| handle.path().size() as u64)
        .unwrap_or(0);
    record(Some(span), kind, fields);
    if overlap_mode {
        OVERLAP_START_RECORDED.fetch_add(1, Ordering::AcqRel);
        while OVERLAP_START_RECORDED.load(Ordering::Acquire) < ACTORS as u8 {
            spin_loop();
        }
        for enabled in &ACTOR_ENABLED {
            enabled.store(false, Ordering::Release);
        }
        ENABLED.store(false, Ordering::Release);
        block_trace::set_enabled(false);
    }
}

pub(crate) fn record_offset_acquire(span: Option<Span>, kind: u8, offset: usize) {
    OBSERVED_OFD_OFFSET.store(offset as u64, Ordering::Release);
    record(span, kind, fields(&[offset as u64]));
}

pub(crate) fn record_positional_begin(span: Option<Span>, kind: u8, offset: usize) {
    let observed_ofd = OBSERVED_OFD_OFFSET.load(Ordering::Acquire);
    record(span, kind, fields(&[offset as u64, observed_ofd]));
}

pub(crate) fn observed_ofd_offset() -> usize {
    OBSERVED_OFD_OFFSET.load(Ordering::Acquire) as usize
}

pub(crate) fn record_append(span: Option<Span>, old_offset: usize, new_offset: usize) {
    OBSERVED_OFD_OFFSET.store(new_offset as u64, Ordering::Release);
    record(
        span,
        EVENT_INODE_WRITE_CHOOSE_APPEND,
        fields(&[old_offset as u64, new_offset as u64]),
    );
}

pub(crate) fn record_acquire_data(span: Option<Span>) {
    let Some(span) = span else {
        return;
    };
    BACKEND_ACTIVE[span.actor as usize].store(true, Ordering::Release);
    record(Some(span), EVENT_FILE_OPS_ACQUIRE_DATA, [0; EVENT_FIELDS]);
}

pub(crate) fn record_release_data(stamped: Option<StampedSpan>) {
    let Some(stamped) = stamped else {
        return;
    };
    BACKEND_ACTIVE[stamped.span.actor as usize].store(false, Ordering::Release);
    record_stamped(
        Some(stamped),
        EVENT_FILE_OPS_RELEASE_DATA,
        [0; EVENT_FIELDS],
    );
}

pub(crate) fn record_inode_return(
    stamped: Option<StampedSpan>,
    kind: u8,
    ok: bool,
    reported_bytes: usize,
    ofd_offset: usize,
    positional: bool,
) {
    if !positional {
        OBSERVED_OFD_OFFSET.store(ofd_offset as u64, Ordering::Release);
    }
    record_stamped(
        stamped,
        kind,
        fields(&[
            ok.into(),
            reported_bytes as u64,
            ofd_offset as u64,
            positional.into(),
        ]),
    );
}

pub(crate) fn record_vector_event(
    span: Option<Span>,
    kind: u8,
    entry: usize,
    entry_bytes: usize,
    total_bytes: usize,
    cursor_bytes: usize,
    ok: bool,
) {
    let actor = span.map(|value| value.actor);
    record(
        span,
        kind,
        fields(&[
            entry as u64,
            entry_bytes as u64,
            total_bytes as u64,
            cursor_bytes as u64,
            ok.into(),
        ]),
    );
    if matches!(
        kind,
        EVENT_READV_ENTRY_OK_CONTINUE | EVENT_WRITEV_ENTRY_OK_CONTINUE
    ) && let Some(actor) = actor
    {
        VECTOR_ENTRY[actor as usize].fetch_add(1, Ordering::Relaxed);
    }
}

pub(crate) fn reset_copy_observation() {
    let Some(actor) = registered_actor() else {
        return;
    };
    RETAINED_PREFIX[actor as usize].store(0, Ordering::Relaxed);
    FAULT_PAGE[actor as usize].store(PAGE_UP_TO_DATE, Ordering::Relaxed);
}

pub(crate) fn observe_retained_prefix(vmo_address: usize, bytes: usize) {
    if bytes == 0 {
        return;
    }
    let Some(actor) = registered_actor() else {
        return;
    };
    if vmo_address != TARGET_VMO.load(Ordering::Acquire)
        || !BACKEND_ACTIVE[actor as usize].load(Ordering::Acquire)
    {
        return;
    }
    RETAINED_PREFIX[actor as usize].fetch_add(bytes as u64, Ordering::Relaxed);
}

pub(crate) fn observe_backed_fault(vmo_address: usize, page_up_to_date: bool, bytes: usize) {
    let Some(actor) = registered_actor() else {
        return;
    };
    let index = actor as usize;
    if vmo_address != TARGET_VMO.load(Ordering::Acquire)
        || !BACKEND_ACTIVE[index].load(Ordering::Acquire)
    {
        return;
    }
    FAULT_PAGE[index].store(
        if page_up_to_date {
            PAGE_UP_TO_DATE
        } else {
            PAGE_UNINIT
        },
        Ordering::Relaxed,
    );
    if page_up_to_date && bytes > 0 {
        RETAINED_PREFIX[index].fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

pub(crate) fn copy_observation() -> (u8, usize) {
    let Some(actor) = registered_actor() else {
        return (PAGE_UP_TO_DATE, 0);
    };
    let index = actor as usize;
    (
        FAULT_PAGE[index].load(Ordering::Relaxed),
        RETAINED_PREFIX[index].load(Ordering::Relaxed) as usize,
    )
}

pub(crate) fn sample_data_epoch() -> u64 {
    block_trace::sample_data_epoch()
}

pub(crate) fn publish_data_effect() -> u64 {
    block_trace::publish_data_effect()
}

pub(crate) fn current_direct_part() -> u64 {
    registered_actor()
        .map(|actor| DIRECT_PART[actor as usize].load(Ordering::Relaxed))
        .unwrap_or(1)
}

pub(crate) fn current_bio_identity(range_start_bytes: usize) -> Option<TraceIdentity> {
    let actor = active_actor()?;
    let index = actor as usize;
    let segment = DIRECT_PART[index].load(Ordering::Relaxed);
    if segment > 2 {
        set_error(5);
        return None;
    }
    Some(TraceIdentity {
        owner: actor,
        attempt: ATTEMPT[index].load(Ordering::Relaxed),
        effect: EFFECT[index].load(Ordering::Relaxed),
        vector_entry: if START_KIND[index].load(Ordering::Relaxed) == EVENT_DO_SYS_WRITEV_START {
            VECTOR_ENTRY[index].load(Ordering::Relaxed)
        } else {
            0
        },
        segment,
        range_start_bytes: range_start_bytes as u64,
    })
}

pub(crate) fn record_bio_submit(
    span: Option<Span>,
    identity: TraceIdentity,
    handle: TraceSubmitHandle,
) {
    let Some(span) = span else {
        return;
    };
    let order = block_trace::next_shadow_order();
    let end = timestamp();
    let event_fields = fields(&[
        identity.owner.into(),
        identity.attempt,
        identity.effect,
        identity.vector_entry,
        identity.segment,
        identity.range_start_bytes,
    ]);
    push(span, EVENT_BIO_SUBMIT, order, end, event_fields);
    handle.publish_submit_order(order);
    if identity.segment == 1 {
        DIRECT_PART[span.actor as usize].store(2, Ordering::Relaxed);
    } else {
        DIRECT_PART[span.actor as usize].store(3, Ordering::Relaxed);
    }
}

pub(crate) fn record_signal_delivery(span: Option<Span>, kind: u8, restart: bool) {
    record(span, kind, fields(&[restart.into(), restart.into()]));
}

pub(crate) fn record_task_restart(syscall_num: usize) {
    let Some(actor) = active_actor() else {
        return;
    };
    let index = actor as usize;
    if MODE.load(Ordering::Acquire) != MODE_REFERENCE
        || !REFERENCE_INJECTED[index].load(Ordering::Acquire)
        || RESTART_SYSCALL[index].load(Ordering::Acquire) != syscall_num as u64
    {
        return;
    }
    let span = Span {
        actor,
        start: timestamp(),
    };
    ATTEMPT[index].fetch_add(1, Ordering::Relaxed);
    VECTOR_ENTRY[index].store(1, Ordering::Relaxed);
    DIRECT_PART[index].store(1, Ordering::Relaxed);
    record(Some(span), EVENT_TASK_RESTART_SYSCALL, [0; EVENT_FIELDS]);
    RESTART_ENTRY_PENDING[index].store(true, Ordering::Release);
}

pub(crate) fn reference_file_ops_if_target(handle: &InodeHandle) -> Option<&'static dyn FileOps> {
    (MODE.load(Ordering::Acquire) == MODE_REFERENCE
        && raw_handle_address(handle) == TARGET_HANDLE.load(Ordering::Acquire))
    .then_some(&REFERENCE_FILE_OPS as &dyn FileOps)
}

fn should_inject_reference() -> Option<u8> {
    let actor = registered_actor()?;
    (MODE.load(Ordering::Acquire) == MODE_REFERENCE
        && !REFERENCE_INJECTED[actor as usize].swap(true, Ordering::AcqRel))
    .then_some(actor)
}

fn wait_for_reference_signal() {
    // The sender sleeps for 1 ms before pthread_kill. This bounded delay keeps
    // the signal pending until the syscall reaches the injected EINTR seam.
    for _ in 0..50_000_000 {
        spin_loop();
    }
}

impl FileOps for ReferenceFileOps {
    fn read_at(
        &self,
        offset: usize,
        writer: &mut VmWriter,
        _status_flags: StatusFlags,
    ) -> Result<usize> {
        let acquire_span = begin_current();
        let data = REFERENCE_DATA.lock();
        record_acquire_data(acquire_span);

        let requested = writer.avail().min(data.len().saturating_sub(offset));
        let before = writer.avail();
        let copy_span = begin_backend();
        let mut reader = VmReader::from(&data[offset..offset + requested]).to_fallible();
        let result = reader.read_fallible(writer);
        let copied = before - writer.avail();
        let epoch = sample_data_epoch();
        let (copy_kind, copy_error) = match result {
            Ok(_) => (EVENT_FILE_READ_COPY_COMPLETE, None),
            Err((error, 0)) => (EVENT_FILE_READ_COPY_FAULT_ZERO, Some(error)),
            Err((error, _)) => (EVENT_FILE_READ_COPY_FAULT_POSITIVE, Some(error)),
        };
        record(
            copy_span,
            copy_kind,
            fields(&[requested as u64, copied as u64, 0, 0, epoch]),
        );

        if should_inject_reference().is_some() {
            wait_for_reference_signal();
            record(
                begin_backend(),
                EVENT_INTERRUPTIBLE_BACKEND_EINTR,
                fields(&[copied as u64, 0, epoch]),
            );
            let release = stamp(begin_backend());
            drop(data);
            record_release_data(release);
            return Err(Error::new(Errno::EINTR));
        }

        let finish = begin_backend();
        record(
            finish,
            EVENT_FILE_READ_FINISH,
            fields(&[
                copy_error.is_none().into(),
                if copy_error.is_none() {
                    copied as u64
                } else {
                    0
                },
                (PAGE_SIZE * 2) as u64,
            ]),
        );
        let release = stamp(begin_backend());
        drop(data);
        record_release_data(release);
        copy_error.map_or(Ok(copied), |error| Err(error.into()))
    }

    fn write_at(
        &self,
        offset: usize,
        reader: &mut VmReader,
        _status_flags: StatusFlags,
    ) -> Result<usize> {
        let acquire_span = begin_current();
        let mut data = REFERENCE_DATA.lock();
        record_acquire_data(acquire_span);

        let requested = reader.remain().min(data.len().saturating_sub(offset));
        record(
            begin_backend(),
            EVENT_INODE_INNER_PREPARE_WRITE,
            fields(&[data.len() as u64, (offset + requested) as u64]),
        );
        let before = reader.remain();
        let copy_span = begin_backend();
        let mut writer = VmWriter::from(&mut data[offset..offset + requested]).to_fallible();
        let result = writer.write_fallible(reader);
        let copied = before - reader.remain();
        let (copy_kind, copy_error) = match result {
            Ok(_) => (EVENT_FILE_WRITE_COPY_COMPLETE, None),
            Err((error, 0)) => (EVENT_FILE_WRITE_COPY_FAULT_ZERO, Some(error)),
            Err((error, _)) => (EVENT_FILE_WRITE_COPY_FAULT_POSITIVE, Some(error)),
        };
        record(
            copy_span,
            copy_kind,
            fields(&[
                requested as u64,
                copied as u64,
                PAGE_UP_TO_DATE.into(),
                copied as u64,
            ]),
        );

        if should_inject_reference().is_some() {
            wait_for_reference_signal();
            let epoch = if copied > 0 {
                publish_data_effect()
            } else {
                sample_data_epoch()
            };
            record(
                begin_backend(),
                EVENT_INTERRUPTIBLE_BACKEND_EINTR,
                fields(&[copied as u64, 1, epoch]),
            );
            let release = stamp(begin_backend());
            drop(data);
            record_release_data(release);
            return Err(Error::new(Errno::EINTR));
        }

        let epoch = if copied > 0 {
            publish_data_effect()
        } else {
            sample_data_epoch()
        };
        record(
            begin_backend(),
            EVENT_ANON_WRITE_SUCCESS,
            fields(&[copied as u64, (PAGE_SIZE * 2) as u64, epoch]),
        );
        let release = stamp(begin_backend());
        drop(data);
        record_release_data(release);
        copy_error.map_or(Ok(copied), |error| Err(error.into()))
    }
}

pub(crate) fn control_name(ctx: &Context<'_>, name: &[u8]) {
    let mode = if command_matches(name, b"sp-ram-t0") {
        Some(MODE_RAMFS)
    } else if command_matches(name, b"sp-buf-t0") {
        Some(MODE_EXT2_BUFFERED)
    } else if command_matches(name, b"sp-dir-t0") {
        Some(MODE_EXT2_DIRECT)
    } else if command_matches(name, b"sp-ref-t0") {
        Some(MODE_REFERENCE)
    } else if command_matches(name, b"sp-ovl-t0") {
        Some(MODE_OVERLAP_PREFIX)
    } else {
        None
    };

    if let Some(mode) = mode {
        reset();
        MODE.store(mode, Ordering::Relaxed);
        ctx.thread_local.set_specula_trace_actor(0);

        let file_table = ctx.thread_local.borrow_file_table();
        let table = file_table.unwrap().read();
        let Ok(fd) = 3i32.try_into() else {
            set_error(1);
            return;
        };
        let Ok(file) = table.get_file(fd) else {
            set_error(1);
            return;
        };
        let Some(handle) = file.downcast_ref::<InodeHandle>() else {
            set_error(2);
            return;
        };
        let inode = handle.path().inode();
        TARGET_HANDLE.store(raw_handle_address(handle), Ordering::Relaxed);
        TARGET_INODE.store(Arc::as_ptr(&inode) as *const () as usize, Ordering::Relaxed);
        TARGET_VMO.store(
            inode
                .page_cache()
                .map(|vmo| Arc::as_ptr(&vmo) as usize)
                .unwrap_or(0),
            Ordering::Relaxed,
        );
        let size = handle.path().size();
        let offset = handle.offset();
        if size != PAGE_SIZE * 2 || offset != 0 {
            set_error(3);
        }
        OBSERVED_OFD_OFFSET.store(offset as u64, Ordering::Relaxed);
        drop(table);
        drop(file_table);

        ACTOR_ENABLED[0].store(true, Ordering::Relaxed);
        INITIALIZED.store(true, Ordering::Release);
    } else if command_matches(name, b"sp-io-t1") {
        if INITIALIZED.load(Ordering::Acquire) {
            ctx.thread_local.set_specula_trace_actor(1);
            ACTOR_ENABLED[1].store(true, Ordering::Relaxed);
            ENABLED.store(true, Ordering::Release);
            block_trace::set_enabled(true);
        }
    } else if command_matches(name, b"sp-io-flush") {
        ENABLED.store(false, Ordering::Release);
        for enabled in &ACTOR_ENABLED {
            enabled.store(false, Ordering::Release);
        }
        block_trace::set_enabled(false);
        flush();
    }
}

fn fields(values: &[u64]) -> [u64; EVENT_FIELDS] {
    let mut result = [0; EVENT_FIELDS];
    result[..values.len()].copy_from_slice(values);
    result
}

pub(crate) fn event_fields(values: &[u64]) -> [u64; EVENT_FIELDS] {
    fields(values)
}

fn flush() {
    println!("SPECULA_TRACE_BEGIN");
    if !INITIALIZED.load(Ordering::Acquire) {
        println!("SPECULA_TRACE_ERROR not-initialized");
    }
    match ERROR_CODE.load(Ordering::Acquire) {
        0 => {}
        1 => println!("SPECULA_TRACE_ERROR target-fd-missing"),
        2 => println!("SPECULA_TRACE_ERROR target-not-inode-handle"),
        3 => println!("SPECULA_TRACE_ERROR initial-state-mismatch"),
        4 => println!("SPECULA_TRACE_ERROR max-attempts-exceeded"),
        5 => println!("SPECULA_TRACE_ERROR direct-range-count-exceeded"),
        code => println!("SPECULA_TRACE_ERROR producer-{}", code),
    }
    for (actor, buffer) in BUFFERS.iter().enumerate() {
        if buffer.overflow.load(Ordering::Acquire) {
            println!("SPECULA_TRACE_ERROR actor-buffer-overflow-{}", actor);
        }
        let count = buffer.next.load(Ordering::Acquire).min(MAX_EVENTS);
        for slot in buffer.slots.iter().take(count) {
            println!(
                "SPECULA_RAW {{\"tag\":\"raw\",\"kind\":{},\"tid\":\"{}\",\"start\":{},\"end\":{},\"shadow_order\":{},\"attempt\":{},\"effect\":{},\"raw\":[{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}]}}",
                slot.kind.load(Ordering::Acquire),
                actor,
                slot.start.load(Ordering::Relaxed),
                slot.end.load(Ordering::Relaxed),
                slot.order.load(Ordering::Relaxed),
                slot.attempt.load(Ordering::Relaxed),
                slot.effect.load(Ordering::Relaxed),
                slot.field(0),
                slot.field(1),
                slot.field(2),
                slot.field(3),
                slot.field(4),
                slot.field(5),
                slot.field(6),
                slot.field(7),
                slot.field(8),
                slot.field(9),
                slot.field(10),
                slot.field(11),
                slot.field(12),
                slot.field(13),
                slot.field(14),
                slot.field(15),
            );
        }
    }
    block_trace::flush();
    println!("SPECULA_TRACE_END");
}
