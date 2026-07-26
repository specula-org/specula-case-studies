# arc-swap

## Scope

Specula analyzed and tested arc-swap's debt-based atomic pointer runtime, including load, swap, compare-and-swap, debt publication and payment, fallback helping, reference-count reclamation, pointer reuse, and generation wraparound.

## Bugs

Specula found 3 new bugs:

- **Fixed:** The fallback path used an `Acquire` storage load that could miss a concurrent `SeqCst` swap and leave a reader holding a freed pointer; see PR #203.
- Generation wraparound can discard a `LocalNode` before `confirm_helping` reuses it, causing a panic and leaving the helping slot poisoned.
- `HybridProtection::attempt` can construct an owned guard from a stale pointer after debt payment fails, causing a provenance-invalid use-after-free when the address is reused.

Specula also found 5 previously known bugs:

- **Open:** An ordering gap in `Debt::pay` can let a writer miss a reader's published debt and free the referenced pointer; see Issues #200 and #198.
- **Fixed:** The historical relaxed failure ordering in `Debt::pay` could observe a repaid debt without the reference-count visibility needed for safety; see PR #195.
- **Fixed:** The historical success-leg ordering in `Debt::pay` could miss a published debt and skip a required reference-count increment; see Issue #204.
- **Fixed:** A historical fast-path confirmation ordering gap could let a reader proceed with a stale pointer after its protection was lost; see Issue #76.
- **Fixed:** An insufficiently ordered `LIST_HEAD` load could let a writer scan a stale node snapshot and miss outstanding debts; see Issue #164.
