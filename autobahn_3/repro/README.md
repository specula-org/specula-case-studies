# Reproduction tests for autobahn_3 confirmed bugs

The Autobahn primary crate ships with developer-acknowledged reproduction tests
(`primary/src/tests/messages_tests.rs::test_da*` and
`primary/src/tests/core_tests.rs::bug*`) that demonstrate Bugs 1-4 directly.
The scripts below drive those tests and the two new reproductions written for
Bugs 5 and 6.

## Layout

| File | Bug | Mechanism reproduced |
|------|-----|----------------------|
| `test_bug1_qc_omits_proposals.sh` | 1 (Family 1) | `verify_commit` accepts two Commits with same QC, different proposals — drives in-tree `test_da1`, `test_da2`, `test_bug03_confirm_double_vote_verify` |
| `test_bug2_tc_verify_shortcircuits.sh` | 2 (Family 2) | Empty TC + under-quorum TC both pass `TC::verify` — drives in-tree `test_da3`, `test_da13` |
| `test_bug3_view_advance_side_effect.sh` | 3 (Family 3) | Invalid Prepare(view=3) corrupts `views[slot]` to 3, then valid Prepare(view=1) gets rejected — drives in-tree `bug4_view_advance_side_effect` |
| `test_bug4_winning_view_wrong.sh` | 4 (Family 4) | `winning_view := timeout.view` inflation causes lower-view proposals to win view-change — drives in-tree `test_da5_viewchange_wrong_winning_view` |
| `test_bug5_no_leader_check.rs` + `.sh` | 5 (Family 8) | Demonstrates that `is_valid(Prepare)` does not consult `LeaderElector` — author of Prepare is unchecked |
| `test_bug6_committed_slot_overwrite.rs` + `.sh` | 6 (composition) | Demonstrates that `process_commit_message` overwrites `committed_slots[slot]` unconditionally — combined with Bugs 1+2+8 yields AgreementSafety violation |
| `run_all.sh` | all | Runs every reproduction in sequence |

## Running

```bash
cd /home/ubuntu/Specula/case-studies/autobahn_3/.specula-output/repro
bash run_all.sh
```

Each script wraps `cargo test -p primary --lib <test_name> -- --nocapture`
inside an outer `timeout`. Tests run inside the in-tree primary crate so they
have access to private types (`ConsensusMessage`, `Timeout`, `TC`, `Core`,
etc.); the reproduction `.rs` files for Bugs 5 and 6 are injected into
`primary/src/tests/messages_tests.rs` as additional `#[test]` functions before
the run and restored on exit (idempotent — running twice is safe).

## Why the in-tree tests are valid reproductions

The bugs in this codebase are explicitly acknowledged by `// FIXME` markers in
`messages.rs:128, 194, 246` and a complete suite of `test_da*` / `bug*` tests
that the developers themselves wrote to demonstrate the defects. Those tests
are part of the project repository and pass against `HEAD` — they are
developer-accepted ground truth, not maintainer-rejected reports.
