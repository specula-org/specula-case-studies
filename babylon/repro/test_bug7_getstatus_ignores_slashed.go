// Bug 7 — BTCDelegation.GetStatus ignores FP Slashed (CR7).
//
// Status: REPRODUCED at Level 0 (pure black-box, direct call of the
// type's public method).
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug7_GetStatusIgnoresFpSlashed
//
// Observed output (verbatim):
//   === RUN   TestBug7_GetStatusIgnoresFpSlashed
//       repro_specula_test.go:368: Bug 7 reproduced at Level 0: BTCDelegation.GetStatus(1, 1, 0) returned ACTIVE with NO opportunity to incorporate an FP-level Slashed flag.
//       repro_specula_test.go:370: Bug 7 confirmed: the function's signature itself precludes per-call FP-status incorporation; any third-party query that calls GetStatus directly (e.g., gRPC BTCDelegation) gets a stale ACTIVE for a slashed-FP delegation.
//   --- PASS: TestBug7_GetStatusIgnoresFpSlashed (0.00s)
//
// The audit:
//   x/btcstaking/types/btc_delegation.go:119-162 — BTCDelegation.GetStatus
//
//     func (d *BTCDelegation) GetStatus(
//       btcHeight uint32,
//       covenantQuorum, quorumPreviousStk uint32,
//     ) BTCDelegationStatus { ... }
//
//   No FinalityProvider argument; no IsSlashed lookup. The slashing
//   filter happens at the power-distribution consumer
//   (x/finality/keeper/power_dist_change.go) — not in the query path.
//
// Consequence: any caller that asks the delegation "what is your status?"
// gets the delegation-local view (PENDING / VERIFIED / ACTIVE / EXPIRED
// / UNBONDED) regardless of whether the FP has been slashed.
// External tooling reading the gRPC BTCDelegation endpoint, which calls
// this same GetStatus(), receives a stale ACTIVE for delegations under
// a slashed FP until the consumer re-runs and zeroes their voting power.
//
// Test outline (the actual implementation is in repro_specula_test.go):
//
//   func TestBug7_GetStatusIgnoresFpSlashed(t *testing.T) {
//     covenantQuorum := uint32(1)
//     d := bstypes.BTCDelegation{
//       CovenantSigs: make([]*bstypes.CovenantAdaptorSignatures, covenantQuorum),
//       BtcUndelegation: &bstypes.BTCUndelegation{
//         CovenantUnbondingSigList: make([]*bstypes.SignatureInfo, covenantQuorum),
//         CovenantSlashingSigs:     make([]*bstypes.CovenantAdaptorSignatures, covenantQuorum),
//       },
//       StartHeight: 1,
//       EndHeight:   2,
//     }
//     status := d.GetStatus(1, covenantQuorum, 0)
//     require.Equal(t, bstypes.BTCDelegationStatus_ACTIVE, status)
//     // The function signature offers NO way to communicate FP-level
//     // slashed state into the answer; demonstrating bug by absence.
//   }

package repro
