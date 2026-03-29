# Confirmed Bug Report — left-right

## Summary
- Total findings reviewed: 7
- Reproduced: 1 (CR-1: change_drop double-free)
- Known historical (no reproduction needed): 1 (Family 3: clone-while-guarded deadlock)
- False positives: 5 (Family 1: ordering fences, Family 2: non-det absorb, Family 4: variants, CR-2: comment, CR-3: loom)

## Bug 1: change_drop() missing mem::forget(self) — double-free / UAF

- **Source**: Code Review (CR-1)
- **Status**: REPRODUCED
- **Severity**: Medium (latent — DoDrop→anything direction not used in current codebase, but safety comment is incorrect)
- **Location**: `artifact/left-right/src/aliasing.rs:211-218`
- **Description**: `Aliased::change_drop()` takes `self` by value and uses `ptr::read(&self.aliased)` to create the return value, but does not call `mem::forget(self)` afterward. When `self` is dropped at function exit, `Aliased::drop()` runs. If the source type `D` has `DO_DROP = true`, the drop impl calls `drop_in_place` on the inner `T`, freeing it. The returned `Aliased<T, D2>` now holds a bitwise copy of the `MaybeUninit<T>` pointing to freed memory. This is:
  - **UAF** if the returned value is read through `Deref`
  - **Double-free** if the target `D2` also has `DO_DROP = true` (both source and result try to drop the same `T`)
- **Safety comment is wrong**: The doc comment says "It is always safe to change an `Aliased` from a dropping `D` to a non-dropping `D`." This is the exact direction that triggers the bug. The comment confuses *semantic* safety (aliasing invariants) with *implementation* correctness (missing `mem::forget`).
- **Trigger scenario**: Any caller that creates an `Aliased<T, DoDrop>` and calls `change_drop()` on it. Currently no code in the left-right crate or its tests exercises this direction — all callers use NoDrop→DoDrop (which is safe). But the API is public and the safety comment invites this usage.
- **Developer intent**: No GitHub issue found for this specific bug. Issue #74 (Box aliasing UB) and PR #83 (Aliased redesign) addressed related problems but not this one. The `change_drop` function was added as part of the PR #83 redesign.
- **Reproduction test**: `repro/test_bug1_change_drop_double_drop.rs`
  - Test 1 (DoDrop→NoDrop): TrackedValue dropped during `change_drop()` — drop_count goes from 0 to 1 while value should still be alive. Returned Aliased holds dangling reference.
  - Test 2 (DoDrop→DoDrop): TrackedValue dropped TWICE — once during `change_drop()`, once when result is dropped. In release mode, the allocator detects the double-free and aborts: `free(): double free detected in tcache 2`
  - Test 3 (NoDrop→DoDrop, control): Works correctly — inner T dropped exactly once when result is dropped.
- **Reproduction result**: PASS (bug triggered)
  - Debug mode: premature drop confirmed, double-free confirmed (drop_count=2)
  - Release mode: **process aborted** with `free(): double free detected in tcache 2` (exit code 134)
- **Recommendation**: Add `std::mem::forget(self)` after `ptr::read(&self.aliased)` in `change_drop()`, or restructure to use `ManuallyDrop` to prevent the source's `Drop` from running. The fix is one line.

## Known Historical Bug: Clone-while-guarded deadlock

- **Source**: MC (Family 3) + historical commit `02eb63b`
- **Status**: KNOWN HISTORICAL — deadlock fix committed 2018-03-01, ReadHandleFactory introduced as safe alternative
- **Severity**: Medium (API hazard — requires specific misuse pattern)
- **Location**: `artifact/left-right/src/read.rs:74-78` (ReadHandle::clone), `artifact/left-right/src/write.rs:236-296` (WriteHandle::wait)
- **Description**: `ReadHandle::clone()` acquires the epochs mutex. If called while a `ReadGuard` is held (epoch is odd) concurrently with `publish()` (which also acquires the epochs mutex and then waits for all epochs to advance), a circular wait occurs: writer holds mutex waiting for reader's epoch; reader holds epoch waiting for mutex. MC confirmed with 11-state counterexample.
- **Mitigation**: `ReadHandleFactory` (`read/factory.rs`) avoids this by capturing `Arc` clones at creation time without needing the mutex during handle production. The deadlock requires: (1) holding a `ReadGuard`, (2) calling `ReadHandle::clone()` from the same thread, (3) concurrent `publish()` holding the mutex. This pattern is unusual but not prevented by the type system.
- **Reproduction**: Not required (known historical bug with existing commit `02eb63b`).

## False Positives

### Family 1: Memory Ordering (MC fault injection)
- **Source**: MC (MC_hunt_ordering.cfg)
- **Status**: FALSE POSITIVE — validates existing correctness, not a current bug
- **Reasoning**: MC confirms that removing the SeqCst fences breaks safety (6-state counterexample). But both fences are correctly in place: `read.rs:172` (between epoch bump and pointer load) and `write.rs:428` (between swap and epoch read). The violation only occurs under fault injection that disables these fences. This is a positive result: it proves the fences are necessary and that model checking can verify what loom cannot (due to `sync.rs:9` FIXME — loom downgrades SeqCst to Acquire).

### Family 2: Oplog Dual-Apply Determinism (MC fault injection)
- **Source**: MC (MC_hunt_absorb.cfg)
- **Status**: FALSE POSITIVE — user contract, not a left-right bug
- **Reasoning**: MC confirms that non-deterministic `absorb_first`/`absorb_second` implementations break copy consistency (10-state counterexample). But this is the documented contract of the `Absorb` trait — the responsibility lies with the user's implementation, not with left-right. The trait documentation clearly warns about this requirement. Historical bugs (`6a678e7`, `338ef95`, evmap #1) were in downstream `Absorb` implementations, not in the left-right protocol.

### Family 4: Publish Path Variants
- **Source**: MC (MC_hunt_variants.cfg)
- **Status**: FALSE POSITIVE — no violations found
- **Reasoning**: 147M states explored, all 6 invariants pass. `publish()`, `try_publish()`, and `take_inner()` all provide identical safety guarantees.

### CR-2: Fence comment mismatch
- **Source**: Code review
- **Status**: FALSE POSITIVE — documentation issue, not a correctness bug
- **Reasoning**: The SeqCst fence at `write.rs:178` in `take_inner()` has a comment that doesn't perfectly match its placement relative to the epoch reads. The fence itself is correct (it ensures epoch reads happen after the NULL swap). This is a comment clarity issue only.

### CR-3: loom SeqCst downgrade
- **Source**: Code review
- **Status**: FALSE POSITIVE — known limitation of external tool
- **Reasoning**: `sync.rs:9` FIXME notes that loom downgrades SeqCst fences to Acquire. This means loom testing cannot fully verify the memory ordering protocol. This is a limitation of loom (tracked in tokio-rs/loom#117), not a bug in left-right. The model checking in this project fills exactly this gap.
