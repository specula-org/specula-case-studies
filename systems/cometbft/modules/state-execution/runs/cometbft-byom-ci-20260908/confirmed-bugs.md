# Confirmation Report — cometbft

## Final Result

Reproduced bugs: 0 = 0 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 3
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 3
Dispositions: 3 total = 0 reproduced + 0 env-limited + 0 masked + 3 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | FALSE POSITIVE | no |
| 2 | CR-2 | FALSE POSITIVE | no |
| 3 | CR-3 | FALSE POSITIVE | no |

## Entry 1: Parameter update validation and installation

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: internal/state/execution.go:254

## Description

CR-1 is not a defect in this revision. `ApplyBlock` deliberately persists the `FinalizeBlockResponse` before validation, but derives consensus parameters in a copy. Rejected updates leave both input and persisted consensus state unchanged and never reach application `Commit`; accepted updates become active at H+1.

## Trigger scenario

Using the public `BlockExecutor.ApplyBlock` path with a real local ABCI connection, the test exercised:

1. A complete update rejected by `ValidateBasic`.
2. A partial subrecord rejected by `ValidateBasic`.
3. A basic-valid update rejected by `ValidateUpdate`.
4. An accepted update installed and persisted for H+1.
5. The rejected path with a 25 ms `FinalizeBlock` delay.

## Developer intent

The source documents that non-empty parameter subrecords are applied in full and H updates activate at H+1 (`spec/abci/abci++_app_requirements.md:779-807`). Response persistence is explicitly for crash recovery between application `Commit` and state save (`internal/state/store.go:562-565`).

Recovery only consumes the stored response through a mock app when the application already reports height H (`internal/consensus/replay.go:417-433`). Rejection occurs before `Commit`, so that precondition is unreachable for a rejected update.

The upstream search included open/closed issues and merged/closed PRs. The closest results—[#2109](https://github.com/cometbft/cometbft/issues/2109), [#2112](https://github.com/cometbft/cometbft/pull/2112), [#1976](https://github.com/cometbft/cometbft/issues/1976), [#2017](https://github.com/cometbft/cometbft/pull/2017), and [#3354](https://github.com/cometbft/cometbft/issues/3354)—concern different mechanisms.

## Reproduction result

Test:

`repro/test_bugCR-1_parameter_update_validation.sh`

Command:

```text
timeout 12m /home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/repro/test_bugCR-1_parameter_update_validation.sh
```

Actual output:

```text
=== RUN   TestBugCR1ParameterUpdateValidationAndInstallation
=== RUN   TestBugCR1ParameterUpdateValidationAndInstallation/level0_complete_update_rejected_by_ValidateBasic
    cr1_parameter_update_repro_test.go:169: complete-invalid: rejected="commit failed for application: validating new consensus params: block.MaxBytes cannot be 0" input_height=0 persisted_height=0 commit_calls=0 response_durable=true
=== RUN   TestBugCR1ParameterUpdateValidationAndInstallation/level0_partial_subrecord_rejected_by_ValidateBasic
    cr1_parameter_update_repro_test.go:180: partial-invalid: rejected="commit failed for application: validating new consensus params: evidence.MaxAgeDuration must be grater than 0 if provided, Got 0s" input_height=0 persisted_height=0 commit_calls=0 response_durable=true
=== RUN   TestBugCR1ParameterUpdateValidationAndInstallation/level0_basic_valid_transition_rejected_by_ValidateUpdate
    cr1_parameter_update_repro_test.go:187: transition-invalid: rejected="commit failed for application: updating consensus params: VoteExtensionsEnableHeight cannot be updated to a past height, initial height: 0, current height 1" input_height=0 persisted_height=0 commit_calls=0 response_durable=true
=== RUN   TestBugCR1ParameterUpdateValidationAndInstallation/level0_accepted_update_is_installed_for_H_plus_1
    cr1_parameter_update_repro_test.go:214: accepted: block_height=1 state_height=1 active_height=2 app_version=7 commit_calls=1
=== RUN   TestBugCR1ParameterUpdateValidationAndInstallation/level1_finalize_delay_does_not_cross_validation_commit_boundary
    cr1_parameter_update_repro_test.go:228: timing-assisted-invalid: rejected="commit failed for application: validating new consensus params: block.MaxBytes cannot be 0" input_height=0 persisted_height=0 commit_calls=0 response_durable=true
--- PASS: TestBugCR1ParameterUpdateValidationAndInstallation (0.03s)
    --- PASS: TestBugCR1ParameterUpdateValidationAndInstallation/level0_complete_update_rejected_by_ValidateBasic (0.00s)
    --- PASS: TestBugCR1ParameterUpdateValidationAndInstallation/level0_partial_subrecord_rejected_by_ValidateBasic (0.00s)
    --- PASS: TestBugCR1ParameterUpdateValidationAndInstallation/level0_basic_valid_transition_rejected_by_ValidateUpdate (0.00s)
    --- PASS: TestBugCR1ParameterUpdateValidationAndInstallation/level0_accepted_update_is_installed_for_H_plus_1 (0.00s)
    --- PASS: TestBugCR1ParameterUpdateValidationAndInstallation/level1_finalize_delay_does_not_cross_validation_commit_boundary (0.03s)
=== RUN   TestBugCR1EscalationSoundness
    cr1_parameter_update_repro_test.go:242: levels2-3: not injected/patched; rejected updates cannot reach app height H because Commit calls=0
--- PASS: TestBugCR1EscalationSoundness (0.00s)
PASS
ok  	github.com/cometbft/cometbft/internal/state	0.036s
```

Level 0 and Level 1 did not produce a wrong outcome. Level 2 was not admissible: its only concerning injected condition—application height H after rejection—cannot be reached through the real sequence `FinalizeBlock → persist response → validation error → no Commit`. Level 3 delays cannot alter that deterministic order.

No real caller observes incorrect active consensus parameters. The durable response is not installed state, and recovery selects the real-application replay branch after rejection. There is therefore no permanent bad state and no separate defect being masked.

Relevant regressions also passed:

```text
ok  github.com/cometbft/cometbft/types
ok  github.com/cometbft/cometbft/internal/state
```

## Recommendation

No production repair is warranted. Retain the reproduction as a regression test documenting response durability, rejection atomicity, and H+1 activation.

---

## Entry 2: Ordered durable boundaries during block application

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: internal/state/execution.go:219-299
- **Severity**: High (candidate)

## Description

The non-atomic persistence boundaries are real, but they are an intentional recovery protocol rather than a defect. Across every exercised boundary, startup handshake reconstructed the height-1 response and height-2 consensus parameters before their real RPC consumers used them.

## Trigger scenario

A normal one-validator node processed height 1 while its application returned `Block.MaxBytes=20000000` for height 2. Source-provided fault hooks stopped processing after block storage, WAL synchronization, `FinalizeBlock`, response persistence, application commit, and CometBFT state persistence.

No malformed input, unreachable state, or core-logic patch was used.

## Developer intent

`internal/consensus/replay.go:388-433` explicitly handles the possible block/state/application height combinations. `node/node.go:347-358` runs this handshake and reloads state during `NewNode`, before normal node operation resumes.

Upstream [issue #203](https://github.com/cometbft/cometbft/issues/203) and [PR #469](https://github.com/cometbft/cometbft/pull/469) document this persistence and recovery contract. Searches including closed and recently merged PRs found no report of parameters remaining incorrect after this recovery mechanism.

Full record: [investigation.md](/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-2/investigation.md)

## Reproduction result

Test: [test_bugCR-2_ordered_durable_boundaries.go](/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/repro/test_bugCR-2_ordered_durable_boundaries.go)

Executed command:

```sh
ln -s /home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/repro/test_bugCR-2_ordered_durable_boundaries.go internal/consensus/cr2_ordered_durable_boundaries_repro_test.go &&
timeout 10m go test ./internal/consensus -run '^TestBugCR2OrderedDurableBoundaries$' -count=1 -v
```

Recorded output:

```text
=== RUN   TestBugCR2OrderedDurableBoundaries
LEVEL0 BASELINE node_height=2 app_height=2 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=3 block=1 state=0 app=0 response_h1=false params_h2=false marker="*** fail-test 3 ***"
LEVEL1 index=3 RECOVER node_height=2 app_height=1 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=4 block=1 state=0 app=0 response_h1=false params_h2=false marker="*** fail-test 4 ***"
LEVEL1 index=4 RECOVER node_height=2 app_height=2 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=5 block=1 state=0 app=0 response_h1=false params_h2=false marker="*** fail-test 5 ***"
LEVEL1 index=5 RECOVER node_height=2 app_height=2 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=6 block=1 state=0 app=0 response_h1=true params_h2=false marker="*** fail-test 6 ***"
LEVEL1 index=6 RECOVER node_height=2 app_height=2 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=7 block=1 state=0 app=1 response_h1=true params_h2=false marker="*** fail-test 7 ***"
LEVEL2 reachable_sequence=NewNode->consensus_height_1->FinalizeBlock->SaveFinalizeBlockResponse->Commit->fail_hook RECOVER node_height=2 app_height=2 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=7 RECOVER node_height=2 app_height=1 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL1 index=8 block=1 state=1 app=1 response_h1=true params_h2=true marker="*** fail-test 8 ***"
LEVEL1 index=8 RECOVER node_height=2 app_height=2 results_h1_max_bytes=20000000 params_h2_max_bytes=20000000
LEVEL3 not-applied: exact source-provided boundary hooks already dominate delay-only timing assistance
RESULT no wrong public outcome observed; all reachable boundary snapshots recovered the height-1 response and height-2 consensus parameters
--- PASS: TestBugCR2OrderedDurableBoundaries (2.31s)
PASS
ok  	github.com/cometbft/cometbft/internal/consensus	2.324s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger a bug? **No.**
2. Level 2 reused a naturally reached snapshot from: `NewNode → height 1 consensus → FinalizeBlock → SaveFinalizeBlockResponse → Commit → fault hook`. It also produced no wrong outcome.
3. Real consumers `rpc/core/blocks.go:181-198` and `rpc/core/consensus.go:99-117` observed the correct response and parameters.
4. The intermediate durable combinations are transient and resolved by `Handshaker.ReplayBlocks`. This is the intended correctness mechanism, not a separate defect masking live harm.

## Recommendation

No CR-2 production fix is warranted. Retain the focused recovery test as regression coverage, especially the application-committed/state-not-saved case. No source, specification, configuration, instrumentation, harness, or trace asset was changed; the temporary test link was removed and the source worktree is clean.

---

## Entry 3: Height-matrix startup replay

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: internal/consensus/replay.go:358
- **Severity**: High (candidate metadata)

## Description

CR-3 does not expose an incorrect transition on source `af998de26e82b796590b14fb2417864fc3c31202`. Every supported application/block-store/state-store height relation synchronized the durable heights and consensus parameters; unsupported relations stopped startup before normal operation.

## Trigger scenario

The test exercised:

- No replay: `A=B=S=2`.
- App-only replay: `A=0, B=S=2`.
- Real final-block replay: `A=S=1, B=2`.
- Historical plus real-final replay: `A=0, S=1, B=2`.
- Saved-response recovery after application commit but before state save: `A=B=2, S=1`.
- Pruned-store boundary and all unsupported relationships.

The commit-before-state-save state was generated through the real sequence:

```text
SaveBlock(2) -> FinalizeBlock(2) -> SaveFinalizeBlockResponse(2)
-> Commit(2) -> interrupted Save(state@2) -> restart Handshake
```

## Developer intent

The implementation deliberately maps these crash cuts to app-only, real-app, mock-app, or no replay. The stored final response exists specifically to recover after application commit but before state persistence.

The required issue/PR search covered open, closed, and recently merged records. Related reports were different mechanisms: [issue #2109](https://github.com/cometbft/cometbft/issues/2109) concerns vote-extension update validation, [issue #3140](https://github.com/cometbft/cometbft/issues/3140) concerns a corrupt snapshot loading a nil block, and [PR #2017](https://github.com/cometbft/cometbft/pull/2017) is a response-persistence optimization.

## Reproduction result

Reproducer: [test_bugCR-3_height_matrix.go](/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/repro/test_bugCR-3_height_matrix.go)

Exact command:

```sh
set -o pipefail
timeout 10m go test -vet=off -overlay=/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-3/repro-overlay.json ./internal/consensus -run '^TestBugCR3HeightMatrix$' -count=1 -v
```

Captured output:

```text
CR3|level=0|case=no-replay|A=2 B=2 S=2|result=synchronized|real-app-calls=0
CR3|level=0|case=app-only|A=0 B=2 S=2|result=synchronized|ExecCommitBlock=2
CR3|level=0|case=real-last|A=1 B=2 S=1|result=synchronized|ApplyBlock-real=1
CR3|level=0|case=historical-plus-real-last|A=0 B=2 S=1|result=synchronized|ExecCommitBlock=1 ApplyBlock-real=1
CR3|level=1|case=saved-response-mock-last|A=2 B=2 S=1|result=synchronized|real-app-recommit=0|consumer=BlockExecutor.ValidateBlock(height=3)
CR3|level=2|case=pruned-boundary-supported|A=1 base=2 B=2 S=2|result=synchronized
CR3|level=2|case=app-below-pruned-base|A=0 base=2 B=2 S=2|result=rejected-before-normal-operation
CR3|level=2|case=app-ahead|A=3 B=2 S=2|result=rejected-before-normal-operation
CR3|level=2|case=negative-app-height|A=-1 B=2 S=1|result=rejected-before-normal-operation
CR3|level=2|case=state-ahead|A=1 B=1 S=2|result=panic-before-normal-operation
CR3|level=2|case=store-two-ahead|A=0 B=2 S=0|result=panic-before-normal-operation
CR3|level=3|case=deterministic-height-dispatch|result=delay-inapplicable; no source logic modified
CR3|summary|live-harm=not-observed|all-supported-cases-synchronized|all-unsupported-cases-rejected
--- PASS: TestBugCR3HeightMatrix (0.10s)
PASS
ok  	github.com/cometbft/cometbft/internal/consensus	0.117s
```

Reproduction outcome: **FAIL—the claimed bug did not trigger**; the Go harness itself passed. Normal vet-enabled regressions also passed:

```text
ok  	github.com/cometbft/cometbft/internal/consensus	3.536s
ok  	github.com/cometbft/cometbft/internal/state	0.011s
```

Reproduction-bar answers:

1. Did Level 0 or Level 1 trigger live harm? **no**.
2. The reachable Level 2 boundary sequence is shown above; impossible height relations were tested only to verify guards, not as bug evidence. Level 3 made no source modification.
3. Wrong real consumer: **none**. `BlockExecutor.ValidateBlock` consumed the recovered state and accepted the correctly parameterized height-3 block.
4. Permanent or masked: **neither**. No bad state was produced; the saved-response replay is the intended recovery algorithm, not a separate masking mechanism.

Full records: [investigation.md](/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-3/investigation.md), [reproduction.md](/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-3/reproduction.md), and [reproduction-output.txt](/home/ubuntu/specula-ci-byom-acceptance-20260908-qkmsf06i/ci/runs/20260908-065730-af7a/cometbft/.specula-output/confirmation/CR-3/reproduction-output.txt).

## Recommendation

Do not change production code for CR-3. Retain the focused height-matrix test as regression coverage for consensus-parameter recovery. No repair request was created because this is code-review-sourced and no model artifact requires repair.

---
