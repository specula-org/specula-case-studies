# Real implementation trace validation

Real implementation trace replay checks only the recorded schedules. Negative controls establish rejection of changed observations; they are not implementation runs. This is neither exhaustive correctness verification nor a general liveness proof.

| Check | Result | TLC exit | Seconds |
|---|---|---:|---:|
| positive-recovery_epochs_and_reconstruction | PASS | 0 | 0.967 |
| positive-reordered_state_transfer | PASS | 0 | 1.017 |
| positive-requests_replies_and_lifetimes | PASS | 0 | 0.966 |
| positive-view_change_and_retained_resume | PASS | 0 | 1.367 |
| negative-postcommit | PASS | 13 | 0.816 |
| negative-apply-result | PASS | 13 | 0.868 |
| negative-packet-offset | PASS | 13 | 0.979 |
| negative-omitted-persist | PASS | 13 | 0.816 |

Every run uses the unrelaxed Trace.cfg invariants and TraceMatched property. Positive passes require completed TLC with zero errors. Negative passes require rejection specifically by TraceMatched; parser errors, invariant failures, exceptions, and timeouts do not count.

results.json records exact commands, hashes, exit codes, errors and log paths. coverage.json records events/branches and missing coverage; l2-audit.json records field/wrapper checks. Corrupted copies reside under negative/ only.
