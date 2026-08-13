# CometBFT evidence committed-marker reacceptance reproducer

This directory contains a small Go reproducer for the evidence-pool bug where a failed committed-marker write can make already-committed evidence acceptable again.

## What it demonstrates

The evidence pool moves evidence from pending to committed in two separate database operations:

1. delete the pending evidence entry;
2. write the committed marker.

If the second write fails after the first delete succeeds, the same evidence is left in neither durable state. A later `CheckEvidence` call can then accept it again because the committed marker is missing.

`bugrepro_test.go` reproduces that state by wrapping the evidence DB. The wrapper lets the pending delete succeed, then fails the next `Set` call used for the committed marker.

The test is meant to be copied into CometBFT's existing `evidence/` test package. It intentionally reuses the package's existing test helpers such as `initializeValidatorState`, `initializeBlockStore`, `defaultEvidenceTime`, and `evidenceChainID`.

## How to run

From a CometBFT checkout:

```bash
cp bugrepro_test.go /path/to/cometbft/evidence/specula_committed_marker_repro_test.go
cd /path/to/cometbft
go test ./evidence -run TestSpeculaCommittedMarkerWriteFailureReacceptsEvidence -count=1 -v
```

Or run the helper script from this directory:

```bash
./run.sh /path/to/cometbft
```

## Expected result on affected versions

The test is written as a regression test for the expected behavior: after evidence has been committed, `CheckEvidence` should reject it even if the committed-marker write failed.

On the affected implementation, the test fails because `CheckEvidence` returns `nil` and accepts the same evidence again.

The observed log sequence is:

- `Deleted pending evidence`
- `Unable to save committed evidence`
- `Check evidence: verified evidence of byzantine behavior`

This shows that the pending entry was removed, the committed marker was not saved, and the same evidence was later accepted as fresh evidence.

## Local validation

This reproducer was validated against CometBFT commit `5bba72c14f2be2b06ac4d89dbdf6712e2e5e095c` with Go `1.23.5`.

The test failed as expected on the affected implementation because the second `CheckEvidence` call returned `nil` after the simulated committed-marker write failure.
