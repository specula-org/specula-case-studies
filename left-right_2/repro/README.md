# Reproduction Tests — left-right_2

These reproduction tests are *copies* of the test files placed at
`artifact/left-right/tests/`. Cargo discovers integration tests from that
directory, so the tests are executed there. The copies in this folder are
the durable artifacts.

## Bug 1 — `take_inner` stale-snapshot UAF (PR #144)

### Level-3 deterministic version (recommended)

Requires the env-var-gated `std::thread::sleep(LR_REPRO_BUG1_SLEEP_US)`
already instrumented in `artifact/left-right/src/write.rs` (lines 174-184).
The instrumentation is opt-in: it has zero effect unless the env var is set.

```bash
cd artifact/left-right
LR_REPRO_BUG1_SLEEP_US=200 cargo test --release \
    --test repro_bug1_take_inner_uaf_l3 -- --ignored --nocapture
```

Expected output:

```
BUG OBSERVED iter=0: v=0x1 v2=0x3aadd031 (CANARY=0x77777777)
BUG OBSERVED iter=0: v=0x1 v2=0x3aadd031 (CANARY=0x77777777)
iter=0/100 bugs=2 obs=8
...
BUG OBSERVED iter=99: v=0x1 v2=0x3aadd031 (CANARY=0x77777777)
BUG OBSERVED iter=99: v=0x1 v2=0x3aadd031 (CANARY=0x77777777)
Total bug observations: 289 / 914 reader observations
test take_inner_stale_snapshot_uaf_l3 ... ok
```

Each `BUG OBSERVED` line shows that the reader read two different values
from a single `ReadGuard` (`v=0x1`, `v2=<heap-pointer-like-garbage>`),
proving the buffer was freed and reused while the reader still aliased it.
The test passes when at least one bug observation is recorded.

### Level-0/1 stress test (cite PR #144 instead)

`test_bug1_take_inner_uaf.rs` runs without source modification but the
window is too small for non-sanitizer detection. Listed for documentation
only. Cite PR #144's TSAN evidence as the authoritative reproduction.

```bash
cd artifact/left-right
cargo test --release --test repro_bug1_take_inner_uaf -- --ignored --nocapture
```

## Bug 2 — Reentrant `enter()` panics on dropped `WriteHandle` (NEW)

Pure black-box. No source modification.

```bash
cd artifact/left-right
cargo test --test repro_bug2_reentrant_panic -- --nocapture
```

Expected output:

```
running 1 test

thread '<unnamed>' (NNNN) panicked at
.../src/read.rs:146:17:
internal error: entered unreachable code:
if pointer is null, no ReadGuard should have been issued
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
BUG REPRODUCED: reader panicked with: internal error: entered unreachable
code: if pointer is null, no ReadGuard should have been issued
test reentrant_enter_on_dropped_writehandle_panics ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;
0 filtered out; finished in 0.07s
```

The reader thread panics at `src/read.rs:146` exactly matching the MC
counterexample for `MCNoUnreachablePanic`. The test passes by catching
the panic via `JoinHandle::join().is_err()` and asserting the message.
