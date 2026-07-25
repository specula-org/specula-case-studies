# Reproduction Tests — aptosbft_2

This directory contains the reproduction harness for the bugs surfaced by the
aptosbft_2 round of model checking and code review.

## Files

- `test_bug1_2_double_vote.rs` — Rust reproduction for Bug 1 (Family 1, MC-1
  enabler / `RecoverPreservesLastVote`) and Bug 2 (Family 1, MC-1 /
  `NoDoubleVote`). Demonstrates that a SafetyRules instance whose persisted
  state was lost between `self.sign(...)` and
  `self.persistent_storage.set_safety_data(...)` will sign a second,
  semantically distinct vote at the same round on the next call. **Lives in the
  aptos-core tree at
  `consensus/safety-rules/src/tests/repro_bugs.rs`** so it has the
  `pub(crate)` visibility it needs to call into safety-rules internals; this
  copy is for reference. The runner script below executes it via
  `cargo test`.

- `test_bug3_sign_commit_vote_epoch.rs` — Companion test embedded in the same
  `repro_bugs.rs`. Probes whether the spec-level `CommitEpochBound`
  counterexample (MC-5) actually fires when the real implementation's
  `match_ordered_only` runs. Result: the cross-epoch attempt is rejected with
  `InconsistentExecutionResult`, so the spec finding is a **false positive at
  the implementation level**.

- `doc_wrapped_ledger_info_vote_data_unsigned.rs` — Documents the
  `WrappedLedgerInfo::verify` gap (vote_data not bound by the signature).
  Reachable in code, but downstream consumers re-check via
  `verify_consensus_data_hash`; defense-in-depth only.

- `on_disk_storage_no_fsync.sh` — Demonstrates that
  `OnDiskStorage::write` (`secure/storage/src/on_disk.rs:64-70`) issues no
  `fsync`/`fdatasync` syscalls, so a power loss between the `rename` and the
  kernel flush can lose the write. This is the storage-backend precondition
  for Bug 1/2 in production.

- `run_repros.sh` — Top-level runner that builds and executes everything,
  capturing output into `test_output.txt`.

## How to run

```
cd /home/ubuntu/Specula/case-studies/aptosbft_2/.specula-output/repro
./run_repros.sh
```

This will:
1. `cargo test -p aptos-safety-rules --lib repro_bugs -- --nocapture` to run
   the Rust reproduction tests.
2. `./on_disk_storage_no_fsync.sh` to verify the storage-backend
   precondition via strace.

Total runtime: ~2 minutes (most of it is the safety-rules build).

## Result summary

| Test | Bug | Outcome |
|---|---|---|
| `repro_bug1_2_double_vote_after_crash_window` | Bug 1 / Bug 2 | **REPRODUCED** — `NoDoubleVote` violated |
| `counter_durable_persist_blocks_double_vote` | Bug 1 / Bug 2 (counter) | PASS — durable persist returns the previous vote (dedup) |
| `test_bug3_sign_commit_vote_cross_epoch_blocked_by_match_ordered_only` | Bug 3 | **FALSE POSITIVE** — `match_ordered_only` blocks |
| `doc_wrapped_ledger_info_vote_data_unsigned` | Family 3 doc | Documents the gap; defense-in-depth |
| `on_disk_storage_no_fsync.sh` | Bug 1 precondition | strace shows no `fsync` / `fdatasync` |
