# CometBFT evidence committed-marker reacceptance reproducer

This directory contains small Go reproducers for the evidence-pool bug where a failed committed-marker write can make already-committed evidence acceptable again, including after the evidence/state/block databases are closed and reopened.

## What it demonstrates

The evidence pool moves evidence from pending to committed in two separate database operations:

1. delete the pending evidence entry;
2. write the committed marker.

If the second write fails after the first delete succeeds, the same evidence is left in neither durable state. A later `CheckEvidence` call can then accept it again because the committed marker is missing.

`bugrepro_test.go` reproduces that state by wrapping the evidence DB. The wrapper lets the pending delete succeed, then fails the next `Set` call used for the committed marker.

`restart_repro_test.go` extends the same failure to a restart-style scenario. It uses on-disk `goleveldb` stores under `t.TempDir()`, lets `Pool.Update` delete the pending entry and fail the committed-marker write, saves the advanced state as `ApplyBlock` does after updating the evidence pool, closes the evidence/state/block databases, reopens them, rebuilds the evidence pool, and then checks the same evidence again. The affected implementation still returns `nil`.

The test is meant to be copied into CometBFT's existing `evidence/` test package. It intentionally reuses the package's existing test helpers such as `initializeValidatorState`, `initializeBlockStore`, `defaultEvidenceTime`, and `evidenceChainID`.

## How to run

From a CometBFT checkout:

```bash
cp *_test.go /path/to/cometbft/evidence/
cd /path/to/cometbft
go test ./evidence -run 'TestSpeculaCommittedMarkerWriteFailure(ReacceptsEvidence|SurvivesRestart)$' -count=1 -v
```

Or run the helper script from this directory:

```bash
./run.sh /path/to/cometbft
```

The helper detects both CometBFT layouts: `evidence/` and `internal/evidence/`.

## Expected result on affected versions

The test is written as a regression test for the expected behavior: after evidence has been committed, `CheckEvidence` should reject it even if the committed-marker write failed.

On the affected implementation, both tests fail because `CheckEvidence` returns `nil` and accepts the same evidence again. The restart test demonstrates that rebuilding the evidence pool from persistent stores does not repair the missing committed marker.

The observed log sequence is:

- `Deleted pending evidence`
- `Unable to save committed evidence`
- `Check evidence: verified evidence of byzantine behavior`

This shows that the pending entry was removed, the committed marker was not saved, and the same evidence was later accepted as fresh evidence. In the restart test, the final `CheckEvidence` call happens after the evidence, state, and block databases have been closed and reopened.

## Local validation

The original same-process reproducer was validated against CometBFT commit `5bba72c14f2be2b06ac4d89dbdf6712e2e5e095c` with Go `1.23.5`.

Both reproducers were also run with Go `1.23.5` against:

- `main` commit `4e907f47c40a17ae5b8b0104e99734026a47c97b`;
- `v1.x` commit `e069791d48381d4a2032087c760079f3a52f22d4`;
- `v0.38.x` commit `330d3bb191985448c76d2eae31d49b561cd5f44d`.

All three runs failed as expected on the affected implementation because `CheckEvidence` returned `nil` after the simulated committed-marker write failure. For `restart_repro_test.go`, this happened after closing and reopening the on-disk databases.
