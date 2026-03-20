`storage.load(Acquire)` in `HybridProtection::fallback` can return a stale pointer. Upgrade to `SeqCst`.

### Problem

```rust
let gen = node.new_helping(storage as *const _ as usize); // SeqCst
let candidate = storage.load(Acquire); // <- not in the SeqCst total order
```

A concurrent writer can `storage.swap(new_ptr, SeqCst)`, but this `Acquire` load may still see the old pointer. The writer scans, sees no debt yet, frees the old pointer. Reader gets a dangling pointer.

### Fix

`storage.load(Acquire)` → `storage.load(SeqCst)`.

### Miri reproduction

Test uses `FillFastSlots` to isolate the fallback path from fast-path ordering.

```
MIRIFLAGS="-Zmiri-seed=39 -Zmiri-preemption-rate=1" \
  cargo +nightly miri test --features internal-test-strategies \
  --target aarch64-unknown-linux-gnu --test fallback_uaf
```

Before (`Acquire`): seed=39, seed=77 fail.
After (`SeqCst`): seeds 0–100 all pass.

---

### Issue #200 comment

We found a separate ordering gap in the fallback path — `storage.load(Acquire)` in `HybridProtection::fallback` can miss a concurrent SeqCst swap. This is independent of the fast-path issue discussed here, and might be the reason miri keeps failing after fixing the fast-path ordering. #203 has a fix and a miri-reproducible test.
