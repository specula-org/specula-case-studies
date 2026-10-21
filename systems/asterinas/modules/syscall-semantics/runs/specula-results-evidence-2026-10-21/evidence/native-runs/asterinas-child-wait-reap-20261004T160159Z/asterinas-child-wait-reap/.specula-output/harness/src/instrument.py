#!/usr/bin/env python3
"""Apply exact, pin-checked source edits without resetting unrelated files."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent / "source"
PIN = "0c60537098f4c2949ad2d382aaf499de72263d76"
copies = {"wr_trace.rs": "ostd/src/wr_trace.rs", "wr_syscall.rs": "kernel/core/src/syscall/wr_syscall.rs",
          "wait_reap_trace.c": "test/initramfs/src/regression/process/wait_reap_trace/wait_reap_trace.c",
          "wait_calibration.c": "test/initramfs/src/regression/process/wait_reap_trace/wait_calibration.c",
          "Makefile": "test/initramfs/src/regression/process/wait_reap_trace/Makefile"}
assert subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip() == PIN
receipt = HERE / "evidence/applied.json"
if receipt.exists():
    old = json.loads(receipt.read_text())
    if all((ROOT / p).exists() and hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h
           for p, h in old["files"].items()):
        if any((HERE / "src" / src).read_bytes() != (ROOT / dst).read_bytes()
               for src, dst in copies.items()):
            raise RuntimeError("installed candidate differs; controller must preserve the old receipt, clean, and apply the reviewed candidate")
        print("Instrumentation already applied at recorded hashes")
        sys.exit(0)
    raise RuntimeError("applied source changed; preserve and review the correction before reapplying")
changes = {}


def edit(path, before, after, count=1):
    text = changes.get(path, (ROOT / path).read_text())
    found = text.count(before)
    if found != count:
        raise RuntimeError(f"{path}: expected {count} matches, found {found}: {before[:100]!r}")
    changes[path] = text.replace(before, after)


def use(path):
    text = changes.get(path, (ROOT / path).read_text())
    pos = text.index("\nuse ")
    changes[path] = text[:pos] + "\nuse ostd::wr_trace as wr;\n" + text[pos:]


edit("ostd/src/lib.rs", "pub mod task;", "pub mod task;\npub mod wr_trace;")
edit("kernel/core/src/syscall/mod.rs", "mod wait4;", "mod wr_syscall;\nmod wait4;")
edit("kernel/core/src/syscall/prctl.rs", "    let prctl_cmd = PrctlCmd::from_args(option, arg2, arg3, arg4, arg5)?;",
     "    if let Some(result) = super::wr_syscall::control(option, arg2, arg3, arg4, ctx) { return result; }\n    let prctl_cmd = PrctlCmd::from_args(option, arg2, arg3, arg4, arg5)?;")

# Keep a wrapper outside the original body's local destructors so the recorded
# ABI result follows WaitStatus destruction, including the ECHILD path.
for name, decl, args, begin in [
    ("wait4", "wait_pid: u64, status_ptr: u64, wait_options: u32, rusage_addr: Vaddr, ctx: &Context",
     "wait_pid, status_ptr, wait_options, rusage_addr, ctx",
     "super::wr_syscall::begin(4, wait_pid, 0, wait_options.bits() as u64, rusage_addr as u64, status_ptr, ctx)?;"),
    ("waitid", "which: u64, upid: u64, infoq_addr: u64, options: u64, _rusage_addr: u64, ctx: &Context",
     "which, upid, infoq_addr, options, _rusage_addr, ctx",
     "super::wr_syscall::begin(247, upid, which, options, _rusage_addr, infoq_addr, ctx)?;")]:
    p = f"kernel/core/src/syscall/{name}.rs"
    use(p)
    edit(p, f"pub(super) fn sys_{name}(", f"pub(super) fn sys_{name}({decl}) -> Result<SyscallReturn> {{\n    let result = sys_{name}_inner({args});\n    super::wr_syscall::returned(&result);\n    result\n}}\n\nfn sys_{name}_inner(")
    edit(p, "    let wait_status =\n        do_wait", f"    {begin}\n    let wait_status =\n        do_wait")
    ret = "    Ok(SyscallReturn::Return(return_pid as _))" if name == "wait4" else "    Ok(SyscallReturn::Return(0))"
    edit(p, ret, "    let wr_start = wr::stamp();\n    drop(wait_status);\n    wr::waiter_event(28, wr_start, &[]);\n" + ret)

p = "kernel/core/src/syscall/wait4.rs"
edit(p, "    let (return_pid, status_code) = (wait_status.pid(), calculate_status_code(&wait_status));",
     "    let wr_start = wr::stamp();\n    let (return_pid, status_code) = (wait_status.pid(), calculate_status_code(&wait_status));\n    wr::waiter_event(25, wr_start, &[status_code as u64, return_pid as u64]);")
edit(p, "        ctx.user_space().write_val(status_ptr as _, &status_code)?;",
     "        let wr_start = wr::stamp();\n        ctx.user_space().write_val(status_ptr as _, &status_code)?;\n        super::wr_syscall::copyout(wr_start, 4, status_ptr, ctx)?;")
p = "kernel/core/src/syscall/waitid.rs"
edit(p, "        let siginfo = {", "        wr::delay_output();\n        let wr_start = wr::stamp();\n        let siginfo = {")
edit(p, "            let uid = wait_status.uid();", "            let uid = wait_status.uid();\n            wr::waiter_event(26, wr_start, &[wr::read_code(), pid as u64, u32::from(uid) as u64]);")
edit(p, "        ctx.user_space().write_val(infoq_addr as usize, &siginfo)?;",
     "        let wr_start = wr::stamp();\n        ctx.user_space().write_val(infoq_addr as usize, &siginfo)?;\n        super::wr_syscall::copyout(wr_start, 247, infoq_addr, ctx)?;")
edit(p, "            let exit_code = process.status().exit_code();", "            let exit_code = process.status().exit_code();\n            wr::save_code(exit_code as u64);")

p = "kernel/core/src/process/wait.rs"
use(p)
edit(p, "                let has_unready_child = match try_wait_children(&child_filter, wait_options, ctx) {\n                    WaitResult::Found(status) => return Some(Ok(Some(status))),",
     "                let has_unready_child = match try_wait_children(&child_filter, wait_options, ctx) {\n                    WaitResult::Found(status) => { wr::decision(10, wr::stamp()); return Some(Ok(Some(status))); },")
edit(p, "                if !has_unready_tracee && !has_unready_child {", "                if !has_unready_tracee && !has_unready_child {\n                    wr::decision(11, wr::stamp());")
edit(p, "                if wait_options.contains(WaitOptions::WNOHANG) {", "                if wait_options.contains(WaitOptions::WNOHANG) {\n                    wr::decision(12, wr::stamp());")
edit(p, "                // wait\n                None", "                wr::decision(13, wr::stamp());\n                None")
edit(p, "    let mut children_lock = ctx.process.children().lock();",
     "    let wr_start = wr::stamp();\n    let mut children_lock = ctx.process.children().lock();\n    wr::waiter_event(2, wr_start, &[]);")
edit(p, "    for child in children_mut.values() {", "    let wr_match_start = wr::stamp();\n    let mut wr_matched = false;\n    for child in children_mut.values() {")
edit(p, "        // We have found at least one child matching `child_filter`.",
     "        wr_matched = true;\n        wr::waiter_event(3, wr_match_start, &[1]);\n        // We have found at least one child matching `child_filter`.")
edit(p, "        if child.status().is_zombie() {\n            let child = child.clone();",
     "        let wr_start = wr::stamp();\n        let wr_zombie = child.status().is_zombie();\n        wr::waiter_event(4, wr_start, &[wr_zombie as u64]);\n        if wr_zombie {\n            let wr_start = wr::stamp();\n            let child = child.clone();\n            wr::waiter_event(5, wr_start, &[child.pid() as u64, wait_options.contains(WaitOptions::WNOWAIT) as u64]);")
edit(p, "            return WaitResult::Found(WaitStatus::Zombie(child));",
     "            let wr_start = wr::stamp();\n            drop(children_lock);\n            wr::waiter_event(9, wr_start, &[]);\n            return WaitResult::Found(WaitStatus::Zombie(child));")
edit(p, "    fallback_result\n}\n\n/// Free zombie", "    if !wr_matched { wr::waiter_event(3, wr_match_start, &[0]); }\n    let wr_start = wr::stamp();\n    drop(children_lock);\n    wr::waiter_event(9, wr_start, &[]);\n    fallback_result\n}\n\n/// Free zombie")
edit(p, "    let child_process = children_lock.remove(&child_pid).unwrap();",
     "    let wr_start = wr::stamp();\n    let child_process = children_lock.remove(&child_pid).unwrap();\n    wr::waiter_event(6, wr_start, &[children_lock.contains_key(&child_pid) as u64]);")
edit(p, "    child_process.status().exit_code()\n}", "    let wr_start = wr::stamp();\n    let code = child_process.status().exit_code();\n    wr::waiter_event(8, wr_start, &[]);\n    code\n}")
p = "kernel/core/src/process/pid_table.rs"
use(p)
edit(p, "            pid_entry.clear_process();\n            pid_entry.clear_thread();",
     "            let wr_start = wr::stamp();\n            pid_entry.clear_process();\n            pid_entry.clear_thread();\n            if pid as u64 == wr::child_pid() { wr::waiter_event(7, wr_start, &[]); }")
p = "kernel/core/src/process/status.rs"
use(p)
edit(p, "        self.is_zombie.store(true, Ordering::Release);",
     "        let wr_start = wr::stamp();\n        self.is_zombie.store(true, Ordering::Release);\n        let wr_end = wr::stamp();\n        if wr::child() { wr::emit(31, wr_start, wr_end, wr::NO_CALL, &[]); }")
edit(p, "        self.exit_code.store(exit_code, Ordering::Relaxed);",
     "        let wr_start = wr::stamp();\n        self.exit_code.store(exit_code, Ordering::Relaxed);\n        let wr_end = wr::stamp();\n        if wr::child() { wr::emit(30, wr_start, wr_end, wr::NO_CALL, &[exit_code as u64]); }")
p = "kernel/core/src/process/signal/pause.rs"
use(p)
edit(p, "        let (waiter, _) = Waiter::new_pair();\n        let cond = || {\n            self.enqueue(waiter.waker());", "        wr::arm_pair();\n        let (waiter, _) = Waiter::new_pair();\n        let cond = || {\n            self.enqueue(waiter.waker());")
edit(p, "        let cancel_cond = || {\n            let has_pending = match reason {", "        let cancel_cond = || {\n            let wr_start = wr::stamp();\n            let has_pending = match reason {")
edit(p, "            Ok(())\n        };\n\n        posix_thread.set_signalled_waker(self.waker(), reason);",
     "            wr::waiter_event(17, wr_start, &[has_pending as u64, timeout.is_some() as u64]);\n            Ok(())\n        };\n\n        posix_thread.set_signalled_waker(self.waker(), reason);")
p = "kernel/core/src/process/posix_thread/mod.rs"
use(p)
edit(p, "        *signalled_waker = Some((waker, reason));", "        let wr_start = wr::stamp();\n        let wr_key = waker.trace_call();\n        *signalled_waker = Some((waker, reason));\n        if wr_key != wr::NO_CALL { wr::waiter_event(15, wr_start, &[]); }")
edit(p, "        *self.signalled_waker.lock() = None;", "        let mut slot = self.signalled_waker.lock();\n        let wr_key = slot.as_ref().map_or(wr::NO_CALL, |(w, _)| w.trace_call());\n        let wr_start = wr::stamp();\n        *slot = None;\n        if wr_key != wr::NO_CALL { wr::waiter_event(23, wr_start, &[]); }")
edit(p, "        if let Some((waker, _)) = &*self.signalled_waker.lock() {\n            waker.wake_up();\n        }",
     "        let wr_start = wr::stamp();\n        let slot = self.signalled_waker.lock();\n        let wr_actor = wr::actor_for_tid(self.tid() as u64);\n        let wr_key = slot.as_ref().map_or(wr::NO_CALL, |(w, _)| w.trace_call());\n        wr::signal_get(wr_start, wr_actor, wr_key);\n        if let Some((waker, _)) = &*slot { waker.wake_up(); }\n        let wr_start = wr::stamp();\n        drop(slot);\n        wr::wake_finish(wr_start, wr_key, 1);")
p = "kernel/core/src/process/process/mod.rs"
use(p)
edit(p, "        self.sig_queues.enqueue(signal);\n\n        for task in self.tasks.lock().as_slice() {",
     "        let wr_start = wr::stamp();\n        self.sig_queues.enqueue(signal);\n        let wr_notify = wr::child() && self.pid() as u64 == wr::parent_pid();\n        if wr_notify { wr::signal_enqueued(wr_start); }\n\n        for task in self.tasks.lock().as_slice() {")
edit(p, "            posix_thread.wake_signalled_waker();\n        }\n    }",
     "            posix_thread.wake_signalled_waker();\n        }\n        if wr_notify { let start = wr::stamp(); wr::emit(35, start, wr::stamp(), wr::NO_CALL, &[]); }\n    }")
p = "kernel/core/src/process/exit.rs"
use(p)
edit(p, "    parent.children_wait_queue().wake_all();\n}", "    parent.children_wait_queue().wake_all();\n    wr::exit_done();\n}")

p = "ostd/src/sync/wait.rs"
edit(p, "use crate::task::{Task, scheduler};", "use crate::{task::{Task, scheduler}, wr_trace as wr};")
edit(p, "pub struct Waker {\n    has_woken: AtomicBool,", "pub struct Waker {\n    trace_call: wr::Call,\n    has_woken: AtomicBool,")
edit(p, "        let waker = Arc::new(Waker {\n            has_woken:", "        let wr_start = wr::stamp();\n        let mut waker = Arc::new(Waker {\n            trace_call: wr::NO_CALL,\n            has_woken:")
edit(p, "        let waiter = Self {\n            waker: waker.clone(),", "        Arc::get_mut(&mut waker).unwrap().trace_call = wr::pair(wr_start);\n        let waiter = Self {\n            waker: waker.clone(),")
edit(p, "impl Waker {\n", "impl Waker {\n    pub fn trace_call(&self) -> wr::Call { self.trace_call }\n")
edit(p, "        if self.has_woken.swap(true, Ordering::Release) {\n            return false;\n        }\n        scheduler::unpark_target(self.task.clone());",
     "        let wr_start = wr::stamp();\n        let old = self.has_woken.swap(true, Ordering::Release);\n        let wr_end = wr::stamp();\n        let traced = wr::child() && self.trace_call != wr::NO_CALL;\n        if traced { wr::emit(36, wr_start, wr_end, self.trace_call, &[old as u64]); }\n        if old { return false; }\n        let wr_start = wr::stamp();\n        scheduler::unpark_target(self.task.clone());\n        if traced { wr::emit(37, wr_start, wr::stamp(), self.trace_call, &[]); }")
edit(p, "        while !self.has_woken.swap(false, Ordering::Acquire) {\n            scheduler::park_current(|| self.has_woken.load(Ordering::Acquire));\n        }",
     "        loop {\n            let wr_start = wr::stamp();\n            let old = self.has_woken.swap(false, Ordering::Acquire);\n            let wr_end = wr::stamp();\n            let traced = self.trace_call != wr::NO_CALL && self.trace_call == wr::call();\n            if traced { wr::emit(18, wr_start, wr_end, self.trace_call, &[old as u64]); }\n            if old { break; }\n            if traced { wr::set_park(true); }\n            scheduler::park_current(|| self.has_woken.load(Ordering::Acquire));\n            if traced { wr::set_park(false); }\n        }")
edit(p, "        let _ = self.has_woken.swap(true, Ordering::Acquire);", "        let wr_start = wr::stamp();\n        let _ = self.has_woken.swap(true, Ordering::Acquire);\n        wr::close(wr_start, self.trace_call);")
edit(p, "        wakers.push_back(waker);\n        self.num_wakers.fetch_add(1, Ordering::Acquire);",
     "        let wr_start = wr::stamp();\n        wakers.push_back(waker);\n        let count = self.num_wakers.fetch_add(1, Ordering::Acquire) + 1;\n        let wr_end = wr::stamp();\n        if wr::queue(self as *const Self as usize) && wr::waiting() {\n            let data = trace_queue(&wakers, count);\n            wr::emit(16, wr_start, wr_end, wr::call(), &data[..2 + data[1] as usize * 2]);\n        }")
start = changes[p].index("    pub fn wake_all(&self) -> usize {")
end = changes[p].index("    fn is_empty", start)
old = changes[p][start:end]
new = '''    pub fn wake_all(&self) -> usize {
        let traced = wr::child() && wr::queue(self as *const Self as usize);
        let start = wr::stamp();
        let count = self.num_wakers.fetch_add(0, Ordering::Release);
        let end = wr::stamp();
        if traced { wr::emit(39, start, end, wr::NO_CALL, &[count as u64]); }
        if count == 0 { return 0; }
        let mut num_woken = 0;
        loop {
            let start = wr::stamp();
            let mut wakers = self.wakers.lock();
            let Some(waker) = wakers.pop_front() else {
                if traced { wr::emit(41, start, wr::stamp(), wr::NO_CALL, &[0]); }
                break;
            };
            let count = self.num_wakers.fetch_sub(1, Ordering::Release) - 1;
            let data = if traced { trace_queue(&wakers, count) } else { [0; 34] };
            drop(wakers);
            if traced { wr::emit(40, start, wr::stamp(), waker.trace_call, &data[..2 + data[1] as usize * 2]); }
            if waker.wake_up() { num_woken += 1; }
            if traced { wr::wake_finish(wr::stamp(), waker.trace_call, 2); }
        }
        num_woken
    }

'''
edit(p, old, new)
edit(p, "impl Default for WaitQueue {", '''fn trace_queue(wakers: &VecDeque<Arc<Waker>>, count: u32) -> [u64; 34] {
    let mut data = [0; 34];
    data[0] = count as u64;
    data[1] = wakers.len().min(16) as u64;
    for (i, waker) in wakers.iter().take(16).enumerate() {
        data[2 + i * 2] = waker.trace_call[0];
        data[3 + i * 2] = waker.trace_call[1];
    }
    data
}

impl Default for WaitQueue {''')

p = "ostd/src/task/scheduler/mod.rs"
edit(p, "pub(crate) fn park_current<F>(has_unparked: F)", "pub(crate) fn park_current<F>(has_unparked: F)")
edit(p, "    let mut current = None;\n    let mut is_first_try = true;", "    let mut current = None;\n    let mut is_first_try = true;\n    let wr_start = crate::wr_trace::stamp();\n    let mut wr_dequeued = false;")
edit(p, "            if has_unparked() {\n                return ReschedAction::DoNothing;\n            }\n            is_first_try = false;",
     "            let observed = has_unparked();\n            let wr_check_end = crate::wr_trace::stamp();\n            if observed { return ReschedAction::DoNothing; }\n            if crate::wr_trace::parking() { crate::wr_trace::emit(19, wr_start, wr_check_end, crate::wr_trace::call(), &[0]); }\n            is_first_try = false;")
edit(p, "            current = local_rq.dequeue_current();",
     "            let wr_dequeue_start = crate::wr_trace::stamp();\n            current = local_rq.dequeue_current();\n            wr_dequeued = true;\n            crate::wr_trace::dequeue_pending(wr_dequeue_start);")
edit(p, "        ReschedAction::Retry\n    });\n}\n\n/// Unblocks a target task.",
     "        ReschedAction::Retry\n    });\n    if crate::wr_trace::parking() {\n        if wr_dequeued { crate::wr_trace::waiter_event(21, crate::wr_trace::stamp(), &[]); }\n        else { crate::wr_trace::waiter_event(19, wr_start, &[1]); }\n    }\n}\n\n/// Unblocks a target task.")
edit(p, "            action = f(rq);\n        });\n\n        match action {",
     "            action = f(rq);\n        });\n        crate::wr_trace::park_released();\n\n        match action {")

edit("test/initramfs/src/regression/process/Makefile", "\tpthread \\\n", "\tpthread \\\n\twait_reap_trace \\\n")

# Check every touched file before the first mutation. This also refuses a
# partially applied version, preserving any edits made by another owner.
for path in changes:
    baseline = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{PIN}:{path}"])
    if (ROOT / path).read_bytes() != baseline:
        raise RuntimeError(f"refusing to overwrite preexisting edits: {path}")
for path, text in changes.items():
    (ROOT / path).write_text(text)
for src, dst in copies.items():
    (ROOT / dst).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HERE / "src" / src, ROOT / dst)
paths = list(changes) + list(copies.values())
receipt.write_text(json.dumps({"pin": PIN, "files": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
                                                      for p in paths}}, indent=2) + "\n")
patch = subprocess.check_output(["git", "-C", str(ROOT), "diff", "--", *changes])
(HERE / "patches/instrumentation.patch").write_bytes(patch)
print(f"Applied instrumentation to {len(paths)} files")
