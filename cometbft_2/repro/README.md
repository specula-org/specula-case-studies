# Reproduction tests — cometbft_2 confirmed bugs

## Layout

| File | Bug | Source | Status |
|------|-----|--------|--------|
| `bug1_doublesign/main.go` | #5435 DoubleSignCheckHeight=1 zero iterations | `consensus/state.go:2719` | REPRODUCED |
| `test_bug2_verifyadjacent_lastblockid_test.go` | #2252 VerifyAdjacent missing LastBlockID check | `light/verifier.go:92-131` | REPRODUCED |
| `test_bug3_ve_signature_missing_blockid_binding_test.go` | Family 3 — VE signature not bound to BlockID | `types/canonical.go:71-78` | REPRODUCED |
| `test_bug4_polround_ge_round_validatebasic_test.go` | CR-7 POLRound >= Round passes ValidateBasic | `types/proposal.go:59-61` | REPRODUCED |
| `test_bug5_consensusbuffer_drops_future_height_test.go` | CR-3 / TV-2 consensusBuffer drops future-height votes | `evidence/pool.go:502-509,538` | REPRODUCED |

## Running

The tests live in a Go module that points at the cometbft artifact under
`../artifact/cometbft` via a `replace` directive in `go.mod`. The Go
toolchain used during reproduction was `go1.25.8`.

```bash
GO=/home/ubuntu/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.25.8.linux-amd64/bin/go

# Bug 1: standalone Go program (non-zero exit means "bug present").
$GO run ./bug1_doublesign

# Bugs 2-5: Go tests. `FAIL` outcome means "bug present".
$GO test -v .
```

Captured outputs are in `bug1_output.txt` and `all_tests_output.txt`.

## Methodology

All five reproductions are **Level 0** — pure black-box invocations of
public API surface. None mutates the system under test, and none injects
inconsistent state below a public entry point. Where a test needed a
runtime evidence pool (Bug 5), the standard mocks shipped with the
artifact (`evidence/mocks`, `state/mocks`) are used so the pool's
external surfaces (`stateStore.Load`, `blockStore.LoadBlockMeta`) are
satisfied without modification of pool internals.
