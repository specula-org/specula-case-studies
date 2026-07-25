# Reproduction Scripts — arc-swap_3

All five MC-found bugs are **historical UAF bugs already fixed in mainline**.
Each is reproduced by reverting one specific historical fix in
`artifact/arc-swap/src/...` and running an aggressive miri stress test that
exercises the relevant path.

The tests `tests/uaf_stress.rs` and `tests/dynamic_threads.rs` are added by
this case study (in the artifact tree, not the upstream crate). The test
`tests/fallback_uaf.rs` already existed upstream as the regression test for
issue #198.

## Pre-requisites

- A nightly Rust toolchain with `miri` installed (e.g. `rustup +nightly component add miri`).
- The artifact must compile cleanly on `cargo build`.

## Running

Each `test_bugN_*.sh` script:

1. Saves the current state of the file it will edit.
2. Applies a single-line revert of the historical SeqCst/Acquire fix.
3. Runs `cargo +nightly miri test --test <test_name>` with `-Zmiri-many-seeds`.
4. Records the miri output.
5. Restores the original file.

Run from this directory:

    cd /home/ubuntu/Specula/case-studies/arc-swap_3/.specula-output/repro
    ./test_bug1_debt_pay_failure_leg.sh
    ./test_bug2_fallback_load.sh
    ./test_bug3_fast_confirm_load.sh
    ./test_bug4_debt_pay_success_leg.sh
    ./test_bug5_list_head_load.sh

## Expected outcome

| Bug | Issue/PR        | Reverted edit                                         | miri result        |
|-----|-----------------|-------------------------------------------------------|--------------------|
| 1   | PR #195         | `Debt::pay` failure leg `Acquire` → `Relaxed`         | UAF at seed 4      |
| 2   | issue #198      | fallback `storage.load(SeqCst)` → `Acquire`           | UAF at seed 39     |
| 3   | issue #76       | fast confirm-load `storage.load(SeqCst)` → `Acquire`  | UAF at every seed  |
| 4   | issue #204      | `Debt::pay` success leg `AcqRel` → `Release`          | NO UAF observed (seeds 0..96)    |
| 5   | issue #164      | `LIST_HEAD.load(SeqCst)` → `Acquire`                  | UAF at most seeds  |

Bug 4's miri reproduction failure is consistent with the historical record:
issue #204 was identified through formal C++ memory model proofs (#200), not
miri runs, because miri's TSO-leaning weak-memory emulation is too strong to
expose the lost transitivity edge between the two CAS legs.
