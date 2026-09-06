# View-change, recovery, and timer fidelity audit

Date: 2026-09-05. Source: `git show 3ac0104a567092139534c9022205d02281a2da41:lib.rs`.

Audited `base.tla` SHA-256: `cdf67438142647ec70869e6f0aa9d18789bf560f91c7d6083fbd4dbbab3ed748`.

This independent static audit ran during the root agent's convergence phase. No tests, simulator, TLC, external queries, or integration-confirmation work were run. No source/spec changes were made. Library line numbers refer to the pinned blob because the working `lib.rs` has preexisting instrumentation.

## Result

No concrete source/spec mismatch was found in the audited view-change, recovery, timer, and adjacent state-adoption paths. No Case B change is proposed on this evidence. This is a bounded static correspondence review, not an exhaustive equivalence proof or a claim that the implementation satisfies protocol invariants.

## Checked correspondence

| Operation | Pinned Rust | `base.tla` | Correspondence checked |
|---|---|---|---|
| Clear and enter Normal | `994-998,1114-1121` | `108-113` | SVC/DVC tables and DVC-sent flag clear. Enter Normal updates last-normal view, catching flag, heard flag, waiting/stable counters. Attempts, acknowledgments, recovery nonce, and responses are not implicitly reset. |
| DVC record selection | `1043-1059` | `127-146` | Per-sender insert overwrites, including an older report; quorum uses distinct map keys and `< quorum` return. Choose lexicographic maximum `(last_normal_view,log length)`, with the last equal item in BTreeMap ascending-key iteration, represented as highest replica ID. Maximum commit is selected independently across reports. |
| DVC commit/install output order | `1066-1080` | `142-146` | Install selected log, commit/reply prefix, enter Normal, clear/rebuild self acknowledgments for the remaining suffix, then broadcast StartView in membership order. Canonical output normalization preserves the implementation's separate protocol/reply vector drain order (`base.tla:380-392`). |
| Send own DVC | `1015-1037` | `148-154` | Candidate primary records locally inside the same handler. Backups emit one DVC with current view, last-normal view, full log/length, and commit. No invented self-delivery event. |
| SVC threshold | `1001-1010` | `155-159` | Requires ViewChange, not catching up, not already sent, and at least `N div 2` other SVC senders. Set sent flag before local or remote DVC contribution. |
| Start view change | `971-991` | `160-166` | Attempts increment only if the old status was ViewChange. Update view/status, clear catching/waiting and view-change tables, broadcast SVC, then evaluate initial DVC eligibility. Heard/stable/acks are preserved. |
| Catch up with a view | `1095-1108` | `167-171` | Same-view catching-up is idempotent. Otherwise set view, ViewChange/catching status, reset waiting/tables, and request suffix after current commit. No attempts increment or synthetic election contribution. |
| Rejected Prepare/Commit side effects | `795-812` | `173-180` | Older view leaves state alone. Newer view initiates catch-up and rejects. Equal view always sets heard; an equal-view ViewChange node also catches up and rejects. Only a Normal backup accepts. Computing acceptance from the old state is equivalent because the mutating rejection branches never become accepting branches. |
| State-transfer responses | `842-893` | `243-264` | View mismatch returns before shape assertion/heard side effect. Equal view asserts suffix shape and marks heard even if later ignored. Same-view transfer requires an extending overlapping suffix, appends only unseen entries, commits, changes only status to Normal, and acknowledges. Cross-view catch-up requires exact current-commit anchor, replaces suffix, commits, calls enter-normal, and acknowledges. |
| Receive SVC | `906-921` | `266-273` | Old view ignored; new view adopted before inserting sender; equal-view non-ViewChange returns, with StartView resend only at a Normal primary. Otherwise record sender and maybe contribute DVC. |
| Receive DVC | `926-942` | `274-280` | Reject old view or a message whose proposed-view primary is another replica before adoption. New view starts election; equal-view Normal primary resends StartView. Other accepted statuses record/overwrite the sender report without an extra ViewChange guard. |
| Receive StartView | `948-967` | `281-286` | Equal-view acceptance is restricted to ViewChange; later views can be installed without an invented role guard. Install, commit without reply, enter Normal, clear acks, then emit PrepareOk. |
| Recovery firewall | `528-536,609,623` | `350-365` | A recovering replica ignores every non-RecoveryResponse before variant-specific assertions. Full-log shape assertions for DVC/StartView occur before their handler guards in both implementations. |
| Receive Recovery | `1131-1149` | `288-295` | A higher supplied persisted view starts a view change and returns without a response. Otherwise only Normal responds, with state only at its primary. Global recovery firewall handles Recovering recipients first. |
| Receive RecoveryResponse | `1159-1205` | `296-311` | Status/nonce rejection occurs before mutation. Sender report overwrites without monotonic-view filtering, then distinct response quorum, latest view not below persisted/current view, primary report presence, state presence, and exact primary-view match. Completion clears responses, sets view, installs/commits without reply, enters Normal, and emits no PrepareOk. |
| Recovery construction and retry | `511-524,1208-1214` | `313-315,451-460` | Start from fresh volatile/application state, set Recovering/current and last-normal persisted view/nonce, and broadcast Recovery. Retry reuses the current nonce and view. The model's used-nonce guard represents the explicit caller contract (`505-510`), not a new Rust validation check. |
| Stable timer | `1291-1295` | `316-318` | Increment stable count first; reset attempts when the incremented count reaches PrimaryTimeout. No stable-count cap is invented. |
| Timeout/backoff | `1302-1305` | `319,334-335,339-340` | Increment waiting exactly once per call and compare against `PrimaryTimeout * 2^min(attempts,10)`. The model moves the increment into callers. A timeout that starts another view increments attempts only after comparing with the old attempt count. |
| Primary idle | `1235-1253` | `320-327` | Note stable, broadcast Commit, then resend each uncommitted Prepare in increasing operation order, each to membership order excluding self. |
| Backup/transfer idle | `1256-1268` | `328-335` | In StateTransfer, retry GetState before heard swap and timeout evaluation. Heard true resets waiting and notes stable; otherwise reset stable and increment/test waiting. A timeout retains the already emitted old-view GetState before newly emitted SVC messages. |
| ViewChange idle | `1270-1283` | `336-348` | Increment/test timeout before retries. Catching-up retries GetState at commit; election retries SVC then, if previously sent, DVC, including synchronous self recording. Recovering idle only retransmits Recovery. |

## Boundaries and non-findings

- Timer counters and views are mathematical naturals; machine-integer overflow is explicitly excluded by `base.tla:8-10`. The audited bounded configurations do not approach Rust overflow. No overflow claim is inferred from this abstraction.
- The two Rust resulting-length assertions at `lib.rs:871,887` are not separate assertions in the corresponding model branches. Their equations follow from the checked suffix-shape relation, branch guards, and `commit <= Len(log)` for admitted invariant-satisfying states. This does not establish a reachable semantic difference.
- `N >= 2`, fresh recovery tokens, fresh client identities, atomic owner calls, and persist-before-output publication are explicit baseline assumptions. They must not be interpreted as validation of the separately retained singleton, startup, filesystem, sender, or allocator candidates.
- Nonce values are equality-only protocol identifiers. Trace normalization retains per-replica equality across requests/responses and restarts; canonical increasing MC nonces therefore implement the stated freshness assumption. No argument about the example's real clock policy or TCP stale-response reachability is made here.
- The retained trace corpus exercises view installation and stale recovery responses but does not establish exhaustive coverage of all quorum overwrite/tie-break/backoff branches. The correspondence table is static evidence supplementing the root's trace validation and invariant checking.
