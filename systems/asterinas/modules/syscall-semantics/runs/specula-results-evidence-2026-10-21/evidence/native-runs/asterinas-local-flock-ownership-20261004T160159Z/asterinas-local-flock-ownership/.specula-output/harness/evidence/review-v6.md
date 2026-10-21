# Independent corrective review of flock harness v6

Verdict: **PASS for the exact v6 revision**. The private-container companion-file copy supplies the paths required by the unchanged guest checksum gate. Both checksum gates remain enforced. No new material finding or source/model/scenario semantic change was identified. R1-R4 remain closed.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T13:42:58.094789+00:00.

The reviewed proposal is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v6`, including its frozen `inputs`, `sha256.json`, `revision.diff` and `reason.md`. All snapshot files match their recorded hashes. Only `run.sh` differs from v5, with SHA-256 `68d5866c9b8ce0d716fe7edbc6cd51cd1e4c61d0169c3f9b5d4b6f8335908730`. Unchanged semantic input hashes remain in the v6 manifest and preceding reviews.

The triggering guest-admission log is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/attempt-20261005T133836-451750748/C01.log`, SHA-256 `3fc07133c08c562f7e04b0a2baa2a6bd30b5203ea9ff3066b307ff26b6d2d075`. It reports missing `../spec/` companion files while the harness files pass their checks. Since `run_case.sh` uses `set -e` and performs the checksum check before initramfs creation and `cargo osdk run`, this log records failed admission, not guest execution.

V6 creates `/spec/generation-checks` inside the already identified private container, then copies the five explicit companion inputs from the host's lane output: `base.tla`, `Trace.tla`, `Trace.cfg`, `instrumentation-spec.md` and `generation-checks/validate_trace.py`. From `/harness`, the guest-side marker's `../spec/` entries resolve to these paths. The directory creation covers the adapter's nested path. Any copy failure stops the runner under its existing shell error handling.

The host checksum gate still precedes the copy, and the unchanged guest checksum gate checks the copied bytes before execution. A change between those stages is rejected by the latter gate. No hash entry is removed, no mismatch is ignored, and the change does not expose host devices or modify host spec files. The source, private alloc patch, fixture, trace interpreter and resource limits are unchanged.

This was a focused read-only review. The reviewer ran no build, guest, test, Linux control, TLC or trace replay, acquired no locks, and changed no source/harness input. Earlier build and Linux-control outcomes are controller evidence, not results of this review. The controller may renew the marker for v6's `run.sh` hash and resume bounded execution. Successful guest execution, trace completeness, coverage and validation remain separate obligations.
