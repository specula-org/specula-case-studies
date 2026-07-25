// Bug 4 — CommitPubRandList accepts commits from slashed/jailed FP (T3).
//
// Status: REPRODUCED at Level 0 (pure black-box, public MsgServer API).
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug4_CommitPubRandFromSlashedFp
//
// Observed output (verbatim):
//   === RUN   TestBug4_CommitPubRandFromSlashedFp
//       repro_specula_test.go:243: Bug 4 reproduced: CommitPubRandList has NO IsSlashed/IsJailed guard — a slashed/jailed FP can still commit.
//       repro_specula_test.go:244: Note: this confirms the absence of the precondition check (T3 from the modeling brief);
//       repro_specula_test.go:245: the impact is gas-burn / state-bloat griefing rather than safety, but the contract gap is real.
//   --- PASS: TestBug4_CommitPubRandFromSlashedFp (0.01s)
//
// The bug:
//   x/finality/keeper/msg_server.go:286-394 — CommitPubRandList checks
//     - upper bound on StartHeight vs currentHeight+MaxPubRandCommitOffset
//     - HasFinalityProvider (FP registered)
//     - IsFinalityProviderDeleted (soft-delete check)
//     - VerifySig
//     - StartHeight > lastCommit.EndHeight (no overlap with own prior commit)
//   But does NOT check IsSlashed() or IsJailed().
//
// Compare AddFinalitySig (msg_server.go:117-122) which DOES guard:
//     if fp.IsSlashed() { return bstypes.ErrFpAlreadySlashed }
//     if fp.IsJailed()  { return bstypes.ErrFpAlreadyJailed  }
//
// Severity: medium-low. A slashed/jailed FP can grief by burning gas on
// commits that will never produce a valid vote. No state corruption,
// no safety violation; primarily a hygiene gap (T3 in modeling-brief.md).
//
// Test outline (the actual implementation is in repro_specula_test.go):
//
//   func TestBug4_CommitPubRandFromSlashedFp(t *testing.T) {
//     r := rand.New(rand.NewSource(4))
//     _, ms, ctx, btcSK, _, _, ctrl, _, _, _ := newReproEnv(t, r)
//     defer ctrl.Finish()
//
//     _, msgCommit, _ := datagen.GenRandomMsgCommitPubRandList(r, btcSK, 10, 200)
//     ctx = ctx.WithHeaderInfo(header.Info{Height: 5})
//     _, err := ms.CommitPubRandList(ctx, msgCommit)
//     require.NoError(t, err)
//     // No IsSlashed/IsJailed callback was issued by the keeper at any
//     // point on the gomock recorder, demonstrating the absence of the
//     // guard.
//   }

package repro
