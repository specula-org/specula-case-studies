#!/usr/bin/env python3
"""Apply the MC-3 Level-3 timing hook to the build copy (exact string edits).

Each replacement is asserted to occur exactly once. Idempotence is NOT
assumed; run only on a fresh copy of the instrumented worktree.
"""
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

def edit(rel, old, new):
    p = root / rel
    text = p.read_text()
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"FATAL: {rel}: expected 1 occurrence, found {n} for: {old[:70]!r}")
    p.write_text(text.replace(old, new))
    print(f"patched {rel}")

edit("kernel/core/src/tla_trace.rs",
     "    overflow: bool,\n    records: Vec<Receipt>,\n}",
     "    overflow: bool,\n    records: Vec<Receipt>,\n"
     "    /// MC-3 repro hook: busy-wait iterations at the exFAT write_at\n"
     "    /// release-preparation/acquire-copy window. 0 = disarmed (default).\n"
     "    mc3_iters: u64,\n}")

edit("kernel/core/src/tla_trace.rs",
     "         overflow: false, records: Vec::new() }",
     "         overflow: false, records: Vec::new(), mc3_iters: 0 }")

edit("kernel/core/src/tla_trace.rs",
     "pub(crate) fn control(option: i32, tid: usize, unit: usize, fault: usize) -> Result<usize> {\n"
     "    if option == 0x53504543 {",
     "pub(crate) fn control(option: i32, tid: usize, unit: usize, fault: usize) -> Result<usize> {\n"
     "    if option == 0x53504551 {\n"
     "        // MC-3 repro hook control: arg2=1 arms with arg3 busy-wait\n"
     "        // iterations, arg2=0 disarms. Timing-only; no logic altered.\n"
     "        with(|r| r.mc3_iters = if tid == 1 { unit as u64 } else { 0 });\n"
     "        return Ok(0);\n"
     "    }\n"
     "    if option == 0x53504543 {")

edit("kernel/core/src/tla_trace.rs",
     "pub(crate) fn last_end() -> u64 { with(|r| r.records.last().map(|e| e.end).unwrap_or_else(stamp)).unwrap_or_else(stamp) }",
     "pub(crate) fn last_end() -> u64 { with(|r| r.records.last().map(|e| e.end).unwrap_or_else(stamp)).unwrap_or_else(stamp) }\n"
     "\n"
     "/// MC-3 repro hook: when armed via prctl(0x53504551), busy-wait at the exact\n"
     "/// counterexample window (after ExfatWriteAtReleasePreparation, before\n"
     "/// reacquiring the guard for the copy). No locks are held while spinning;\n"
     "/// only this thread's timing is dilated, the system's logic is unchanged.\n"
     "pub(crate) fn mc3_release_hook() {\n"
     "    let iters = with(|r| r.mc3_iters).unwrap_or(0);\n"
     "    for _ in 0..iters {\n"
     "        core::hint::spin_loop();\n"
     "    }\n"
     "}")

edit("kernel/core/src/syscall/prctl.rs",
     "    if option == 0x53504543 || option == 0x53504544 {",
     "    if option == 0x53504543 || option == 0x53504544 || option == 0x53504551 {")

edit("kernel/core/src/fs/fs_impls/exfat/inode.rs",
     '        crate::tla_trace::event("ExfatWriteAtReleasePreparation", crate::tla_trace::last_end(), [0; 8]);\n'
     "        let specula_start = crate::tla_trace::stamp();",
     '        crate::tla_trace::event("ExfatWriteAtReleasePreparation", crate::tla_trace::last_end(), [0; 8]);\n'
     "        crate::tla_trace::mc3_release_hook();\n"
     "        let specula_start = crate::tla_trace::stamp();")

print("MC-3 hook applied OK")
