# arc-swap

## Scope

Specula analyzed and tested arc-swap's debt-based atomic pointer runtime, including load, swap, compare-and-swap, debt publication and payment, fallback helping, reference-count reclamation, pointer reuse, and generation wraparound.

## Bugs

Specula found 3 new bugs:

- The fallback path used an `Acquire` storage load that could miss a concurrent `SeqCst` swap and leave a reader holding a freed pointer; PR #203 fixed the issue.
- Generation wraparound can discard a `LocalNode` before `confirm_helping` reuses it, causing a panic and leaving the helping slot poisoned.
- `HybridProtection::attempt` can construct an owned guard from a stale pointer after debt payment fails, causing a provenance-invalid use-after-free when the address is reused.

The bug tracker also records 5 known bugs examined by Specula:

- An ordering gap in `Debt::pay` can let a writer miss a reader's published debt and free the referenced pointer; Issues #200 and #198 remain open.
- The historical relaxed failure ordering in `Debt::pay` could observe a repaid debt without the reference-count visibility needed for safety; PR #195 fixed it.
- The historical success-leg ordering in `Debt::pay` could miss a published debt and skip a required reference-count increment; Issue #204 records the fixed issue.
- A historical fast-path confirmation ordering gap could let a reader proceed with a stale pointer after its protection was lost; Issue #76 records the fix.
- An insufficiently ordered `LIST_HEAD` load could let a writer scan a stale node snapshot and miss outstanding debts; Issue #164 records the fixed issue.
