# Candidate v6 amendment D8: OSTD print macro in the recorder dump

Author: lane controller (Claude), 2026-10-10. Trigger: outcome run v6d7-1. All 21 Linux outcome
controls ran pinned to two CPUs and every comparison was `match`. The kernel build then failed:
`error[E0433]: cannot find println in crate` at `ostd/src/wr_trace.rs:254,260`. OSTD defines
`early_println!` (`ostd/src/console/mod.rs:39`, used as `crate::early_println!` in
`ostd/src/arch/x86/mod.rs:36`), not `println!`. The calls are in `dump()`, the recorder's serial
dump, which the outcome path never reaches because the recorder is not armed. They came from
the original v3 harness, and no earlier review compiled the kernel.

Change: `src/wr_trace.rs` (and its frozen copy) replace the two `crate::println!` calls with
`crate::early_println!`, keeping the same format strings and arguments. `apply.sh` copies this
file into `ostd/src/wr_trace.rs`. `candidate-v6/hashes.json` was regenerated. Nothing else
changed.

Pre-review compile check, which produced no evidence: a scratch copy of the instrumented source
with exactly this file content was built under the heavy lock (03:30:59Z to 03:32:17Z,
effective memory 45.71 GiB). The commands matched `run.sh`'s kernel container: locked fetches,
offline OSDK build and seeded lockfile. `osdk build` finished (`Finished release profile`) and
produced `asterinas-osdk-bin.elf` (5,832,296 bytes). The log, script and times are kept as
`harness-fix-2026-10-06/compile-check-d8.*` in the lane directory.

The author does not approve this change.

## Revision after review-v6c (D8-S1)

`review-v6c.md` did not approve D8. Its only finding, D8-S1 (Medium), is that `boot.py` passes
`console=ttyS0` without `earlycon`. The pinned kernel's early cmdline parser
(`kernel/core/comps/cmdline/src/early.rs`) enables the early UART console only for `earlycon`,
so `early_println!` output would be discarded and `WR_STREAM`/`WR_RAW` could never reach the
collector. The flag was missing before D8 as well. Change: `src/boot.py` (and its frozen copy)
now passes `earlycon console=ttyS0 ...`. Outcome mode does not dump the recorder, so this only
affects grouped-path transport. Its early boot messages are confined to the guest serial log
and are excluded from outcome JSON. `candidate-v6/hashes.json` was regenerated. The author does
not approve this change.

Correction after review-v6d finding D8-S2 (Low): the sentence above saying `earlycon` "only
affects grouped-path transport" is wrong. The pinned kernel also registers the ordinary UART
console (`ttyS0`) through the same serial port, so `earlycon` enables guest serial transport in
both modes, including the `WR_OUTCOME_*`, `WR_GUEST_NPROC` and completion lines that outcome mode
needs. The recorder macro substitution affects only grouped dumping. Outcome fixture semantics,
record schemas and comparisons are unchanged.
