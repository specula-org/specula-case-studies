// Bug 3 — Fork-fork evidence overwrite at the same (fp, h).
//
// Status: REPRODUCED at Level 0 (pure black-box, public MsgServer API).
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug3_ForkForkEvidenceOverwrite
//
// Observed output (verbatim):
//   === RUN   TestBug3_ForkForkEvidenceOverwrite
//       repro_specula_test.go:215: Bug 3 reproduced: the on-chain evidence at (fp, h=1) was OVERWRITTEN; the first ForkAppHash is lost.
//       repro_specula_test.go:216: Bug 3 reproduced: IsSlashable()=false for fork-only evidence, so the in-protocol slashing pipeline never fires for the pair of fork sigs.
//   --- PASS: TestBug3_ForkForkEvidenceOverwrite (0.01s)
//
// The bug has two components:
//
//   (A) x/finality/keeper/evidence.go:13-16 — SetEvidence stores the
//       Evidence record at key (fpBtcPk, blockHeight). A second fork-sig
//       at the same (fp,h) overwrites the first; the first ForkAppHash
//       and ForkFinalitySig are lost from the chain state.
//
//   (B) x/finality/types/finality.go:226-234 — Evidence.IsSlashable()
//       requires CanonicalFinalitySig != nil. Two distinct fork sigs at
//       the same height under the same pub-rand mathematically reveal
//       the FP's BTC SK, but the on-chain Evidence struct cannot hold
//       two fork sigs and the slashing pipeline never fires.
//
// Maintainer intent (per x/finality/README.md): the slashing flow relies
// on an external observer (the vigilante daemon) to derive the SK
// off-chain when both a canonical and a fork sig are seen. The fork-fork
// case is not formally addressed; the bug-report.md verdict notes that
// `AddFinalitySigFork only sets the latest fork sig (overwrite, by
// design)`. Treat the on-chain evidence DB as lossy with respect to
// fork-fork double-signs.
//
// Test outline (the actual implementation is in repro_specula_test.go):
//
//   func TestBug3_ForkForkEvidenceOverwrite(t *testing.T) {
//     r := rand.New(rand.NewSource(3))
//     fk, ms, ctx, btcSK, fpBTCPK, fpBTCPKBytes, ctrl, bs, _, _ := newReproEnv(t, r)
//     defer ctrl.Finish()
//
//     fp, _ := datagen.GenRandomFinalityProviderWithBTCSK(r, btcSK)
//     bs.EXPECT().GetFinalityProvider(gomock.Any(), gomock.Eq(fpBTCPKBytes)).Return(fp, nil).AnyTimes()
//
//     randListInfo, msgCommit, _ := datagen.GenRandomMsgCommitPubRandList(r, btcSK, 0, 200)
//     ms.CommitPubRandList(ctx, msgCommit)
//
//     canonical := datagen.GenRandomByteArray(r, 32)
//     fork1 := datagen.GenRandomByteArray(r, 32)
//     fork2 := datagen.GenRandomByteArray(r, 32)
//     ctx = ctx.WithHeaderInfo(header.Info{Height: 1, AppHash: canonical})
//     fk.IndexBlock(ctx); fk.SetVotingPower(ctx, fpBTCPKBytes, 1, 1)
//
//     msg1, _ := datagen.NewMsgAddFinalitySig(signer, btcSK, 0, 1, randListInfo, fork1)
//     ms.AddFinalitySig(ctx, msg1)
//     ev1, _ := fk.GetEvidence(ctx, fpBTCPK, 1)
//     require.False(t, ev1.IsSlashable())
//
//     msg2, _ := datagen.NewMsgAddFinalitySig(signer, btcSK, 0, 1, randListInfo, fork2)
//     ms.AddFinalitySig(ctx, msg2)
//     ev2, _ := fk.GetEvidence(ctx, fpBTCPK, 1)
//     require.Equal(t, fork2, ev2.ForkAppHash)    // first overwritten
//     require.False(t, ev2.IsSlashable())          // fork-only never auto-slashable
//   }

package repro
