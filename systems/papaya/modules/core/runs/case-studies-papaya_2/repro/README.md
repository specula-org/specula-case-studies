# Reproduction Tests — papaya_2

These reproduction tests are *copies* of the test files placed at
`artifact/papaya/tests/`. Cargo discovers integration tests from that
directory, so the tests are executed there. The copies in this folder are
the durable artifacts.

## Bug 1 — Wrong-Parker on Resize Abort (deadlock)

```bash
cd artifact/papaya
RUSTFLAGS="--cfg papaya_stress" cargo test \
    --test repro_parker_deadlock -- --test-threads 1 --nocapture
```

`papaya_stress` makes resize re-allocate at the same capacity, so resize
copies always abort. With 4 threads inserting concurrently, threads park
on the destination table's parker, while the abort path unparks the source
table's parker → permanent deadlock.

Expected output:
```
DEADLOCK DETECTED: thread did not complete within 30s
panicked at tests/repro_parker_deadlock.rs:83:5:
BUG REPRODUCED: Deadlock detected ...
```

## Bug 2 — META Overwrite Race (slot-leak / probe-chain bloat)

```bash
cd artifact/papaya
cargo test --test repro_bug1_meta_overwrite -- --nocapture
```

Requires the Level-3 instrumentation already present in
`src/raw/mod.rs:1055-1068` (a `yield_now` loop that widens the race window
between Phase-1 CAS and Phase-2 meta store, plus the
`META_OVERWRITE_BUG_COUNT` counter). The test races 3 inserter and 3
remover threads on the same key for 5,000 iterations each; the counter
records every time the entry pointer was tombstoned by a concurrent
`Remove` between the winning insert's CAS and meta-store.

Expected output:
```
BUG-1 Meta overwrite detections: <N> (across 5000 iterations x 6 threads)
test bug1_meta_overwrite_race ... ok
```
with `N > 0`.

## Bug 3 — Iterator Double-Yield

```bash
cd artifact/papaya
cargo test --test repro_bug3_iter_double_yield -- --nocapture
```

Single-threaded deterministic test. Uses a constant hasher (every key
hashes to slot 0) so insertion/probing order is fully controlled.

Expected output:
```
iter.next() #1 -> Some((1, 100))
remove(1) -> Some(100)
insert(1, 200) — re-inserted in a fresh slot
iter.next() -> (1, 200)
panicked: BUG 3 REPRODUCED: iterator yielded key 1 twice ...
```
