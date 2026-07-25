package consensus

// byz_state.go — additional harness-side state attached to *State.
//
// These fields are NOT part of CometBFT proper. They exist only to compose
// trace-side bookkeeping (signed-vote shadow set, byzantine local clock,
// pending-evidence shadow) with the honest path of the real state machine.
// They never feed back into consensus decisions.

// byzSignedVote is a shadow record matching VoteRecord(...) in spec/base.tla.
type byzSignedVote struct {
	Signer string
	VType  string
	Height int64
	Round  int32
	Value  string
	VE     string
}

// byzAddSignedVote records a signed vote in cs.byzSignedVotes (idempotent).
func (cs *State) byzAddSignedVote(signer, vtype string, h int64, r int32, value, ve string) {
	if cs.byzSignedVotes == nil {
		cs.byzSignedVotes = make(map[string][]byzSignedVote)
	}
	rec := byzSignedVote{
		Signer: signer,
		VType:  vtype,
		Height: h,
		Round:  r,
		Value:  value,
		VE:     ve,
	}
	for _, existing := range cs.byzSignedVotes[signer] {
		if existing == rec {
			return
		}
	}
	cs.byzSignedVotes[signer] = append(cs.byzSignedVotes[signer], rec)
}

// byzAdvanceClock increments cs.byzClock by one tick.
func (cs *State) byzAdvanceClock() {
	cs.byzClock++
}
