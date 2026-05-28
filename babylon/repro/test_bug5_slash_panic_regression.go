// Bug 5 — slashFinalityProvider panic-on-error wrapper (CR4).
//
// Status: REPRODUCED at Level 2 (state-injection via mock — the
// underlying BTCStakingKeeper.SlashFinalityProvider is made to return an
// error to simulate a regression or new caller).
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug5_SlashWrapperPanicOnRegression
//
// Observed output (verbatim):
//   === RUN   TestBug5_SlashWrapperPanicOnRegression
//       repro_specula_test.go:301: Bug 5 reproduced (Level 2, state-injection via mock): slashFinalityProvider wrapper PANICKED with failed to slash finality provider: finality signature is not valid
//   --- PASS: TestBug5_SlashWrapperPanicOnRegression (0.01s)
//
// The bug (hardening):
//   x/finality/keeper/msg_server.go:457-461
//
//     func (k Keeper) slashFinalityProvider(ctx context.Context, ...) {
//       if err := k.BTCStakingKeeper.SlashFinalityProvider(ctx, ...); err != nil {
//         panic(fmt.Errorf("failed to slash finality provider: %v", err))
//       }
//       ...
//     }
//
// In current code, the panic is unreachable through the public
// AddFinalitySig path because IsSlashed/IsJailed checks at msg_server.go
// lines 117-122 reject the message before slashing is attempted.
// However, the wrapper is also called from the canonical-after-evidence
// branch (line 237). Any future code change that introduces a second
// caller, or that loosens the IsSlashed precondition, will turn an
// `ErrFpAlreadySlashed` (or any other backend error) into a chain halt.
//
// Recommendation: make the wrapper idempotent. Log and return on
// ErrFpAlreadySlashed; only panic on truly unrecoverable backend errors.
//
// Level escalation log:
//   Level 0 (pure black-box): cannot trigger the panic — IsSlashed/IsJailed
//   guards at the start of AddFinalitySig prevent reaching the slashing
//   wrapper for already-slashed FPs. The current AddFinalitySig handlers
//   never call slashFinalityProvider twice in one tx.
//   Level 1 (timing): not applicable — single-threaded Cosmos-SDK tx exec.
//   Level 2 (state injection): mocked BTCStakingKeeper.SlashFinalityProvider
//   returns an error → wrapper panics as predicted. This is the
//   regression-mode that CR4 flags.
//
// Test outline (the actual implementation is in repro_specula_test.go):
//
//   func TestBug5_SlashWrapperPanicOnRegression(t *testing.T) {
//     // ... set up FP + commit pub-rand, then submit a fork sig to seed evidence ...
//     ms.AddFinalitySig(ctx, msgFork)
//     // make the backend slash call fail (simulates a regression):
//     bs.EXPECT().SlashFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).
//         Return(types.ErrInvalidFinalitySig).Times(1)
//     // canonical sig now triggers the slashing wrapper which calls the
//     // backend — backend errors — wrapper panics.
//     defer func() {
//       require.NotNil(t, recover(), "expected panic from slashFinalityProvider wrapper")
//     }()
//     ms.AddFinalitySig(ctx, msgCanonical)
//   }

package repro
