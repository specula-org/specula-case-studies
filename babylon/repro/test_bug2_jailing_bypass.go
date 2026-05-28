// Bug 2 — Jailing bypass via active toggle (#1852, Immunefi #56201).
//
// Status: REPRODUCED at Level 1 (state setup via keeper public method,
// then exercise via HandleActivatedFinalityProvider).
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug2_JailingBypassActiveToggle
//
// Observed output (verbatim):
//   === RUN   TestBug2_JailingBypassActiveToggle
//       repro_specula_test.go:123: After Activate: StartHeight=110 MissedBlocksCounter=1
//       repro_specula_test.go:141: Bug 2 reproduced: counter=1 (>0) and bitmap[3]=true survived HandleActivatedFinalityProvider; new misses landing on modular index 3 become no-ops (previous=true && missed=true => skip)
//       repro_specula_test.go:154: Bug 2 confirmed: a fresh miss at modular index 3 was silently absorbed by the stale bitmap bit
//   --- PASS: TestBug2_JailingBypassActiveToggle (0.00s)
//
// The bug:
//   x/finality/keeper/power_dist_change.go:197-211 — HandleActivatedFinalityProvider
//   resets StartHeight (=> JailedUntil) but does NOT call
//   ResetMissedBlocksCounter and does NOT clear the missed-block bitmap.
//
// Consequence: after re-activation,
//   index = (height - StartHeight) % SignedBlocksWindow
// can collide with a bitmap position that was set during the prior active
// window. In UpdateSigningInfo, the case `previous=true && missed=true`
// falls into the default branch (no counter increment), so the new miss
// is silently absorbed. A persistent malicious oscillation around the
// window boundary keeps the FP from ever reaching maxMissed.
//
// Test outline (the actual implementation is in repro_specula_test.go):
//
//   func TestBug2_JailingBypassActiveToggle(t *testing.T) {
//     r := rand.New(rand.NewSource(2))
//     fk, _, ctx, _, fpBTCPK, _, ctrl, _, _, _ := newReproEnv(t, r)
//     defer ctrl.Finish()
//
//     si := types.NewFinalityProviderSigningInfo(fpBTCPK, 100, 1)
//     require.NoError(t, fk.FinalityProviderSigningTracker.Set(ctx, fpBTCPK.MustMarshal(), si))
//     index := int64(3)
//     require.NoError(t, fk.SetMissedBlockBitmapValue(ctx, fpBTCPK, index, true))
//
//     ctx = ctx.WithHeaderInfo(header.Info{Height: 110})
//     require.NoError(t, fk.HandleActivatedFinalityProvider(ctx, fpBTCPK))
//
//     siAfter, _ := fk.FinalityProviderSigningTracker.Get(ctx, fpBTCPK.MustMarshal())
//     require.Equal(t, int64(1), siAfter.MissedBlocksCounter)   // counter NOT reset
//     require.Equal(t, int64(110), siAfter.StartHeight)         // StartHeight advanced
//
//     bit, _ := fk.GetMissedBlockBitmapValue(ctx, fpBTCPK, index)
//     require.True(t, bit)                                      // bitmap NOT cleared
//
//     // fresh miss at modular index 3 is absorbed by the stale bit
//     modified, _, _ := fk.UpdateSigningInfo(ctx, fpBTCPK, true, int64(siAfter.StartHeight)+3)
//     require.False(t, modified)                                // miss silently dropped
//   }

package repro
