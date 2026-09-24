# AST-05 extra: 01a MC-3 consequence test (debater payload)

01a run `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`,
finding MC-3, native verdict REPRODUCED at pin
`604948581512d83734377974d4c34adb4530f2d7`.

The catalog's `reports/asterinas-bug-findings-2026-08/AST-05-ramfs-read-past-eof/repro.c`
is byte-identical to this run's `test_bugMC-3_ramfs_read_past_eof.c`, so that
file is not repeated here. The debate turn added a second, materially
different test, `test_bugMC-3_eof_consumer_harm.c`, which the catalog does not
contain. It is packaged here.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-3_eof_consumer_harm.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-3_eof_consumer_harm.c` |
| `test_bugMC-3_eof_consumer_harm.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-3_eof_consumer_harm.sh` (driver: Linux control on the host, then the Asterinas guest) |

## What it tests

- C1: an application reads a short record over pre-filled defaults and keeps
  the defaults for bytes the file does not have. On ramfs the defaults past the
  returned count are silently overwritten.
- C2: `preadv` whose second iovec points at a live, unrelated object. The
  object is clobbered although the return value excludes it.
- C3: whether the extra bytes are zeros or resurrected pre-truncate content.
- C4: negative control on a page-aligned file (capacity equals size), where
  nothing past EOF may be touched.
- C5: the MC counterexample shape verbatim.

Usage: `mc3_consumer <directory-on-the-filesystem-under-test>` (for example
`/tmp` for ramfs, `/ext2` as a control).

## How to run

The driver expects the removed `confirmation/MC-3/worktree` and the Specula
initramfs plumbing (`ENABLE_SPECULA_TRACE`, `SPECULA_INIT`). It also builds
`test_bugMC-3_ramfs_read_past_eof.c` from the same directory as payload A. That
file is byte-identical to the catalog's AST-05 `repro.c`. The same plumbing
patch is packaged with AST-24 and AST-26 as `specula-initramfs-plumbing.patch`.
Without it, compile the file statically and run it from any init on `/tmp`.
On Linux, `gcc -O2` and run it on a tmpfs directory.

## Output

Recorded in the 01a `confirmed-bugs.md`, Entry 3, "What my run added":

| Case | Linux | Asterinas at the pin |
|---|---|---|
| C1 | `timeout_ms=5000 retries=3 name="default-profile"` | `timeout_ms=0 retries=0 name=""`, `WRONG_OUTCOME` |
| C2 | magic and payload intact 60/60 | magic zeroed, payload 0/60, `WRONG_OUTCOME` |
| C3 | untouched | `zeroed=4086 stale_pre_truncate=0` (zeros, not old content) |
| C4 | no clobber | no clobber (control held) |

A fixed kernel must match the Linux column. The debater's notes are in
`.specula-output/confirmation/MC-3/challenge-notes-turn02_B.md` of the 01a run.

## SMP

Sequential. The 01a guest used SMP=2.
