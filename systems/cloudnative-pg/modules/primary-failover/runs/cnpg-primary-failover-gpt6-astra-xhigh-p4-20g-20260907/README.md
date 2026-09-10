# CloudNativePG: Primary Lease and Failover

This record covers the run started on 2026-09-07 against CloudNativePG revision
[d5f3426e161076322086b58c886cf8e7435f0e1b](https://github.com/cloudnative-pg/cloudnative-pg/tree/d5f3426e161076322086b58c886cf8e7435f0e1b).
The reviewed result is **1 new reproduced bug**, CR-4. Four other candidates are
excluded as already reported.

## Results

| Category | Count |
| --- | ---: |
| Accepted new bugs | 1 |
| Accepted model-checking discoveries | 0 |
| Accepted code-review discoveries | 1 |
| Excluded code-review candidates matching prior reports | 4 |

[CR-4](confirmed-bugs.md) loses an acknowledged transaction after stale quorum
metadata authorizes promotion of an outdated replica. The
[captured reproduction](confirmation/CR-4/reproduction-output.log) used
CloudNativePG 1.30.0 and PostgreSQL 18.6 in Kind. The reviewed record is based on
that archived execution; publication preparation did not repeat the live-cluster
experiment.

The original aggregate reported two NEW bugs. The
[reviewed dispositions](review/decisions.md) correct CR-3's novelty without
rewriting the supplied archive. Only CR-4 contributes to the system total.

## Run Setup

Phases 1 through 3 used Codex with GPT-6 Astra and xhigh reasoning. Final
confirmation used GPT-5.6 Sol and max reasoning after earlier confirmation
attempts were interrupted by provider policy blocks. Initial arguments requested
four parallel agents and reviews/debate; later logs show eight-way confirmation
with debate off. These settings describe separate attempts, not a uniform run
configuration. [Run metadata](run.json) separates them.

## Artifacts

- [Reviewed confirmation report](confirmed-bugs.md)
- [Original CR-4 test](repro/test_bugCR-4_stale_quorum_watch.py) and [safe launcher](repro/README.md)
- [Recorded SQL and controller output](confirmation/CR-4/reproduction-output.log)
- [Specifications and validation limits](spec/README.md)
- [Canonical lease traces](traces/) and [hook coverage inventory](harness/coverage.json)
- [Reported usage](reported-metrics.json)
- [Provenance manifest](.record/manifest.json) and [file hashes](.record/files.tsv)

This is a curated evidence subset. Source/dependency copies, database binaries,
TLC state databases, credentials, process state, retry prompts, and the separate
Specula product-feedback list are not included. Original files remain in the
supplied archive identified by its SHA-256 in the manifest.

The reported 8h53m, 288.7 million tokens, and $160.23 cover all reported sessions,
not just CR-4. About 95.81% of the token total is cached input; the complete
44-session billing/runtime ledger was not supplied for independent auditing.
