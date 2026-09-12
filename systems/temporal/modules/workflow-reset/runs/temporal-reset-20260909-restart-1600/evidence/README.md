# Evidence entry points

All implementation conclusions refer to `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Two locally reproduced behavior defects; no upstream confirmation, TLC run or formal trace validation is claimed.

- [Final verification and selected case statuses](verification.json): 27 existing cases; 16 focused cases (10 observation/control passes, 6 retained identity-contract failures); final lint exit 0.
- [Reproduction script](reproduce.sh): compiles current pinned source plus the archived test overlay and checks expected diagnostic result counts. Syntax checked; equivalent build/test commands executed during this investigation. The script itself was not used to rerun all already-completed tests.
- [Final test sources and hashes](test-sources/manifest.json): authoritative final overlay; no tracked production changes.
- [Identity audit](identity/identity-audit.md) and [original exact observations](identity/observations.json): six file-backed cases, one defect. Final style-corrected rerun is `final-functional.log`; use only identity test cases from that log.
- [Final recovery/concurrency log](recovery/recovery-complete.log): definite rejection recovery, actual Start-first interference, automatic Reset retry, completion and post-completion base deletion. Dedicated SQLite memory, SQL shard I/O concurrency two.
- [Final CAN/deletion audit](history/audit.md) and [final run](history/final-history-tests.log): repeated-ID rejection, distinct/exclusion controls, shard-reload control, file-backed live-reset base deletion through completion.
- [Existing baseline log](recovery/baseline.log) and [case denominator](baseline-cases.json).
- [Final lint log](lint-complete.log).
- [Commit coverage denominator](archaeology/coverage-total.json): 188 unique keyword commits plus one separately traced identity change; 224 entries across four scopes.
- [Issue coverage denominator](archaeology/issue-coverage-total.json): 520 collected unique records, 46 full discussions; [open-PR inventory/triage](archaeology/open-pr-ledger.md).
- [Backend/locking/retry audit](persistence/persistence-audit.md); [upstream Reset source comparison](upstream-reset-comparison.json).

Earlier logs are preserved for audit, not combined with final result counts. `final-functional.log` contains an obsolete competing-Start assertion expecting a public error; `recovery/recovery-complete.log` supersedes it and verifies successful internal retry. Initial deletion waits, shared-cluster CloseShard use, absent polling deadline and blocked single-slot test gates were harness problems subsequently corrected. The identity audit's early source snapshot/UUID records predate lint-only changes; the final overlay snapshot and selected final logs above are authoritative for reproduction.

File-backed readback is not process restart. The dedicated CloseShard cases are in-memory SQLite. A deliberately unavailable successful public response is distinct from a persistence commit returning an uncertain outcome. Required remaining formal, backend, scanner-age and child-completion schedules are enumerated in the main report and brief.
