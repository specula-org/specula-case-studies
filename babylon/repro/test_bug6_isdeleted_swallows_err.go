// Bug 6 — IsFinalityProviderDeleted swallows KV errors (CR6/T1).
//
// Status: REPRODUCTION FAILED — escalation ladder exhausted without
// triggering the bug through public test interfaces. The audit finding
// stands on code-review evidence alone.
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug6_IsFinalityProviderDeletedSwallowsErr
//
// Observed output (verbatim):
//   === RUN   TestBug6_IsFinalityProviderDeletedSwallowsErr
//       repro_specula_test.go:322: Bug 6 documentation-only test:
//       repro_specula_test.go:323:   IsFinalityProviderDeleted has the literal pattern:
//       repro_specula_test.go:324:     blocked, err := k.finalityProvidersDeleted.Has(ctx, ...)
//       repro_specula_test.go:325:     if err != nil { return true }   // <-- swallowed, fail-closed
//       repro_specula_test.go:326:     return blocked
//       repro_specula_test.go:327: Black-box (Level 0/1) reproduction: NOT POSSIBLE — the in-memory KV store does not error.
//       repro_specula_test.go:328: State-injection (Level 2): would require swapping the keeper's underlying store with one that errors,
//       repro_specula_test.go:329: which violates the 'use public interfaces' rule.
//       repro_specula_test.go:330: Code modification (Level 3): trivially demonstrable but tautological.
//       repro_specula_test.go:331: Conclusion: REPRODUCTION FAILED; the audit finding (contract gap, silent fail-closed) stands.
//   --- PASS: TestBug6_IsFinalityProviderDeletedSwallowsErr (0.00s)
//
// The audit:
//   x/btcstaking/keeper/finality_providers.go:132-138
//
//     func (k Keeper) IsFinalityProviderDeleted(ctx context.Context, fpBtcPk *bbn.BIP340PubKey) bool {
//       blocked, err := k.finalityProvidersDeleted.Has(ctx, fpBtcPk.MustMarshal())
//       if err != nil {
//         return true                  // <-- silent fail-closed; callers cannot distinguish lookup error from "is deleted"
//       }
//       return blocked
//     }
//
// Callers (AddFinalitySig, CommitPubRandList, grpc_query.FinalityProviders,
// btc_delegations.NewBTCDelegation et al.) treat the bool return as
// authoritative. A transient KV failure silently turns valid messages
// into ErrFinalityProviderIsDeleted rejections.
//
// Escalation log:
//   Level 0 (black-box via public API):
//     dbm.NewMemDB() does not error on Has(). No way to provoke from
//     userspace.
//   Level 1 (timing):
//     Not applicable — Has() is synchronous and deterministic.
//   Level 2 (state injection):
//     Would require swapping the FinalityKeeper's backing store with a
//     custom corestore.KVStoreService whose Has() returns an error.
//     This is not exposed by testutil/keeper.FinalityKeeper, and
//     constructing one ad-hoc bypasses the public test interface.
//   Level 3 (minimal code modification):
//     Would tautologically demonstrate the panic on a manufactured error;
//     skipped because the bug claim is about a code pattern, not a race.
//
// Conclusion: the bug is real per the code (contract gap, silent
// fail-closed), but cannot be reached through normal use; severity LOW.

package repro
