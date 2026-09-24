# CR-11 — Standalone Verification Package

> **LOCAL VERIFICATION ONLY.** This document is for internal verification on your own
> hosts. It is **not** an upstream report and contains no submission-ready text. Do not
> file it, or any part of it, to the asterinas tracker or any public channel.

**Claim:** `Segment::slice` accepts `range.start == range.end` and returns a zero-length
`Segment` that holds no reference count. The two type-erasure conversions then
unconditionally dereference `range.start`, reading frame metadata the segment does not
own. At the end boundary this reads a frame that was never allocated, and the resulting
virtual call **kills the kernel** — no panic, no unwind, no recovery.

| | |
|---|---|
| **Target** | `asterinas/asterinas`, worktree HEAD `4c1fdd1e4` (`v0.18.0-250-g4c1fdd1e4`) |
| **Original verdict** | `REPRODUCED` (consensus) |
| **Novelty** | **NEW** — no upstream report for this mechanism as of 2026-08-07 |
| **Escalation level** | **0** — no `unsafe`, no private access, code under test unmodified |
| **Severity** | Medium as filed; the hard-fault case is kernel death |
| **Arch dependence** | None — pure `ostd::mm` logic, not arch-specific |

At the time of investigation `upstream/main` was 29 commits ahead of this worktree and
**no commit in that range touches `ostd/src/mm/frame/segment.rs`** — the code below was
byte-identical to upstream `main`.

> This document is fully self-contained. The complete harness and driver are embedded in
> §6 and §7. §10 lists the criteria that would **falsify** the claim.

---

## 1. The defect

### 1.1 `Segment::slice` admits an empty result — `ostd/src/mm/frame/segment.rs:164-188`

```rust
pub fn slice(&self, range: &Range<usize>) -> Self {
    assert!(range.start.is_multiple_of(PAGE_SIZE) && range.end.is_multiple_of(PAGE_SIZE), ...);
    assert!(range.start <= range.end && range.end <= self.size(), ...);   // <= , not <

    let start = self.range.start + range.start;
    let end   = self.range.start + range.end;

    for paddr in (start..end).step_by(PAGE_SIZE) {   // 0 iterations when start == end
        unsafe { inc_frame_ref_count(paddr) };
    }
    Self { range: start..end, _marker: PhantomData }
}
```

`range.start == range.end` passes both assertions. The result is
`Segment { range: start..start }` and **the reference-count loop runs zero times** — the
returned handle owns nothing.

Two offsets matter:

| call | resulting `range.start` | what lives there |
|---|---|---|
| `seg.slice(&(0..0))` | `seg.paddr()` | a frame the **parent** owns (the slice does not) |
| `seg.slice(&(size..size))` | `seg.end_paddr()` | **one past** `seg` — never owned by it |

### 1.2 The conversions dereference `range.start` unconditionally

`segment.rs:269-293` (`TryFrom<Segment<dyn AnyFrameMeta>> for Segment<M>`) and
`segment.rs:302-330` (`… for USegment`) both open with:

```rust
// SAFETY: for each page there would be a forgotten handle
// when creating the `Segment` object.
let first_frame = unsafe { Frame::<dyn AnyFrameMeta>::from_raw(seg.range.start) };
let first_frame = ManuallyDrop::new(first_frame);
if !first_frame.dyn_meta().is_untyped() { ... }
```

**For an empty segment that SAFETY premise is false**: there is no forgotten handle at
`range.start`. `dyn_meta()` (`ostd/src/mm/frame/mod.rs:154-157`) then reads the
`vtable_ptr` of a `MetaSlot` belonging to some other frame — or to no live frame at all —
and the type check dispatches a **virtual call through that pointer**.

### 1.3 Three flavours, increasing severity

| # | `range.start` lands on | consequence |
|---|---|---|
| 1 | the parent's own first frame (`slice(&(0..0))`) | answer happens to be right — **masked** |
| 2 | a frame owned by someone else | deterministic **wrong answer** returned to the caller |
| 3 | a frame never allocated since boot | `vtable_ptr` never written → **kernel death** |

Flavour 3's slot is left `MaybeUninit::uninit()` by `ostd/src/mm/frame/meta.rs:540-554`.
Note the masking in flavour 1 exists only at the **start** boundary; it is absent at the
end boundary, which is where the harm lands.

### 1.4 Empty segments are inert everywhere else

`Drop` (`segment.rs:46-54`) and `Iterator::next` (`segment.rs:245-261`) iterate `range`
and are no-ops when empty. `HasVmReaderWriter` (`ostd/src/mm/frame/untyped.rs:78-96`)
builds a zero-byte reader/writer. **The conversion paths are the only unsound consumers.**

### 1.5 No safeguard fires

- `alloc_segment_with`'s `nframes == 0` rejection and `Segment::from_unused`'s
  `assert!(range.start < range.end)` guard **construction**, not `slice`.
- `Split::split` (`0 < offset < size`) cannot produce an empty half — but `slice` can.
- `Frame::from_raw`'s `debug_assert!(paddr < max_paddr())` (`frame/mod.rs:207`) covers
  only flavour 3's max-boundary variant, which §8's probe shows the allocator cannot reach
  in this environment. Flavours 1 and 2 sail past it.

**Static checks:**

```sh
sed -n '164,188p' ostd/src/mm/frame/segment.rs     # expect `range.start <= range.end`
sed -n '269,293p' ostd/src/mm/frame/segment.rs     # expect unconditional from_raw(seg.range.start)
sed -n '302,330p' ostd/src/mm/frame/segment.rs     # same in the USegment impl
```

### 1.6 A sibling implementation in the same tree rejects this

`kernel/libs/aster-util/src/mem_obj_slice.rs` does the same "slice a memory object by an
offset range" job and its `Slice::new` **rejects empty ranges** ("The function panics if
the range is empty…"). So do `Segment::from_unused` ("It panics if the range is empty"),
`alloc_segment_with` (`InvalidArgs` on `nframes == 0`), and `Split::split`.
`Segment::slice` is the odd one out.

---

## 2. Prerequisites

- x86_64 Linux host, QEMU with the ostd ktest setup
- Rust toolchain per the asterinas checkout; `nix` optional (driver uses `nix develop`
  when present, otherwise runs commands directly)
- An asterinas checkout. For an exact replay use `4c1fdd1e4`; to test current status use
  `main`.
- Time: OSDK build up to 2400 s, then four QEMU boots (one per ktest), 2400 s each max.

---

## 3. How to run

```sh
mkdir -p cr11 && cd cr11
# save the two files from §6 and §7 here, then:
chmod +x test_bugCR-11_empty_slice_conversion.sh
./test_bugCR-11_empty_slice_conversion.sh /path/to/asterinas
```

The driver installs the ktest at `<worktree>/ostd/src/mm/frame/cr11_repro.rs`, registers
`#[cfg(ktest)] pub(crate) mod cr11_repro;` in `ostd/src/mm/frame/mod.rs` (idempotent),
builds a worktree-local OSDK, and runs the four tests **each in its own kernel boot** so a
kernel death in one does not hide the others.

> **The OSDK must be built from the worktree under test.** It bakes `CARGO_MANIFEST_DIR`
> in at its own compile time and derives the `ostd` path dependency from it
> (`osdk/src/util.rs:20`, `base_crate/mod.rs:270`), so a binary from another checkout
> would silently test *that* checkout.

---

## 4. Expected result — how to read it

Two of the four tests **fail**, and one **kills the kernel**. That is the positive result.

| test | expected outcome |
|---|---|
| `cr11_l0_empty_slice_round_trip_matrix` | **FAILED** — `end_round_trip_ok=false` at n=1 and n=2; controls pass |
| `cr11_l0_empty_slice_answers_from_a_foreign_frame` | **FAILED** — `round_trip_ok=false`, `accepted_as_usegment=true`; controls pass |
| `cr11_l0_empty_slice_at_end_boundary_faults` | **kernel dies** inside `Segment::try_from` — no panic message, no `test result:` line |
| `cr11_l0_max_tracked_boundary_probe` | **ok** — environment probe only |

> The third test produces neither a panic nor a test result, because the kernel is gone.
> The driver detects this structurally: `CR11|fault|about_to_call` present **and**
> `CR11|fault|survived` absent. It prints
> `KERNEL DIED inside Segment::try_from` and sets a non-zero exit. **A missing completion
> marker after `about_to_call` IS the finding**, not a harness malfunction.

---

## 5. Observed evidence (original run, 2026-08-07)

### 5.1 Round-trip matrix — the identity is violated only at the end boundary

```
CR11|matrix|n=1|base=0x6021a000|end=0x6021b000
CR11|probe|empty@start|enter|range=[0x6021a000,0x6021a000)|size=0
CR11|probe|empty@start|returned|ok=true            <- flavour 1: masked, answer right
CR11|probe|empty@end|enter|range=[0x6021b000,0x6021b000)|size=0
CR11|probe|empty@end|returned|ok=false             <- WRONG: identity broken
CR11|probe|control|enter|range=[0x6021a000,0x6021b000)|size=4096
CR11|probe|control|returned|ok=true                <- control passes
CR11|matrix|n=1|start_round_trip_ok=true|end_round_trip_ok=false|control_ok=true
CR11|matrix|n=2|... |start_round_trip_ok=true|end_round_trip_ok=false|control_ok=true
CR11|matrix|FAILURE|n=1|case=empty@end
CR11|matrix|FAILURE|n=2|case=empty@end
```

`Segment<M> -> Segment<dyn AnyFrameMeta> -> Segment<M>` must be the identity: the erasure
is infallible and the recovery only rejects a *different* metadata type. It returned
`Err` anyway — decided by a frame outside the segment.

### 5.2 Foreign-frame case — deterministic wrong answers, both directions

```
CR11|foreign|typed=[0x6013e000,0x6013f000)|want_neighbour=0x6013f000|got=0x6013f000
CR11|foreign|adjacency=obtained
CR11|foreign|empty_slice=[0x6013f000,0x6013f000)|size=0
CR11|foreign|round_trip_ok=false               <- must be true
CR11|foreign|accepted_as_usegment=true         <- must be FALSE: typed frames accepted as untyped
CR11|foreign|control_round_trip_ok=true|control_accepted_as_usegment=false   <- controls correct
```

`accepted_as_usegment=true` is the serious half: an empty slice carved from a segment of
**typed** frames was accepted as an **untyped-memory** handle, because the decision was
made by a neighbouring frame the slice does not own. The test *verifies* it re-acquired
the same physical frame rather than assuming it (`adjacency=obtained`).

### 5.3 Hard fault — kernel death

```
CR11|fault|segment=[0x60220000,0x60223000)|past_the_end=0x60223000
CR11|fault|from_in_use=0x60223000|Err(Unused)          <- ostd itself says: not in use
CR11|fault|about_to_call|Segment::try_from
                                                        <- no 'survived' line: kernel gone
--- hard-fault check ---
KERNEL DIED inside Segment::try_from: 'about_to_call' present, 'survived' absent
```

The contrast is the point: ostd's **checked** public accessor `Frame::from_in_use` reports
that frame as `Err(Unused)`. The same address reached through `slice` + conversion is read
with **no check at all**.

### 5.4 Environment probe

```
CR11|maxprobe|max_paddr=0x8000000
CR11|maxprobe|allocated=1024|highest_end=0x60630000|reaches_max_paddr=false
```

The allocator cannot hand out a segment ending at `max_paddr()` here, so flavour 3's
`debug_assert`-guarded variant is unreachable in this environment — which is why flavours
1 and 2 matter, and why the fault above is the *uninitialised-slot* variant.

### 5.5 Test-runner lines

```
test result: FAILED. 0 passed; 1 failed; 205 filtered out.     (matrix)
test result: FAILED. 0 passed; 1 failed; 205 filtered out.     (foreign frame)
                                                                (fault test: no result line)
test result: ok. 1 passed; 0 failed; 205 filtered out.          (max probe)
```

---

## 6. Harness — `test_bugCR-11_empty_slice_conversion.rs`

Save verbatim next to the driver.

```rust
// SPDX-License-Identifier: MPL-2.0

//! Specula CR-11 reproduction.
//!
//! Finding: `Segment::slice` (ostd/src/mm/frame/segment.rs:164-188) accepts
//! `range.start == range.end` and returns a zero-length `Segment` that holds no
//! reference count at all. The two type-erasure conversions
//! (`TryFrom<Segment<dyn AnyFrameMeta>>` for `Segment<M>` at segment.rs:269-293
//! and for `USegment` at segment.rs:302-330) then open with an unconditional
//!
//! ```ignore
//! // SAFETY: for each page there would be a forgotten handle
//! // when creating the `Segment` object.
//! let first_frame = unsafe { Frame::<dyn AnyFrameMeta>::from_raw(seg.range.start) };
//! let first_frame = ManuallyDrop::new(first_frame);
//! if !(first_frame.dyn_meta() as &dyn core::any::Any).is::<M>() { ... }
//! ```
//!
//! For an empty segment that SAFETY premise is false: there is no forgotten
//! handle at `range.start`. `dyn_meta()` (frame/mod.rs:154-157) then reads the
//! `vtable_ptr` of a `MetaSlot` that belongs to some other frame — or to no live
//! frame at all — and `is::<M>()` dispatches a virtual call through it.
//!
//! Every test below uses only safe, public `ostd::mm` API: no `unsafe`, no
//! private field access, no modification of the code under test. Escalation
//! level 0 throughout.
//!
//!  * `cr11_l0_empty_slice_round_trip_matrix` — the invariant that must hold for
//!    every `Segment<M>` value: `Segment<M> -> Segment<dyn AnyFrameMeta> ->
//!    Segment<M>` is the identity (the impl only returns `Err` "if the usage of
//!    the page is not the same as the expected usage", and here it is, by
//!    construction). Checked at both zero-length offsets, with a non-empty slice
//!    of the same segment as the positive control.
//!
//!  * `cr11_l0_empty_slice_answers_from_a_foreign_frame` — the deterministic
//!    wrong answer. The frame one past the end of a *typed* segment is released
//!    and immediately re-acquired as an *untyped* segment (the OSDK frame
//!    allocator caches single frames per-CPU LIFO,
//!    osdk/deps/frame-allocator/src/cache.rs:49-66, so the same physical frame
//!    comes back; the test verifies this rather than assuming it). Both
//!    conversions then answer from a frame owned by somebody else.
//!
//!  * `cr11_l0_empty_slice_at_end_boundary_faults` — the hard failure. Same
//!    shape, but the frame past the end has never been allocated since boot, so
//!    its `vtable_ptr` was never written (frame/meta.rs:540-554 leaves it
//!    `MaybeUninit::uninit()`). The virtual call kills the kernel. The test
//!    first shows, through the *checked* public accessor `Frame::from_in_use`,
//!    that ostd itself reports that frame as not in use.
//!
//!  * `cr11_l0_max_tracked_boundary_probe` — reports whether the third flavour
//!    (`range.start == max_paddr()`, guarded only by `Frame::from_raw`'s
//!    `debug_assert!(paddr < max_paddr())` at frame/mod.rs:207) is reachable
//!    through the frame allocator in this environment.
//!
//! Output lines are prefixed `CR11|` so the driver script can grep them.

use super::{Frame, Segment, meta::AnyFrameMeta};
use crate::{
    impl_frame_meta_for,
    mm::{FrameAllocOptions, HasPaddrRange, PAGE_SIZE, Split, USegment},
    prelude::*,
};

/// Typed metadata: `is_untyped()` is `false` and the `TypeId` is unique to it.
#[derive(Debug, Default)]
struct Cr11TypedMeta;
impl_frame_meta_for!(Cr11TypedMeta);

/// `Segment<M> -> Segment<dyn AnyFrameMeta> -> Segment<M>` must be the identity.
///
/// The erasure is infallible (`From`), and the recovery only rejects a segment
/// whose frames are of a different metadata type. Feeding it a segment that was
/// erased from `Segment<Cr11TypedMeta>` a line earlier can only fail if the
/// recovery looks at a frame that is not in the segment.
fn survives_round_trip(seg: Segment<Cr11TypedMeta>) -> bool {
    let erased: Segment<dyn AnyFrameMeta> = seg.into();
    Segment::<Cr11TypedMeta>::try_from(erased).is_ok()
}

/// Same round trip, with a marker printed on each side of the conversion so that
/// a kernel death inside `try_from` is attributable to that exact call.
fn survives_round_trip_traced(label: &str, seg: Segment<Cr11TypedMeta>) -> bool {
    println!(
        "CR11|probe|{}|enter|range=[{:#x},{:#x})|size={}",
        label,
        seg.paddr(),
        seg.end_paddr(),
        seg.size()
    );
    let erased: Segment<dyn AnyFrameMeta> = seg.into();
    println!("CR11|probe|{}|calling Segment::try_from", label);
    let ok = Segment::<Cr11TypedMeta>::try_from(erased).is_ok();
    println!("CR11|probe|{}|returned|ok={}", label, ok);
    ok
}

/// An empty segment carved out of a *typed* segment must not be accepted as an
/// untyped-memory handle.
fn accepted_as_untyped(seg: Segment<Cr11TypedMeta>) -> bool {
    let erased: Segment<dyn AnyFrameMeta> = seg.into();
    USegment::try_from(erased).is_ok()
}

#[ktest]
fn cr11_l0_empty_slice_round_trip_matrix() {
    let mut failures: Vec<(usize, &'static str)> = Vec::new();

    // Sizes 1 and 2. Size 3 is exercised separately by
    // `cr11_l0_empty_slice_at_end_boundary_faults`, because there the same
    // conversion takes the kernel down and no later assertion could run.
    for nframes in 1..=2usize {
        let seg = FrameAllocOptions::new()
            .alloc_segment_with(nframes, |_| Cr11TypedMeta)
            .expect("failed to allocate the segment");
        let size = seg.size();
        println!(
            "CR11|matrix|n={}|base={:#x}|end={:#x}",
            nframes,
            seg.paddr(),
            seg.end_paddr()
        );

        // Zero-length slice at the start boundary: `range.start` is the
        // segment's own first frame, which the *parent* still owns.
        let at_start = seg.slice(&(0..0));
        assert_eq!(at_start.size(), 0, "slice(&(0..0)) is not empty");
        assert_eq!(at_start.paddr(), seg.paddr());
        let start_ok = survives_round_trip_traced("empty@start", at_start);

        // Zero-length slice at the end boundary: `range.start` is one frame
        // past the segment, which the segment never owned.
        let at_end = seg.slice(&(size..size));
        assert_eq!(at_end.size(), 0, "slice(&(size..size)) is not empty");
        assert_eq!(at_end.paddr(), seg.end_paddr());
        let end_ok = survives_round_trip_traced("empty@end", at_end);

        // Positive control: a non-empty slice of the same segment.
        let control = seg.slice(&(0..size));
        let control_ok = survives_round_trip_traced("control", control);

        println!(
            "CR11|matrix|n={}|start_round_trip_ok={}|end_round_trip_ok={}|control_ok={}",
            nframes, start_ok, end_ok, control_ok
        );

        if !control_ok {
            failures.push((nframes, "control"));
        }
        if !start_ok {
            failures.push((nframes, "empty@start"));
        }
        if !end_ok {
            failures.push((nframes, "empty@end"));
        }
    }

    for (nframes, which) in failures.iter() {
        println!("CR11|matrix|FAILURE|n={}|case={}", nframes, which);
    }
    assert!(
        failures.is_empty(),
        "Segment<M> -> Segment<dyn AnyFrameMeta> -> Segment<M> is not the identity for a \
         zero-length slice: the conversion answers from a frame outside the segment"
    );
}

#[ktest]
fn cr11_l0_empty_slice_answers_from_a_foreign_frame() {
    // Two contiguous TYPED frames, then keep only the first one.
    let two = FrameAllocOptions::new()
        .alloc_segment_with(2, |_| Cr11TypedMeta)
        .expect("failed to allocate two frames");
    let (typed, tail) = two.split(PAGE_SIZE);
    let neighbour: Paddr = tail.paddr();
    assert_eq!(neighbour, typed.end_paddr());

    // Release the frame one past `typed`. Nothing `typed` owns is touched.
    drop(tail);

    // Re-acquire that frame as UNTYPED memory through the normal allocation
    // path. Whether the allocator hands back the very same frame is checked,
    // never assumed.
    let foreign = FrameAllocOptions::new()
        .alloc_segment(1)
        .expect("failed to re-acquire the neighbouring frame");
    println!(
        "CR11|foreign|typed=[{:#x},{:#x})|want_neighbour={:#x}|got={:#x}",
        typed.paddr(),
        typed.end_paddr(),
        neighbour,
        foreign.paddr()
    );
    if foreign.paddr() != neighbour {
        println!("CR11|foreign|adjacency=not-obtained|skipping");
        return;
    }
    println!("CR11|foreign|adjacency=obtained");

    // A zero-length slice at `typed`'s end boundary. `slice` accepts it, takes
    // no reference count, and points `range.start` at `foreign`'s frame.
    let empty_a = typed.slice(&(PAGE_SIZE..PAGE_SIZE));
    let empty_b = typed.slice(&(PAGE_SIZE..PAGE_SIZE));
    assert_eq!(empty_a.size(), 0);
    assert_eq!(empty_a.paddr(), neighbour);
    println!(
        "CR11|foreign|empty_slice=[{:#x},{:#x})|size={}",
        empty_a.paddr(),
        empty_a.end_paddr(),
        empty_a.size()
    );

    // Direction 1: the round trip that must be the identity.
    let round_trip_ok = survives_round_trip(empty_a);
    println!("CR11|foreign|round_trip_ok={}", round_trip_ok);

    // Direction 2: an empty slice of a segment of TYPED frames must never be
    // accepted as an untyped-memory handle.
    let untyped_ok = accepted_as_untyped(empty_b);
    println!("CR11|foreign|accepted_as_usegment={}", untyped_ok);

    // Positive control: the same two conversions on a non-empty slice of
    // `typed`, which does own its frame.
    let control_round_trip = survives_round_trip(typed.slice(&(0..PAGE_SIZE)));
    let control_untyped = accepted_as_untyped(typed.slice(&(0..PAGE_SIZE)));
    println!(
        "CR11|foreign|control_round_trip_ok={}|control_accepted_as_usegment={}",
        control_round_trip, control_untyped
    );

    assert!(
        control_round_trip,
        "control: a non-empty typed segment must survive the round trip"
    );
    assert!(
        !control_untyped,
        "control: a non-empty typed segment must not convert to USegment"
    );

    assert!(
        round_trip_ok && !untyped_ok,
        "the empty slice's conversions were decided by frame {:#x}, which the slice does not own: \
         round_trip_ok={} (must be true), accepted_as_usegment={} (must be false)",
        neighbour,
        round_trip_ok,
        untyped_ok
    );
}

#[ktest]
fn cr11_l0_empty_slice_at_end_boundary_faults() {
    let seg = FrameAllocOptions::new()
        .alloc_segment_with(3, |_| Cr11TypedMeta)
        .expect("failed to allocate three frames");
    let size = seg.size();
    let past_the_end = seg.end_paddr();
    println!(
        "CR11|fault|segment=[{:#x},{:#x})|past_the_end={:#x}",
        seg.paddr(),
        past_the_end,
        past_the_end
    );

    // ostd's *checked* public accessor for a frame at a raw physical address
    // validates the slot's state before handing anything back
    // (frame/meta.rs:206-220, 265-300). Ask it about the very frame the
    // conversion is about to read.
    match Frame::<dyn AnyFrameMeta>::from_in_use(past_the_end) {
        Ok(_) => println!("CR11|fault|from_in_use={:#x}|Ok(in use)", past_the_end),
        Err(e) => println!("CR11|fault|from_in_use={:#x}|Err({:?})", past_the_end, e),
    }

    // The same address, reached through `slice` + a conversion, is read with no
    // check at all.
    let empty = seg.slice(&(size..size));
    assert_eq!(empty.size(), 0);
    assert_eq!(empty.paddr(), past_the_end);
    let erased: Segment<dyn AnyFrameMeta> = empty.into();

    println!(
        "CR11|fault|about_to_call|Segment::try_from on the empty slice at {:#x}",
        past_the_end
    );
    let ok = Segment::<Cr11TypedMeta>::try_from(erased).is_ok();

    // Reaching this line at all means the kernel survived the read.
    println!("CR11|fault|survived|round_trip_ok={}", ok);
    assert!(
        ok,
        "Segment<M> -> Segment<dyn AnyFrameMeta> -> Segment<M> is not the identity for the \
         zero-length slice at the end boundary"
    );
}

#[ktest]
fn cr11_l0_max_tracked_boundary_probe() {
    // `Frame::from_raw` requires `paddr < max_paddr()` (frame/mod.rs:207), and
    // the frame metadata array holds exactly `max_paddr / PAGE_SIZE` slots
    // (frame/meta.rs:476, 540-554). `Segment::from_unused` deliberately allows
    // `range.end == max_paddr()` (commit 14dc4752f "Don't panic when allocating
    // the last page"), so a segment ending at the top of tracked memory is a
    // legal value, and `slice(&(size..size))` on it would put `max_paddr()`
    // into `range.start`. This probe reports whether the frame allocator can
    // actually hand out such a segment here.
    let max = super::max_paddr();
    println!("CR11|maxprobe|max_paddr={:#x}", max);

    let mut kept: Vec<Segment<Cr11TypedMeta>> = Vec::new();
    let mut highest: Paddr = 0;
    for _ in 0..1024 {
        match FrameAllocOptions::new().alloc_segment_with(1, |_| Cr11TypedMeta) {
            Ok(seg) => {
                highest = highest.max(seg.end_paddr());
                kept.push(seg);
            }
            Err(_) => break,
        }
    }
    println!(
        "CR11|maxprobe|allocated={}|highest_end={:#x}|reaches_max_paddr={}",
        kept.len(),
        highest,
        highest == max
    );
    drop(kept);
}
```

---

## 7. Driver — `test_bugCR-11_empty_slice_conversion.sh`

Save verbatim next to the harness, then `chmod +x`.

```bash
#!/usr/bin/env bash
# Reproduction driver for finding CR-11:
#   "Empty `Segment::slice` can reach conversions that assume a first frame"
#
# What it does
#   1. Installs the ktest module into the Asterinas worktree (idempotent).
#   2. Boots ostd's ktest kernel under QEMU and runs the three `cr11_repro`
#      tests, each in its own kernel boot so a panic in one does not hide the
#      others.
#   3. Reports the CR11| measurement lines and the pass/fail result.
#
# Escalation level: 0 for all three tests — safe, public `ostd::mm` API only
# (`FrameAllocOptions`, `Segment::slice`, `Split::split`, `From`/`TryFrom`).
# No source under test is modified; the only edit to the worktree is
# registering the new `#[cfg(ktest)]` module in ostd/src/mm/frame/mod.rs.
#
# Usage: test_bugCR-11_empty_slice_conversion.sh [worktree] [osdk-binary]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="${1:-$HERE/../confirmation/CR-11/worktree}"
WORKTREE="$(cd "$WORKTREE" && pwd)"
# The OSDK bakes `CARGO_MANIFEST_DIR` in at its own compile time and derives the
# `ostd` path dependency from it (osdk/src/util.rs:20, base_crate/mod.rs:270), so
# a binary built from another checkout would silently test *that* checkout's
# ostd. The OSDK must be built from this worktree.
OSDK_BIN="${2:-$WORKTREE/osdk/target/debug/cargo-osdk}"
LOG="$HERE/test_bugCR-11_empty_slice_conversion.log"
BUILD_TIMEOUT_SECONDS="${BUILD_TIMEOUT_SECONDS:-2400}"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-2400}"

in_dev_shell() {
    local directory="$1" limit="$2"
    shift 2
    if command -v nix >/dev/null 2>&1; then
        (cd "$directory" && timeout "$limit" nix develop "$WORKTREE" \
            --accept-flake-config --command "$@")
    else
        (cd "$directory" && timeout "$limit" "$@")
    fi
}

install_sources() {
    cp "$HERE/test_bugCR-11_empty_slice_conversion.rs" \
       "$WORKTREE/ostd/src/mm/frame/cr11_repro.rs"

    python3 - "$WORKTREE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

mod = root / "ostd/src/mm/frame/mod.rs"
text = mod.read_text()
if "mod cr11_repro;" not in text:
    anchor = "#[cfg(ktest)]\nmod test;"
    assert anchor in text, "ostd/src/mm/frame/mod.rs is missing the ktest module block"
    text = text.replace(
        anchor, "#[cfg(ktest)]\npub(crate) mod cr11_repro;\n" + anchor, 1
    )
    mod.write_text(text)
PY
}

install_sources

if [[ ! -x "$OSDK_BIN" ]]; then
    echo "Building the worktree-local OSDK ..."
    in_dev_shell "$WORKTREE" "$BUILD_TIMEOUT_SECONDS" \
        env OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml
fi
[[ -x "$OSDK_BIN" ]] || { echo "no OSDK binary at $OSDK_BIN" >&2; exit 2; }

# The ktest whitelist matches whole path *suffixes*, so each test has to be
# named in full; a bare module name matches nothing.
TESTS=(
    cr11_repro::cr11_l0_empty_slice_round_trip_matrix
    cr11_repro::cr11_l0_empty_slice_answers_from_a_foreign_frame
    cr11_repro::cr11_l0_empty_slice_at_end_boundary_faults
    cr11_repro::cr11_l0_max_tracked_boundary_probe
)

echo "Running the CR-11 reproduction ..."
: >"$LOG"
status=0
for t in "${TESTS[]}"; do
    echo "=================== $t ===================" >>"$LOG"
    set +e
    in_dev_shell "$WORKTREE/ostd" "$TEST_TIMEOUT_SECONDS" \
        env "$OSDK_BIN" osdk test "$t" --target-arch x86_64 \
        >>"$LOG" 2>&1
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || status=$rc
done

echo "--- CR-11 measurements ---"
# Not anchored at column 0: the ktest runner leaves the "test <name> ..." prefix
# on the same line as a test's first `println!`.
grep -aoE 'CR11\|[^ ]*' "$LOG" || echo "(no CR11| lines: the tests did not reach their measurements)"
echo "--- test result ---"
grep -aE 'test result:|panicked|FAILED|\[ktest runner\]' "$LOG" | tail -20 || true

# `cr11_l0_empty_slice_at_end_boundary_faults` takes the kernel down inside the
# conversion, so it produces neither a panic message nor a "test result:" line.
# A missing completion marker after the "about_to_call" marker IS the finding.
echo "--- hard-fault check ---"
if grep -aq 'CR11|fault|about_to_call' "$LOG"; then
    if grep -aq 'CR11|fault|survived' "$LOG"; then
        echo "kernel survived the read (see CR11|fault|survived above)"
    else
        echo "KERNEL DIED inside Segment::try_from: 'about_to_call' present, 'survived' absent"
        status=1
    fi
else
    echo "(the faulting test never reached its conversion)"
fi
echo "Full log: $LOG (exit=$status)"
exit "$status"
```

> The default `WORKTREE` points at the original Specula layout. Always pass your own
> checkout path as the first argument.

---

## 8. Novelty check — re-run this, it is time-sensitive

Searched the upstream tracker (`gh search issues|prs --repo asterinas/asterinas`) on
**2026-08-07** for: "Segment slice", "empty segment", "zero-length segment",
"Frame::from_raw", "from_raw segment", "USegment try_from", "empty slice", plus a 30-item
sweep of segment-related PRs including merged and closed ones.

Two same-site hits, both a **different mechanism**:

- Issue **#3165** "Integer overflow in `Segment::slice`" (CLOSED) — about
  `self.range.start + range.start` silent wraparound, not emptiness. Already fixed.
- PR **#3587** "Fix silent integer wrapping in `Segment::slice`" (MERGED) — the fix for
  #3165, landed here as `43bc501c4` / `55cee9788`. Same function, **and it left
  `range.start <= range.end` untouched**.

Nothing reports an empty/zero-length segment reaching `Segment`/`USegment::try_from` or
`Frame::from_raw`. A same-site precedent about a different mechanism is not a known match.

Also checked: no `TODO`/`FIXME`/"known issue" note at the site. Existing tests
(`ostd/src/mm/frame/test.rs:385-395` `segment_slice_out_of_bounds`) do pass an empty range
to `slice`, but the intent is the out-of-bounds assertion — no test converts an empty
segment. `test.rs:397-423` exercises the conversions on 1-frame segments only.

---

## 9. Suggested verification order

1. **Static (minutes).** Confirm §1.1–1.2 in the checkout under test — is the assertion
   still `<=`, and are both conversions still unconditional?
2. **Novelty (minutes).** Re-run §8. Most likely item to have changed.
3. **Dynamic (~1 h).** Run §3 and check the §5 markers. Remember two FAILs and one kernel
   death are the expected positive result.
4. **Independent harness (best evidence).** The round-trip identity is a one-line property
   — write your own check rather than only re-running this one.

---

## 10. Falsification criteria — the claim is WRONG if any of these hold

- `end_round_trip_ok=true` at every size — the identity holds and there is no wrong answer.
- Any **control** fails (`control_ok=false`, `control_round_trip_ok=false`, or
  `control_accepted_as_usegment=true`) — the harness is broken and proves nothing.
- `CR11|foreign|adjacency=not-obtained` — the allocator did not return the neighbouring
  frame, so that test self-skips and its result must not be counted.
- `CR11|fault|survived` appears — the kernel tolerated the read; the hard-fault claim
  fails (the wrong-answer claim could still stand).
- `CR11|fault|from_in_use=…|Ok(in use)` — the frame past the end *was* in use, so reading
  it is not obviously unsound and the framing needs revisiting.
- `slice(&(size..size))` panics or returns a non-empty segment — then §1.1 is wrong for
  your checkout.

## 11. Known limitations

- **One environment**, QEMU-based ostd ktest on x86_64. The logic is arch-independent, but
  the *reachability* of flavour 3 depends on allocator layout (see §5.4).
- **Flavour 2 depends on allocator behaviour.** It relies on the per-CPU LIFO single-frame
  cache returning the same physical frame. The test verifies this and self-skips
  otherwise, so a different allocator policy weakens reproducibility, not the claim.
- **The max-boundary variant was not exercised** — the allocator could not reach
  `max_paddr()` here (`reaches_max_paddr=false`), so `Frame::from_raw`'s `debug_assert`
  path is untested.
- **Debug vs release.** `debug_assert!` is compiled out in release builds; the ktest
  kernel is a debug build. A release kernel may behave differently at the max boundary.
- **Residue.** The driver leaves `ostd/src/mm/frame/cr11_repro.rs` and its `mod`
  registration in the worktree. It modifies no code under test.

## 12. Fix direction (context only — local reference, not for submission)

Reject the empty segment at the conversions, which is where the unsound read is. Both
impls need it (`segment.rs:275` and `segment.rs:312`):

```rust
fn try_from(seg: Segment<dyn AnyFrameMeta>) -> Result<Self, Self::Error> {
    if seg.range.is_empty() {
        return Err(seg);   // or Ok(...) — an empty segment is vacuously of any type
    }
    ...
}
```

Returning `Err` is the smaller change and matches the existing contract shape; returning
`Ok` is more principled (an empty segment is vacuously homogeneous) but callers already
handle `Err`.

Optionally tighten `Segment::slice` to `range.start < range.end` (`segment.rs:170`) and
document the panic, matching every sibling in the codebase (§1.6). That is more invasive —
it turns a currently-legal call into a panic — so **the conversion guard should land
regardless**.

Either change should carry the §6 tests as regressions; they encode the round-trip
identity as the property.
