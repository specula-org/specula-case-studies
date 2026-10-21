// SPDX-License-Identifier: MPL-2.0

use ostd::{mm::VmIo, wr_trace as wr};

use super::SyscallReturn;
use crate::prelude::*;

pub(super) fn output(api: u64, ptr: u64, ctx: &Context) -> Result<[u64; 5]> {
    if api == 4 {
        let status: i32 = ctx.user_space().read_val(ptr as usize)?;
        Ok([0, 0, 0, 0, status as i64 as u64])
    } else {
        // The fixture pins the x86-64 siginfo ABI and supplies 128 valid bytes.
        let raw: [i32; 32] = ctx.user_space().read_val(ptr as usize)?;
        Ok([raw[4] as u64, raw[5] as u64, raw[0] as u64,
            raw[2] as u64, raw[6] as i64 as u64])
    }
}

pub(super) fn begin(api: u64, pid: u64, which: u64, options: u64,
    rusage: u64, buffer: u64, ctx: &Context) -> Result<()> {
    if !(1..=2).contains(&wr::actor()) { return Ok(()); }
    let start = wr::stamp();
    let out = output(api, buffer, ctx)?;
    wr::begin(start, &[api, pid, which, options, rusage, buffer,
        out[0], out[1], out[2], out[3], out[4]]);
    Ok(())
}

pub(super) fn copyout(start: u64, api: u64, buffer: u64, ctx: &Context) -> Result<()> {
    if wr::waiting() {
        let end = wr::stamp();
        let out = output(api, buffer, ctx)?;
        wr::emit(27, start, end, wr::call(), &out);
    }
    Ok(())
}

pub(super) fn returned(result: &Result<SyscallReturn>) {
    let ret = match result {
        Ok(SyscallReturn::Return(value)) => *value as i64,
        Err(error) => -(error.error() as i64),
        _ => return,
    };
    wr::finish(ret);
}

pub(super) fn control(option: i32, actor: u64, child: u64, delay: u64, ctx: &Context)
    -> Option<Result<SyscallReturn>> {
    match option {
        0x53575000 => {
            wr::reset();
            Some(Ok(SyscallReturn::Return(0)))
        }
        0x53575001 => {
            let queue = ctx.process.children_wait_queue() as *const _ as usize;
            let ok = wr::register(actor as usize, ctx.posix_thread.tid() as u64,
                child, ctx.process.pid() as u64, queue, delay);
            Some(if ok { Ok(SyscallReturn::Return(ostd::cpu::num_cpus() as _)) }
                else { Err(Error::with_message(Errno::EINVAL, "trace actor already registered")) })
        }
        0x53575002 => Some(if wr::dump() { Ok(SyscallReturn::Return(0)) }
            else { Err(Error::new(Errno::EAGAIN)) }),
        _ => None,
    }
}
