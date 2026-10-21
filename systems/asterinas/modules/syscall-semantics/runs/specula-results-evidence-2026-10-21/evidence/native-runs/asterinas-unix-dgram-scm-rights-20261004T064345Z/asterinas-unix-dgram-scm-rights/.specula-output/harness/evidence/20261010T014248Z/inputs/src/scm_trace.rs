// SPDX-License-Identifier: MPL-2.0

//! Private instrumentation for the bounded SCM_RIGHTS fixture.

use ostd::task::Task;

use crate::{fs::file::FileLike, prelude::*};

pub(crate) struct Buffer {
    tid: usize,
    case: usize,
    objects: [usize; 2],
    records: Vec<Record>,
    overflow: bool,
    pub(crate) mode: usize,
    prep: [usize; 4],
    queue: usize,
}

struct Record {
    name: &'static str,
    start: u64,
    end: u64,
    values: [usize; 16],
    cpu: u32,
}

pub(crate) fn stamp() -> u64 {
    ostd::arch::read_trace_clock()
}

pub(crate) fn ptr(file: &Arc<dyn FileLike>) -> usize {
    Arc::as_ptr(file) as *const () as usize
}

fn with_buffer(f: impl FnOnce(&mut Buffer)) {
    let Some(task) = Task::current() else { return };
    let Some(local) = task.as_thread_local() else {
        return;
    };
    let mut buffer = local.scm_trace.borrow_mut();
    if let Some(buffer) = buffer.as_mut() {
        f(buffer);
    }
}

pub(crate) fn enabled() -> bool {
    let mut enabled = false;
    with_buffer(|_| enabled = true);
    enabled
}

pub(crate) fn ordinary(file: &Arc<dyn FileLike>) -> bool {
    let p = ptr(file);
    let mut yes = false;
    with_buffer(|b| yes = b.objects.contains(&p));
    yes
}

pub(crate) fn mode() -> usize {
    let mut mode = 0;
    with_buffer(|b| mode = b.mode);
    mode
}

pub(crate) fn origin(entry: usize) -> [usize; 3] {
    let mut result = [0; 3];
    with_buffer(|b| result = [b.tid, b.prep[0], entry]);
    result
}

pub(crate) fn queue(id: usize, register: bool) -> bool {
    let mut yes = false;
    with_buffer(|b| {
        if register {
            b.queue = id;
        }
        yes = b.queue == id;
    });
    yes
}

pub(crate) fn emit(name: &'static str, start: u64, end: u64, values: &[usize]) {
    with_buffer(|b| {
        if b.records.len() == b.records.capacity() || values.len() > 16 {
            b.overflow = true;
            return;
        }
        let mut record = Record {
            name,
            start,
            end,
            values: [0; 16],
            cpu: ostd::cpu::CpuId::current_racy().into(),
        };
        record.values[..values.len()].copy_from_slice(values);
        b.records.push(record);
    });
}

pub(crate) fn begin(receive: bool) {
    let mut prep = [0; 4];
    with_buffer(|b| {
        b.mode = if receive { 2 } else { 1 };
        prep = b.prep;
    });
    let t = stamp();
    emit(if receive { "RecvBegin" } else { "SendBegin" }, t, t, &prep);
}

// This observer is declared before syscall locals, so its destructor runs last.
pub(crate) struct Complete(pub(crate) bool);
impl Drop for Complete {
    fn drop(&mut self) {
        let t = stamp();
        emit(
            if self.0 {
                "SysRecvmsgComplete"
            } else {
                "SysSendmsgComplete"
            },
            t,
            t,
            &[],
        );
        with_buffer(|b| b.mode = 0);
    }
}

pub(crate) fn release(file: Arc<dyn FileLike>, queue: bool) {
    let p = ptr(&file);
    let observed = ordinary(&file);
    let mode = mode();
    let start = stamp();
    drop(file);
    let end = stamp();
    if observed {
        emit(
            if queue {
                "MessageReceiverDropReference"
            } else if mode == 1 {
                "SendTemporaryDrop"
            } else {
                "RecvTemporaryDrop"
            },
            start,
            end,
            &[p],
        );
    }
}

pub(crate) fn control(option: i32, a: u64, b: u64, c: u64, d: u64, ctx: &Context) -> Result<isize> {
    match option {
        0x53504300 => {
            ostd::arch::init_trace_clock();
            let table = ctx.thread_local.borrow_file_table();
            let table = table.unwrap().read();
            let objects = [
                ptr(table.get_file((b as i32).try_into()?)?),
                ptr(table.get_file((c as i32).try_into()?)?),
            ];
            *ctx.thread_local.scm_trace.borrow_mut() = Some(Buffer {
                tid: a as _,
                case: d as _,
                objects,
                records: Vec::with_capacity(1024),
                overflow: false,
                mode: 0,
                prep: [0, 0, 1, 0],
                queue: 0,
            });
        }
        0x53504301 => with_buffer(|buf| buf.prep = [a as _, b as _, c as _, d as _]),
        0x53504302 => {
            let t = stamp();
            emit("RequestCleanup", t, t, &[]);
        }
        0x53504303 => {
            let buffer = ctx.thread_local.scm_trace.borrow_mut().take().unwrap();
            ostd::early_println!(
                "SCM_MAP {{\"case\":{},\"tid\":{},\"objects\":{:?},\"overflow\":{}}}",
                buffer.case,
                buffer.tid,
                buffer.objects,
                buffer.overflow
            );
            for r in &buffer.records {
                ostd::early_println!(
                    "SCM_RAW {{\"case\":{},\"tid\":{},\"event\":\"{}\",\"start\":{},\"end\":{},\"cpu\":{},\"v\":{:?}}}",
                    buffer.case,
                    buffer.tid,
                    r.name,
                    r.start,
                    r.end,
                    r.cpu,
                    r.values
                );
            }
            if buffer.overflow {
                return_errno!(Errno::EOVERFLOW);
            }
            return Ok(buffer.records.len() as _);
        }
        0x53504304 => return Ok(stamp() as isize),
        0x53504305 => return Ok(ostd::arch::trace_clock_period() as isize),
        _ => return_errno!(Errno::EINVAL),
    }
    Ok(0)
}
