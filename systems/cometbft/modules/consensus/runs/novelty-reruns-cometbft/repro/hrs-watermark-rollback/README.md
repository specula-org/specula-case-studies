# CometBFT FilePV HRS rollback reproducer

This directory contains a focused reproducer for the FilePV HRS-watermark durability gap.

## What it demonstrates

CometBFT's `FilePV` uses `priv_validator_state.json` as the local anti-double-signing watermark. After signing, `FilePV.SignVote` updates the last signed height/round/step and persists it through:

- `privval/file.go`: `FilePV.signVote` -> `saveSigned` -> `FilePVLastSignState.Save`
- `libs/tempfile/tempfile.go`: `WriteFileAtomic`

On the affected implementation, the temp file is opened with `O_SYNC` and then renamed onto `priv_validator_state.json`, but the parent directory is not fsync'd after the rename. That leaves a power-loss window where the state file's directory entry can roll back even after `SignVote` returned.

The public reproducer has two parts:

1. A real-path syscall probe: it drives `FilePV.SignVote`, traces the write, and checks for a rename to `priv_validator_state.json` with no `fsync`/`fdatasync`/`syncfs`.
2. A deterministic rollback-consequence test: it signs vote A, confirms the live FilePV correctly rejects a conflicting vote B at the same height/round/step, restores the pre-sign state file, reloads FilePV, and shows the same validator key can sign vote B. Both signatures verify and the signed bytes differ. This second part is a Level-2 state-injection test: it proves the consequence of the reachable rollback state, not that the test itself caused a real power-loss rollback.

This is intentionally scoped. It demonstrates the reachable rollback consequence, not a real hardware power-loss run and not a live network slashing event.

## How to run

From this directory:

```bash
./run.sh /path/to/cometbft
```

The helper copies one temporary Go test file into `/path/to/cometbft/privval`, runs the two focused tests, and removes the temporary file on exit.

The test was written against CometBFT main commit `4e907f47c40a17ae5b8b0104e99734026a47c97b`.

Relevant upstream source:

- `privval/file.go`: <https://github.com/cometbft/cometbft/blob/4e907f47c40a17ae5b8b0104e99734026a47c97b/privval/file.go>
- `libs/tempfile/tempfile.go`: <https://github.com/cometbft/cometbft/blob/4e907f47c40a17ae5b8b0104e99734026a47c97b/libs/tempfile/tempfile.go>

## Expected affected output

The rollback-consequence test should pass and include:

```text
SPECULA_DOUBLE_SIGN_CONSEQUENCE: rollback allowed conflicting signatures at same H/R/S
```

The syscall probe should show a rename to `priv_validator_state.json` and zero directory-sync calls:

```text
rename calls to priv_validator_state.json : 1
fsync/fdatasync/syncfs calls              : 0
```

Interpretation:

- Directly demonstrated: if the HRS state file rolls back, FilePV can sign conflicting votes for the same height/round/step.
- Directly demonstrated: the current SignVote persistence path does not issue a parent-directory sync after the atomic rename.
- Not directly demonstrated: a full real power-loss crash causing the rollback in a live validator deployment.

## Local validation

Validated on 2026-08-14 against CometBFT main commit `4e907f47c40a17ae5b8b0104e99734026a47c97b`:

```bash
timeout 10m ./run.sh /home/ubuntu/tmp/specula-first-issue-review-cometbft-20260813
```

Key output:

```text
SPECULA_DOUBLE_SIGN_CONSEQUENCE: rollback allowed conflicting signatures at same H/R/S height=100 round=0 type=SIGNED_MSG_TYPE_PREVOTE
open temp file with O_SYNC calls        : 1
rename calls to priv_validator_state.json : 1
fsync/fdatasync/syncfs calls              : 0
SPECULA_HRS_DURABILITY_GAP: SignVote persisted the HRS state through an atomic rename without a parent-directory sync.
```
