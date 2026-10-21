# Phase 2.5 status

Candidate v6 adds syscall-outcome collection through `run.sh --outcome`. `--diagnostic` is an alias and remains the default. The candidate is ready for independent review, with `review-gate.json` set to `INCOMPLETE`, candidate `v6` and scope `NONE`. The author has neither approved nor committed it.

The first admitted v5 Linux control stopped with exit 78 and the reported diagnostic `WR_CLOCK_UNSUPPORTED actor=3 cpu=1 vendor=AuthenticAMD max=80000022 features=178bfbff invariant=0`. The supplied environment is an AMD Ryzen 9 9950X KVM guest using kvm-clock without invariant TSC. The grouped path still requires GenuineIntel and invariant TSC. Its clock method has not changed, and implementation trace validation is **BLOCKED_ENVIRONMENT**.

Outcome records carry `evidence_class: "OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE"`, `implementation_trace: "NONE"` and `trace_validation: "BLOCKED_ENVIRONMENT"`. They compare each observed call and the permitted history with the pinned Linux v6.16.5 source oracle. A comparison is `match`, `mismatch` or `inconclusive`. None of these values classifies a kernel bug. The Linux control runs the host kernel, whose uname is recorded separately from the source oracle version.

## Required criteria

PASS means static implementation or artifact verification. No v6 fixture, collector, Linux control or guest has executed. Both systems' runtime coverage and the comparison logic's runtime behavior remain **NOT RUN**. Static evidence is in [v6-static-checks.json](evidence/v6-static-checks.json).

| Criterion | Status | Evidence and limits |
| --- | --- | --- |
| O1-mode | PASS | [wait_reap_trace.c](src/wait_reap_trace.c) dispatches to a separate outcome entry that never calls the fixture clock, calibration or recorder controls. [collect_outcome.py](src/collect_outcome.py) writes only allowlisted syscall records. [run.sh](run.sh) sends outcome results to the attempt's `outcomes/` directory and skips calibration execution. The original grouped fixture body and collector functions are preserved. The unchanged kernel patch still executes some unrecorded stamps. |
| O2-coverage | PASS | [cases.tsv](cases.tsv) maps all 21 cases to WR IDs, covering WR-01 through WR-10, WR-SQ, WR-CF and WR-LX. Both runner loops include every row in outcome mode. WR-08/09/10 internal windows remain opportunistic and unestablished. Execution on both systems is NOT RUN. |
| O3-controls | PASS | [wait_reap_trace.c](src/wait_reap_trace.c) implements separate fresh-child SQ zero/poison cases, three CF cases with an established zombie and a valid follow-up, and the sequential LX calls. It records all six siginfo fields and relevant bytes before and after valid-buffer calls. Exit values 0, 37 and 255 remain covered by WR-02. Runtime checks are NOT RUN. |
| O4-expected | PASS | [collect_outcome.py](src/collect_outcome.py) fixes the call plan before reading results, checks arguments and initial sentinels, emits the Linux-source expectations per call and checks one-success/one-ECHILD histories. Incomplete execution or missing evidence produces `inconclusive`. No mismatch is labelled a bug. Collector execution is NOT RUN. |
| O5-records | PASS | [candidate-v6/hashes.json](evidence/candidate-v6/hashes.json), [correction-v5-v6.diff](evidence/correction-v5-v6.diff), [v6-inputs.json](evidence/v6-inputs.json), [outcome-mode-v6.md](evidence/outcome-mode-v6.md), the updated documents and the incomplete gate preserve the review candidate. The full changed-file list is [v6-files.txt](evidence/v6-files.txt). |

## Evidence limits and continuation

The kernel recorder is not armed in outcome mode. The observer-delay control is inactive. Every guest uses a fresh boot, so no actor registration survives from an earlier case. The existing kernel instrumentation remains installed and contains unconditional stamp instructions and hook checks. Outcome mode therefore removes recording and output-buffer observer reads, but does not establish the behavior of an uninstrumented kernel.

WR-08 checks allowed observer/consumer results without proving selection-before-removal or late output. WR-09 and WR-10 may encounter their intended internal windows through zero-delay and delayed exits, but neither user-space started flags nor sleeps prove registration, recheck or park timing. Completed competing cases must still have one successful consumer, one ECHILD and no hang. A watchdog expiry is an execution limit, not evidence of a lost wakeup. R2's global order, store visibility and run-wide clock obligations remain open.

The reviewer must approve the exact v6 snapshot and live inputs with `OUTCOME_ONLY` before outcome execution. Clock diagnostics and grouped collection require `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND` and a compatible environment. The current receipt approves neither scope. The controller retains installation, receipt rebinding and heavy-stage lock ownership. The workspace's historical `evidence/applied.json` was not replaced and is not a v6 installation receipt.

No Docker, build, QEMU, TLC, source installation, runtime control or collector execution occurred during v6 preparation. Only source inspection, Python/Bash/C syntax checks, static comparisons and artifact verification were performed. `spec/`, `modeling-brief.md`, the kernel patch and hooks, clock method, memory admission, network policy, image pin and BusyBox/probe handling remain unchanged.
