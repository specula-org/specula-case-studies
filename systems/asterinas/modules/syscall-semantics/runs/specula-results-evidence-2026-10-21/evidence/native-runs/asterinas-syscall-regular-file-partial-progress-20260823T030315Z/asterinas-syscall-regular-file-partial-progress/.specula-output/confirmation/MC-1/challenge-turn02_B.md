# MC-1 — Challenger notes (Agent B, turn 2)

Goal: remove MC-1 unless it clears both bars. It clears both. Every attack line
below was pursued to a citable conclusion and failed.

## What I verified independently (not taken from A)

### 1. Kernel under test is pristine — checked, and re-checked after my own run

`worktree` HEAD = `2cd6429` (upstream `604948581`). Full `git status --short`:

    M Makefile
    M test/initramfs/Makefile
    M test/initramfs/nix/default.nix
    M test/initramfs/nix/initramfs.nix
    ?? test/initramfs/nix/specula/
    ?? test/initramfs/src/regression/io/specula/

I read every one of those diffs. `Makefile` adds only `ENABLE_SPECULA_TRACE ?=
false` and `CARGO_OSDK_BUILD_ARGS += --init-args="$(SPECULA_INIT)"`; the nix
diffs only thread a userspace package into the initramfs closure. **No kernel
cargo feature, no `ostd`/`kernel` source change.** `git status --short --
kernel ostd` is empty before and after my run. The guest payload
(`test/initramfs/src/regression/io/specula/mc1_repro.c`) is byte-identical to
`repro/test_bugMC-1_partial_read_efault.c` (`diff -q` → identical).

This was my best shot at killing the repro (`ENABLE_SPECULA_TRACE=true` looked
like kernel instrumentation). It is initramfs build wiring only. Attack failed.

### 2. I re-ran the whole reproduction myself, logging to a separate directory

`verify/rerun.sh` (A's driver with `LOG_DIR` repointed so A's logs are
preserved), full rebuild + boot, driver exit code 0:

    ramfs read      : ret=-1 errno=14(Bad address) offset_after=0 visible_prefix=128
    ramfs next read : ret=128 first_byte='A' (... 'A' if it is replayed)
    ext2  read      : ret=-1 errno=14(Bad address) offset_after=0 visible_prefix=128
    ext2  next read : ret=128 first_byte='A'
    MC1_ANOMALIES 6
    MC1_RESULT DIVERGES_FROM_LINUX
    MC-1 REPRODUCED

Byte-for-byte the same as A's run. Artifacts: `verify/rerun.out`,
`verify/asterinas-run.log`, `verify/asterinas-build.log`.

### 3. I re-ran the Linux control myself, on a different filesystem

A's control used tmpfs + a loop disk. I ran the same binary against `/tmp` on
this host, which `stat -f` reports as **ext2/ext3** — an ext-family file, the
closest control to the Asterinas ext2 case:

    read      : ret=128 errno=0(-) offset_after=128 visible_prefix=128
    next read : ret=128 first_byte='Y'
    pread     : ret=128 errno=0(-) visible_prefix=128
    zero-prefix control: ret=-1 errno=14(Bad address) offset_after=0
    MC1_ANOMALIES 0 / MC1_RESULT MATCHES_LINUX

So `ReportedCoversVisibleCopy` is a property Linux actually holds, not a
property invented by the model. This is what closes the `INVARIANT` route.

### 4. Every code citation, read from `git show HEAD:` on the pristine tree

- `ostd/src/mm/io/mod.rs:354-358` — `writer.cursor` is advanced by `copied_len`
  **before** `Err((Error::PageFault, copied_len))` is returned. The user buffer
  is already clobbered at the moment the error is produced.
- `kernel/core/src/error.rs:209-214` — `From<(ostd::Error, usize)>` returns
  `Error::from(ostd_error.0)`; the `usize` is dropped. Verified verbatim.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:557` — `read_fallible(writer)?`
  inside a `Result<()>` function; the count cannot escape.
- `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:241-242` — `?` on
  `page_cache().read(...)` skips `Ok(read_len)`.
- `kernel/core/src/fs/file/inode_handle.rs:287-288` — `?` returns before
  `*offset += len`.
- `kernel/core/src/syscall/read.rs:36-44` — `.map_err` rewrites only
  `EINTR`→`ERESTARTSYS`; everything else propagates, so
  `SyscallReturn::Return(read_len)` at :44 is unreachable on this path.

No safeguard anywhere on the chain. I looked for one specifically.

### 5. The repro triggered the RIGHT bug

CE final state (State 10, `output/MC_hunt_scenario_1_positive_copy_progress_bfs.out`)
for `t1`, read directly:

    pc=Idle  opKind=SharedRead  copyFault=TRUE  copied=Positive
    visibleTotal=1  reportedTotal=0  result=Fault  ofdOffset=0

Maps 1:1 onto the guest output: `result=Fault` → `ret=-1 EFAULT`;
`visibleTotal=1` → `visible_prefix=128`; `reportedTotal=0` → no bytes reported;
`ofdOffset=0` → `offset_after=0`.

Note the CE's second thread `t2` is still `pc="AcquireOffset"`,
`result="Pending"`, `visibleTotal=0` at the violating state — it contributes
nothing to the violation, which is entirely `t1`'s single-threaded read. A's
single-threaded repro is therefore a *simpler* instantiation than the CE, not
an incomplete one. Recording this so the missing concurrency is not later
mistaken for a partial match.

## Attack lines pursued and why each failed

| Attack | Outcome |
|---|---|
| Repro runs on an instrumented kernel (`ENABLE_SPECULA_TRACE=true`) | **Failed.** Flag only selects an initramfs userspace package + `--init-args`. Kernel/ostd diff empty before and after my own run. |
| A's output is a one-off or unverified | **Failed.** I rebuilt and rebooted from scratch; identical output, driver exit 0. |
| The Linux "contract" is asserted, not measured | **Failed.** I measured it myself on an ext-family file: `ret=128`, offset 128, stream continues at 'Y'. |
| `SPEC_REPAIR` — CE needs a step the code cannot take | **Failed.** The code takes exactly that step, at escalation Level 0, twice. |
| `FAULT_MODEL` — the fault is outside the failure model | **Failed.** No fault was injected. `mprotect(PROT_NONE)` is a public syscall; the target's own Assumptions admit "any user copy may complete ... a positive prefix, or all requested bytes and then fault" and "a cooperating thread may mutate or remap user buffer ranges between kernel steps". |
| `INVARIANT` — the invariant over-flags a benign state | **Failed.** Linux satisfies it on the same payload (0 anomalies). Asterinas targets the Linux ABI; the campaign brief names this exact divergence as Priority Question 1. |
| `MASKED` — something downstream repairs the state | **Failed.** I looked for the mask and there is none. The follow-up read proves permanence *and* escalates the harm: the offset never moved, so the 128 already-delivered bytes are handed out a **second** time. A caller that repairs its mapping and retries gets duplicated stream data. |
| Consequence is only a "symptom", no real consumer | **Failed.** The consumer is the userspace process: it gets `-1/EFAULT` where Linux gives `128`, its buffer *is* modified, and its file position is wrong. Secondary: `fs::vfs::notify::on_access` (`read.rs:41-43`) is skipped although data was delivered. |
| Not novel — issue #711 already reports it | **Failed as a removal argument.** I confirmed #711 is still `OPEN` (created 2024-03-23) via `gh issue view`. But the skill's only known-drop pre-filter is *code-review* × already-reported; MC-sourced findings with a real counterexample proceed unfiltered. A already labels it `KNOWN (cite: …/issues/711; fix-status: unfixed)`, which also satisfies the campaign brief's "#711 is mechanism context, never a new finding". Correct handling, not grounds for removal. |

## Reachability checklist (applied by me, not inherited)

1. **Level 0/1 alone?** Level 0. `mmap`, `mprotect`, `open`, `read`, `pread`,
   `lseek` only. No failpoint, no timing assist, no state injection, no kernel
   patch — I verified the pristine tree myself, twice.
2. **Level 2/3 pre-condition justification?** Not applicable; neither used.
3. **Real consumer with a wrong outcome?** Yes — the calling process. See above.
4. **Permanent?** Yes. Nothing re-reads, re-syncs, or rewinds; the replay probe
   demonstrates the state persists into the next syscall.

## Conclusion

Both bars are cleared with evidence I generated independently. I have no citable
objection left. Conceding.

No repair request: all three artifact routes (`SPEC_REPAIR`, `FAULT_MODEL`,
`INVARIANT`) are affirmatively refuted above, so emitting one would be a
fishing expedition the skill explicitly forbids.
