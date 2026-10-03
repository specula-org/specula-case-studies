# Incremental CI Report — etcd-raft V01

Source revision: `16c5274b589aa75c634a1a5f2b05cf66aaf37dcc`.

Execution mode: automatic model generation and verification, followed by manual confirmation and publication. The automatic CLI attempts ended with exit 76; this result is not an unattended end-to-end CI success.

The source delta requires a model update: it introduces `ConfChangeV2` joint consensus, explicit RawNode bootstrap, Advance-driven auto-leave, and changed Ready ownership. The updated reference suite, `Update.tla`, and the rebased harness are recorded in `modeling-brief.md`, `analysis-report.md`, `incremental-validation.md`, and `spec/changelog.md`.

Eight fresh source traces (4,629 events) passed exact post-state correspondence. Seven pass the normal invariant set; the joint-snapshot recovery trace fully corresponds through the restart that violates the retained configuration-origin property. Uncached upstream tests and the race-enabled harness passed. The standard, full-update, focused, and scenario TLC campaigns completed their configured bounded checks with no additional reported violation; those budgets do not establish exhaustive safety or liveness.

Current confirmation found two reproduced defects. `MC-1` is a Critical joint-snapshot recovery error: V01 restores only incoming voters, allowing a leader without the persisted outgoing quorum. `CR-3` is a High configuration-boundary error: an early Advance admits a second configuration change before the first callback. `CR-1` and `CR-6` no longer reproduce; `CR-2` and `CR-5` require public-interface rechecks. See `confirmed-bugs.md`, `bug-severity.md`, and `repro/results/` for current evidence.

CI verdict: **FAIL**.

## Evidence and accounting

- [Confirmation dispositions](confirmed-bugs.md) and [severity classification](bug-severity.md) retain the manually finalized results unchanged.
- [Reproduction evidence inventory](repro/evidence-index.json) binds the archived files to their current hashes. The CR-3 program was copied unchanged from the prior run's retained program to restore the report's relative reference; no reproduction was rerun during curation.
- [Trace-validation handoff](incremental-validation.md) and [modeling/checking history](spec/changelog.md) describe the V01 evidence. Earlier baseline reports retain their historical scope.
- Recorded incremental model-call cost is approximately $29.19. Untracked manual completion work is not included, so the resource total remains labeled incomplete.

The curation changes reports and evidence packaging only. Model/configuration semantics, source revision, confirmation statuses and the FAIL verdict are unchanged; the previous publication remains retained.
