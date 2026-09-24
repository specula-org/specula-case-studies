# AST-07: Empty Segment conversion dereferences an unowned first frame

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | External package, finding CR-11 (former catalog alias OS-01), original run ID not recorded, Asterinas pin `4c1fdd1e4` (`v0.18.0-250-g4c1fdd1e4`), verified 2026-08-07 |
| Also seen in | none. The 2026-09-02 ktest re-run at `604948581` is a validation, not a separate Specula run. |
| Syscalls | none (kernel-internal `ostd` API) |
| Upstream | Related only: closed issue [#3165](https://github.com/asterinas/asterinas/issues/3165) and merged PR [#3587](https://github.com/asterinas/asterinas/pull/3587) fix integer wrapping in `Segment::slice`, a different mechanism that left `<=` in place. |
| Fix | Unfixed. No local branch or patch is recorded. The verification package gives a fix direction only. |
| Reproducer | repro/ (ostd ktest, runtime REPRODUCED at `604948581` for the wrong-answer cases, SMP=2; kernel death seen only at `4c1fdd1e4`) |

## Summary

`Segment::slice` accepts an empty range and returns a zero-length `Segment`
that holds no frame reference. The two type-erasure conversions then read the
metadata slot at `range.start` unconditionally. For a slice taken at the end
of a segment, that slot belongs to a frame the segment never owned. The
conversion then returns a wrong answer (for example it accepts typed frames as
untyped memory), or, when the slot was never initialized, makes a virtual call
through garbage. Only kernel code can reach this. No syscall path passes a
caller-controlled empty range.

## Linux contract

Not applicable. This is an internal soundness property of Asterinas's `ostd`
frame API: `Segment<M> -> Segment<dyn AnyFrameMeta> -> Segment<M>` must be the
identity, and a segment must not read the metadata of frames it does not own.
Sibling APIs in the same tree reject empty ranges
(`kernel/libs/aster-util/src/mem_obj_slice.rs::Slice::new`,
`Segment::from_unused`, `alloc_segment_with` with `nframes == 0`). The
promotion audit marks the oracle control as "none".

## Asterinas behavior

Line numbers are at `4c1fdd1e4` and were rechecked as unchanged at `604948581`
(2026-08-25) and on main `29b0f4bcf` (2026-09-02).

- `ostd/src/mm/frame/segment.rs::Segment::slice` (lines 164-188) asserts
  `range.start <= range.end`, so an empty range passes, and its reference-count
  loop runs zero times.
- `ostd/src/mm/frame/segment.rs::<Segment<M> as TryFrom<Segment<dyn AnyFrameMeta>>>::try_from`
  (lines 269-293) and
  `ostd/src/mm/frame/segment.rs::<USegment as TryFrom<Segment<dyn AnyFrameMeta>>>::try_from`
  (lines 302-330) both start with
  `unsafe { Frame::<dyn AnyFrameMeta>::from_raw(seg.range.start) }` and call
  `dyn_meta()` on it. The SAFETY comment ("for each page there would be a
  forgotten handle") is false for an empty segment.
- `ostd/src/mm/frame/mod.rs::Frame::dyn_meta` (lines 154-157) reads the slot's
  `vtable_ptr`. `ostd/src/mm/frame/meta.rs` (lines 540-554) leaves slots of
  never-allocated frames `MaybeUninit::uninit()`.

`slice(&(0..0))` points at the parent's own first frame, which masks the bug.
`slice(&(size..size))` points one frame past the segment, where the harm is.

## Reproduction

There is no userspace reproducer. The reproducer is an `ostd` ktest module
with four tests, each run in its own kernel boot:

| Test | `4c1fdd1e4` (2026-08-07) | `604948581` (2026-09-02, TCG, SMP=2, 8G) |
|---|---|---|
| `cr11_l0_empty_slice_round_trip_matrix` | FAILED: `end_round_trip_ok=false` for n=1 and n=2, controls pass | FAILED, same |
| `cr11_l0_empty_slice_answers_from_a_foreign_frame` | FAILED: `adjacency=obtained`, `round_trip_ok=false`, `accepted_as_usegment=true` | FAILED, same |
| `cr11_l0_empty_slice_at_end_boundary_faults` | kernel died inside `Segment::try_from` (`about_to_call` present, `survived` absent) | FAILED by assertion: `CR11\|fault\|survived\|round_trip_ok=false`. The kernel survived, and QEMU logged zero CPU exceptions |
| `cr11_l0_max_tracked_boundary_probe` | ok, environment probe (`max_paddr=0x8000000`) | ok (`max_paddr=0x280000000`, `reaches_max_paddr=false`) |

`repro/README.md` explains how to install and run the tests.

## Fix and upstream status

- Upstream dedup (2026-09-14): `RELATED_ONLY`, no fix established. #3165 and
  #3587 are about integer wrapping in the same function. A 2026-08-25 GitHub
  search found no report of the empty-segment conversion path.
- Fix direction from verification package §12 (context, not a tested patch):
  reject empty segments at the start of both `try_from` impls
  (`if seg.range.is_empty() { return Err(seg); }`), and optionally tighten
  `Segment::slice` to `range.start < range.end`. The package's tests encode the
  round-trip identity and can serve as regressions.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-07-segment-empty-slice/description.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-07-segment-empty-slice/verification-package.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md` ("AST-07 detail")
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/ast07-driver-summary.txt` and `ast07-ktest-*.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/run-cr11.sh`, `scripts/OSDK.cr11.toml`, `scripts/harness/cr11_repro.rs`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scratch-worktree-tooling.diff`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-07`)

## Caveats

- Kernel-internal only. The historical promotion audit marks "Userspace
  repro" as not applicable and SMP evidence as n/a. An unprivileged syscall
  path was not demonstrated.
- The kernel-death outcome is environment-dependent. It needs the
  one-past-the-end metadata slot to be uninitialized. At `604948581` the
  neighboring slot held a stale but callable vtable, so the kernel survived and
  returned a wrong answer. Do not describe AST-07 as a panic, and do not
  describe it as reliably killing the kernel. Describe it as an unsound read
  whose outcome depends on the neighboring frame's metadata slot.
- The foreign-frame test depends on the per-CPU LIFO frame cache handing back
  the same frame. It self-skips with `adjacency=not-obtained` otherwise, and a
  skipped run must not be counted.
- The `max_paddr` variant (guarded only by a `debug_assert!` in
  `Frame::from_raw`) was never reachable in either environment.
- The original external package's run ID and location were not recorded. The
  catalog copy of its verification package is the only source.
- `4c1fdd1e4` is not an upstream commit. It is the head of a local
  `feat/nix-flake-devenv` branch in `/home/chin39/Documents/asterinas` (8 Nix
  packaging commits on upstream `9388d7d47`, with no change under `ostd/` or
  `kernel/`).
- The embedded driver script in the verification package has a typo that makes
  it fail under bash (`"${TESTS[]}"`). `repro/README.md` describes the one-line
  fix applied to the extracted copy.
