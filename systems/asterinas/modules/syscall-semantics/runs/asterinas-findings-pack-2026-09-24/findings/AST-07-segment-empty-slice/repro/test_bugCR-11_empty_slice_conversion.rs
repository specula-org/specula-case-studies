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
