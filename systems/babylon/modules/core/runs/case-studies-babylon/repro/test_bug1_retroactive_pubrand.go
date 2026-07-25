// Bug 1 — Retroactive Public Randomness Commits (#1984).
//
// Status: REPRODUCED at Level 0 (pure black-box, public MsgServer API).
//
// File-level note: this Go source is a standalone documentation extract of
// the test function `TestBug1_RetroactivePubRandCommit` that actually runs
// inside the babylon source tree at
//   artifact/babylon/x/finality/keeper/repro_specula_test.go
// (a copy of which sits next to this file as `repro_specula_test.go`).
//
// Reproduction: from artifact/babylon, run:
//   go test -v ./x/finality/keeper/ -run TestBug1_RetroactivePubRandCommit
//
// Observed output (verbatim):
//   === RUN   TestBug1_RetroactivePubRandCommit
//       repro_specula_test.go:91: Bug 1 reproduced: CommitPubRandList ACCEPTED a retroactive commit (startHeight=1 while currentHeight=5)
//   --- PASS: TestBug1_RetroactivePubRandCommit (0.01s)

// Test outline (the actual implementation is in repro_specula_test.go):
//
//   func TestBug1_RetroactivePubRandCommit(t *testing.T) {
//     r := rand.New(rand.NewSource(1))
//     _, ms, ctx, btcSK, _, _, ctrl, _, _, _ := newReproEnv(t, r)
//     defer ctrl.Finish()
//
//     // advance the chain so currentHeight = 5 (heights 1..5 produced)
//     ctx = ctx.WithHeaderInfo(header.Info{Height: 5})
//
//     // submit CommitPubRandList(startHeight=1, num=200) — RETROACTIVE
//     const startHeight = uint64(1)
//     const numPubRand = uint64(200)
//     _, msgCommit, err := datagen.GenRandomMsgCommitPubRandList(r, btcSK, startHeight, numPubRand)
//     require.NoError(t, err)
//     _, err = ms.CommitPubRandList(ctx, msgCommit)
//     // Bug: no error, the retroactive commit is accepted.
//     require.NoError(t, err)
//   }

package repro
