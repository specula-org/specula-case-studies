# Babylon Bug Reproduction Suite

This directory holds the executable reproduction tests for the bugs surfaced
by the Specula bug-confirmation pass on `babylonlabs-io/babylon@d96cd9d`.

## Layout

| File | Bug | Status |
|------|-----|--------|
| `test_bug1_retroactive_pubrand.go` | F1: Retroactive pub-rand commits (#1984) | REPRODUCED (Level 0) |
| `test_bug2_jailing_bypass.go` | F2: Jailing bypass via active toggle (#1852) | REPRODUCED (Level 1) |
| `test_bug3_fork_fork_overwrite.go` | F1: Fork-fork evidence overwrite | REPRODUCED (Level 0) |
| `test_bug4_commit_pubrand_slashed.go` | T3: CommitPubRandList accepts slashed FP | REPRODUCED (Level 0) |
| `test_bug5_slash_panic_regression.go` | CR4: Panic-on-error in slashFinalityProvider | REPRODUCED (Level 2) |
| `test_bug6_isdeleted_swallows_err.go` | CR6/T1: IsFinalityProviderDeleted silent fail-closed | REPRODUCTION FAILED |
| `test_bug7_getstatus_ignores_slashed.go` | CR7: BTCDelegation.GetStatus ignores FP Slashed | REPRODUCED (Level 0) |

All seven tests are bundled into a single Go test file in the babylon source
tree at `artifact/babylon/x/finality/keeper/repro_specula_test.go`. The
per-bug files in this directory are documentation copies of the individual
test functions for review convenience; they share imports and a setup
helper with the bundled file.

## Running

```bash
cd artifact/babylon
go test -v ./x/finality/keeper/ -run TestBug
```

Or run a single bug:

```bash
go test -v ./x/finality/keeper/ -run TestBug1_RetroactivePubRandCommit
```

## Notes

- The mock setup helper `newReproEnv` is defined once at the top of
  `repro_specula_test.go`. The per-bug files in this directory inline a
  reference to it; the actual definition is in the bundled file.
- All tests use the existing `testutil/keeper.FinalityKeeper` harness with
  gomock-based BTCStaking/Checkpointing/Incentive mocks, identical in
  pattern to the upstream `x/finality/keeper/msg_server_test.go` tests.
