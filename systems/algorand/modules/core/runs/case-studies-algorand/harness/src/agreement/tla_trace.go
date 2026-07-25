// Package agreement: TLA+ trace emission for trace validation.
//
// This file is added by the Specula harness. It emits NDJSON lines to a
// trace file specified by the SPECULA_TRACE environment variable. Lines are
// tagged "trace" so Trace.tla can filter them. Mapping from per-key
// participation addresses to TLA+ server IDs ("n1", "n2", ...) is dynamic:
// the first address to appear receives "n1", and so on.
//
// Thread-safe: all writes go through a mutex-protected writer. Init/Close
// are idempotent. If SPECULA_TRACE is unset, emit calls are no-ops.

package agreement

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/algorand/go-algorand/data/basics"
)

var (
	specTraceMu      sync.Mutex
	specTraceFile    *os.File
	specTraceEnc     *json.Encoder
	specTraceServers = map[basics.Address]string{}
	specTraceNextID  = 1
)

// SpecTraceInit opens the trace file at the given path. Repeated calls are
// idempotent (subsequent paths are ignored). Returns true if a writer is
// active after the call.
func SpecTraceInit(path string) bool {
	specTraceMu.Lock()
	defer specTraceMu.Unlock()
	if specTraceFile != nil {
		return true
	}
	if path == "" {
		return false
	}
	f, err := os.Create(path)
	if err != nil {
		return false
	}
	specTraceFile = f
	specTraceEnc = json.NewEncoder(f)
	specTraceServers = map[basics.Address]string{}
	specTraceNextID = 1
	return true
}

// SpecTraceClose flushes and closes the trace writer.
func SpecTraceClose() {
	specTraceMu.Lock()
	defer specTraceMu.Unlock()
	if specTraceFile != nil {
		specTraceFile.Sync()
		specTraceFile.Close()
		specTraceFile = nil
		specTraceEnc = nil
	}
}

// SpecTraceActive returns true if a trace writer is open. Used to short-circuit
// instrumented code paths when tracing is disabled.
func SpecTraceActive() bool {
	specTraceMu.Lock()
	defer specTraceMu.Unlock()
	return specTraceFile != nil
}

// SpecTraceRegisterServer pre-registers an address with a chosen ID. When the
// address later appears in a trace event the same ID is used. Safe to call
// before init.
func SpecTraceRegisterServer(addr basics.Address, id string) {
	specTraceMu.Lock()
	defer specTraceMu.Unlock()
	specTraceServers[addr] = id
}

// specTraceNidLocked returns the TLA+ server ID for addr, allocating one on
// first sight. Caller must hold specTraceMu.
func specTraceNidLocked(addr basics.Address) string {
	if id, ok := specTraceServers[addr]; ok {
		return id
	}
	id := fmt.Sprintf("n%d", specTraceNextID)
	specTraceNextID++
	specTraceServers[addr] = id
	return id
}

// specTraceNid is the locked-helper wrapper.
func specTraceNid(addr basics.Address) string {
	specTraceMu.Lock()
	defer specTraceMu.Unlock()
	return specTraceNidLocked(addr)
}

// SpecTraceLocalNid returns a stable ID for the "local" pseudonode (used when
// an event represents a player-level decision rather than a per-key vote).
// We pick "local" so it is distinct from per-key IDs and stays the same
// across the run. For tests with a single pseudonode this collapses
// player-level events onto one synthetic server.
const specLocalNid = "local"

// specPlayerState is the snapshot captured at every event.
type specPlayerState struct {
	Round           uint64 `json:"round"`
	Period          uint64 `json:"period"`
	Step            uint64 `json:"step"`
	LastConcluding  uint64 `json:"lastConcluding"`
	PersistedRound  uint64 `json:"persistedRound"`
	PersistedPeriod uint64 `json:"persistedPeriod"`
	PersistedStep   uint64 `json:"persistedStep"`
	FastRecovery    uint64 `json:"fastRecovery"`
	Partitioned     bool   `json:"partitioned"`
	Decision        string `json:"decision,omitempty"`

	// Threshold fields (only set on threshold-related events).
	ThresholdType   string `json:"thresholdType,omitempty"`
	ThresholdPeriod uint64 `json:"thresholdPeriod,omitempty"`
	ThresholdValue  string `json:"thresholdValue,omitempty"`

	// CatchupInstall.
	InstalledValue string `json:"installedValue,omitempty"`
}

// specVote captures a vote payload (used by Issue*Vote/BroadcastVote/ReceiveVote).
type specVote struct {
	Sender     string `json:"sender"`
	Round      uint64 `json:"round"`
	Period     uint64 `json:"period"`
	Step       uint64 `json:"step"`
	Value      string `json:"value"`
	OrigPeriod uint64 `json:"origPeriod"`
}

// specMsg captures a message (used by Receive*).
type specMsg struct {
	Broadcaster string `json:"broadcaster,omitempty"`
	Round       uint64 `json:"round"`
	Period      uint64 `json:"period"`
	Value       string `json:"value,omitempty"`
}

// specEvent is the inner event payload.
type specEvent struct {
	Name  string          `json:"name"`
	Nid   string          `json:"nid"`
	State specPlayerState `json:"state"`
	Vote  *specVote       `json:"vote,omitempty"`
	Msg   *specMsg        `json:"msg,omitempty"`
}

// specEnvelope is the outer NDJSON record. tag MUST be "trace" so Trace.tla
// picks the line up.
type specEnvelope struct {
	Tag   string    `json:"tag"`
	Ts    int64     `json:"ts"`
	Event specEvent `json:"event"`
}

// shadow persisted state, kept in sync with the on-disk player snapshot.
// service.persistState updates these after enqueueing a write.
var (
	specPersistedMu sync.Mutex
	specPersisted   = struct {
		Round  uint64
		Period uint64
		Step   uint64
	}{}
)

// SpecTraceSetPersisted records the just-persisted player snapshot.
func SpecTraceSetPersisted(r round, p period, s step) {
	specPersistedMu.Lock()
	defer specPersistedMu.Unlock()
	specPersisted.Round = uint64(r)
	specPersisted.Period = uint64(p)
	specPersisted.Step = uint64(s)
}

// specPersistedGet returns the latest persisted snapshot.
func specPersistedGet() (uint64, uint64, uint64) {
	specPersistedMu.Lock()
	defer specPersistedMu.Unlock()
	return specPersisted.Round, specPersisted.Period, specPersisted.Step
}

// fastRecoveryCount tracks how many fast-vote fires have happened — the spec
// represents fastRecovery as a counter (0 before primer, 1 after, N+1 after Nth fast vote).
var (
	specFastMu    sync.Mutex
	specFastCount = uint64(0)
)

// SpecTraceFastRecoveryBumpPrimer is called when handleFastTimeout sets the
// initial deadline (first-fire branch).
func SpecTraceFastRecoveryBumpPrimer() {
	specFastMu.Lock()
	defer specFastMu.Unlock()
	if specFastCount == 0 {
		specFastCount = 1
	}
}

// SpecTraceFastRecoveryBumpVote is called when issueFastVote actually emits a
// vote.
func SpecTraceFastRecoveryBumpVote() {
	specFastMu.Lock()
	defer specFastMu.Unlock()
	specFastCount++
}

// SpecTraceFastRecoveryReset resets the counter (on enterPeriod / enterRound).
func SpecTraceFastRecoveryReset() {
	specFastMu.Lock()
	defer specFastMu.Unlock()
	specFastCount = 0
}

func specFastRecoveryGet() uint64 {
	specFastMu.Lock()
	defer specFastMu.Unlock()
	return specFastCount
}

// SpecTracePlayerSnapshot captures common player state. We expose this so
// callers can build a state record without each holding the lock manually.
func SpecTracePlayerSnapshot(p *player) specPlayerState {
	pr, pp, ps := specPersistedGet()
	return specPlayerState{
		Round:           uint64(p.Round),
		Period:          uint64(p.Period),
		Step:            uint64(p.Step),
		LastConcluding:  uint64(p.LastConcluding),
		PersistedRound:  pr,
		PersistedPeriod: pp,
		PersistedStep:   ps,
		FastRecovery:    specFastRecoveryGet(),
		Partitioned:     p.partitioned(),
	}
}

// specEmit writes a single NDJSON line. Returns silently if no writer.
func specEmit(ev specEvent) {
	specTraceMu.Lock()
	defer specTraceMu.Unlock()
	if specTraceEnc == nil {
		return
	}
	env := specEnvelope{
		Tag:   "trace",
		Ts:    time.Now().UnixNano(),
		Event: ev,
	}
	_ = specTraceEnc.Encode(env)
}

// digestString returns the trace-friendly form of a proposal value. Bottom is
// the literal string "Bottom".
func digestString(pv proposalValue) string {
	if pv == bottom {
		return "Bottom"
	}
	return pv.BlockDigest.String()
}

// ----------------------------------------------------------------------------
// Event emitters: one per spec action.
// ----------------------------------------------------------------------------

// SpecTraceIssueSoftVote emits an IssueSoftVote event. If pa is nil the call
// is an abstain (the function returned without appending an attest action);
// in that case vote is nil. Otherwise pa.Sender/Round/Period/Step are used.
func SpecTraceIssueSoftVote(p *player, pa *pseudonodeAction) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	ev := specEvent{Name: "IssueSoftVote", Nid: specLocalNid, State: st}
	if pa != nil {
		ev.Vote = &specVote{
			Sender:     specLocalNid,
			Round:      uint64(pa.Round),
			Period:     uint64(pa.Period),
			Step:       uint64(pa.Step),
			Value:      digestString(pa.Proposal),
			OrigPeriod: uint64(pa.Proposal.OriginalPeriod),
		}
	}
	specEmit(ev)
}

// SpecTraceIssueCertVote emits an IssueCertVote event.
func SpecTraceIssueCertVote(p *player, pa pseudonodeAction) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	ev := specEvent{
		Name:  "IssueCertVote",
		Nid:   specLocalNid,
		State: st,
		Vote: &specVote{
			Sender:     specLocalNid,
			Round:      uint64(pa.Round),
			Period:     uint64(pa.Period),
			Step:       uint64(pa.Step),
			Value:      digestString(pa.Proposal),
			OrigPeriod: uint64(pa.Proposal.OriginalPeriod),
		},
	}
	specEmit(ev)
}

// SpecTraceIssueNextVote emits an IssueNextVote event.
func SpecTraceIssueNextVote(p *player, pa pseudonodeAction) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	ev := specEvent{
		Name:  "IssueNextVote",
		Nid:   specLocalNid,
		State: st,
		Vote: &specVote{
			Sender:     specLocalNid,
			Round:      uint64(pa.Round),
			Period:     uint64(pa.Period),
			Step:       uint64(pa.Step),
			Value:      digestString(pa.Proposal),
			OrigPeriod: uint64(pa.Proposal.OriginalPeriod),
		},
	}
	specEmit(ev)
}

// SpecTraceIssueFastVote emits an IssueFastVote event.
func SpecTraceIssueFastVote(p *player, pa pseudonodeAction) {
	if !SpecTraceActive() {
		return
	}
	SpecTraceFastRecoveryBumpVote()
	st := SpecTracePlayerSnapshot(p)
	ev := specEvent{
		Name:  "IssueFastVote",
		Nid:   specLocalNid,
		State: st,
		Vote: &specVote{
			Sender:     specLocalNid,
			Round:      uint64(pa.Round),
			Period:     uint64(pa.Period),
			Step:       uint64(pa.Step),
			Value:      digestString(pa.Proposal),
			OrigPeriod: uint64(pa.Proposal.OriginalPeriod),
		},
	}
	specEmit(ev)
}

// SpecTraceHandleFastTimeoutPrimer fires when handleFastTimeout sets the
// initial deadline on first fire.
func SpecTraceHandleFastTimeoutPrimer(p *player) {
	if !SpecTraceActive() {
		return
	}
	SpecTraceFastRecoveryBumpPrimer()
	st := SpecTracePlayerSnapshot(p)
	specEmit(specEvent{Name: "HandleFastTimeoutPrimer", Nid: specLocalNid, State: st})
}

// SpecTracePersistState emits a PersistState event after the persist write completes.
func SpecTracePersistState(r round, pr period, st step) {
	if !SpecTraceActive() {
		return
	}
	SpecTraceSetPersisted(r, pr, st)
	state := specPlayerState{
		Round:           uint64(r),
		Period:          uint64(pr),
		Step:            uint64(st),
		PersistedRound:  uint64(r),
		PersistedPeriod: uint64(pr),
		PersistedStep:   uint64(st),
		FastRecovery:    specFastRecoveryGet(),
	}
	specEmit(specEvent{Name: "PersistState", Nid: specLocalNid, State: state})
}

// SpecTraceBroadcastVote emits a BroadcastVote event from pseudonode just
// before the vote is pushed onto t.out.
func SpecTraceBroadcastVote(v vote) {
	if !SpecTraceActive() {
		return
	}
	sender := specTraceNid(v.R.Sender)
	pr, pp, ps := specPersistedGet()
	state := specPlayerState{
		Round:           uint64(v.R.Round),
		Period:          uint64(v.R.Period),
		Step:            uint64(v.R.Step),
		PersistedRound:  pr,
		PersistedPeriod: pp,
		PersistedStep:   ps,
		FastRecovery:    specFastRecoveryGet(),
	}
	ev := specEvent{
		Name:  "BroadcastVote",
		Nid:   sender,
		State: state,
		Vote: &specVote{
			Sender:     sender,
			Round:      uint64(v.R.Round),
			Period:     uint64(v.R.Period),
			Step:       uint64(v.R.Step),
			Value:      digestString(v.R.Proposal),
			OrigPeriod: uint64(v.R.Proposal.OriginalPeriod),
		},
	}
	specEmit(ev)
}

// SpecTraceProposeBlock emits a ProposeBlock event when a proposal vote is sent.
func SpecTraceProposeBlock(v vote) {
	if !SpecTraceActive() {
		return
	}
	sender := specTraceNid(v.R.Sender)
	pr, pp, ps := specPersistedGet()
	state := specPlayerState{
		Round:           uint64(v.R.Round),
		Period:          uint64(v.R.Period),
		Step:            uint64(v.R.Step),
		PersistedRound:  pr,
		PersistedPeriod: pp,
		PersistedStep:   ps,
		FastRecovery:    specFastRecoveryGet(),
	}
	ev := specEvent{
		Name:  "ProposeBlock",
		Nid:   sender,
		State: state,
		Vote: &specVote{
			Sender:     sender,
			Round:      uint64(v.R.Round),
			Period:     uint64(v.R.Period),
			Step:       uint64(v.R.Step),
			Value:      digestString(v.R.Proposal),
			OrigPeriod: uint64(v.R.Proposal.OriginalPeriod),
		},
	}
	specEmit(ev)
}

// SpecTracePartitionPolicyRebroadcast emits a PartitionPolicyRebroadcast event
// after broadcastBundleAction was appended.
func SpecTracePartitionPolicyRebroadcast(p *player, b unauthenticatedBundle) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	st.ThresholdPeriod = uint64(b.Period)
	st.ThresholdValue = digestString(b.Proposal)
	st.ThresholdType = stepToThresholdType(b.Step)
	specEmit(specEvent{Name: "PartitionPolicyRebroadcast", Nid: specLocalNid, State: st})
}

// stepToThresholdType maps a bundle step to its threshold-event string.
func stepToThresholdType(s step) string {
	switch s {
	case soft:
		return "softThreshold"
	case cert:
		return "certThreshold"
	default:
		return "nextThreshold"
	}
}

// SpecTraceEnterPeriod emits the EnterPeriodViaSoftThreshold or
// EnterPeriodViaNextThreshold event based on the source threshold type.
func SpecTraceEnterPeriod(p *player, source thresholdEvent) {
	if !SpecTraceActive() {
		return
	}
	SpecTraceFastRecoveryReset()
	name := "EnterPeriodViaNextThreshold"
	tt := "nextThreshold"
	switch source.t() {
	case softThreshold:
		name = "EnterPeriodViaSoftThreshold"
		tt = "softThreshold"
	case certThreshold:
		name = "EnterPeriodViaSoftThreshold"
		tt = "certThreshold"
	}
	st := SpecTracePlayerSnapshot(p)
	st.ThresholdType = tt
	st.ThresholdPeriod = uint64(source.Period)
	st.ThresholdValue = digestString(source.Proposal)
	specEmit(specEvent{Name: name, Nid: specLocalNid, State: st})
}

// SpecTraceEnterRound emits the EnterRound event.
func SpecTraceEnterRound(p *player) {
	if !SpecTraceActive() {
		return
	}
	SpecTraceFastRecoveryReset()
	st := SpecTracePlayerSnapshot(p)
	specEmit(specEvent{Name: "EnterRound", Nid: specLocalNid, State: st})
}

// SpecTraceHandleSoftThresholdSamePeriod fires when the softThreshold handler
// issues a cert vote in the same period.
func SpecTraceHandleSoftThresholdSamePeriod(p *player, e thresholdEvent) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	st.ThresholdType = "softThreshold"
	st.ThresholdPeriod = uint64(e.Period)
	st.ThresholdValue = digestString(e.Proposal)
	specEmit(specEvent{Name: "HandleSoftThresholdSamePeriod", Nid: specLocalNid, State: st})
}

// SpecTraceHandleCertThresholdLocal fires when the certThreshold handler
// installs the cert locally + advances the round.
func SpecTraceHandleCertThresholdLocal(p *player, e thresholdEvent) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	st.ThresholdType = "certThreshold"
	st.ThresholdPeriod = uint64(e.Period)
	st.ThresholdValue = digestString(e.Proposal)
	st.Decision = digestString(e.Proposal)
	specEmit(specEvent{Name: "HandleCertThresholdLocal", Nid: specLocalNid, State: st})
}

// SpecTraceUpdateNextThresholdCache fires on each cache mutation in
// voteTrackerPeriod.handle for nextThreshold.
func SpecTraceUpdateNextThresholdCache(p *player, e thresholdEvent) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	st.ThresholdType = "nextThreshold"
	st.ThresholdPeriod = uint64(e.Period)
	st.ThresholdValue = digestString(e.Proposal)
	specEmit(specEvent{Name: "UpdateNextThresholdCache", Nid: specLocalNid, State: st})
}

// SpecTraceUpdateFreshest fires after voteTrackerRound replaces its freshest.
func SpecTraceUpdateFreshest(p *player, e thresholdEvent) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	st.ThresholdType = stepToThresholdType(e.Step)
	switch e.t() {
	case softThreshold:
		st.ThresholdType = "softThreshold"
	case certThreshold:
		st.ThresholdType = "certThreshold"
	case nextThreshold:
		st.ThresholdType = "nextThreshold"
	}
	st.ThresholdPeriod = uint64(e.Period)
	st.ThresholdValue = digestString(e.Proposal)
	specEmit(specEvent{Name: "UpdateFreshest", Nid: specLocalNid, State: st})
}

// SpecTraceUpdateStaging fires after proposalTracker.Staging is set.
func SpecTraceUpdateStaging(p *player, e thresholdEvent) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	switch e.t() {
	case softThreshold:
		st.ThresholdType = "softThreshold"
	case certThreshold:
		st.ThresholdType = "certThreshold"
	default:
		st.ThresholdType = "nextThreshold"
	}
	st.ThresholdPeriod = uint64(e.Period)
	st.ThresholdValue = digestString(e.Proposal)
	specEmit(specEvent{Name: "UpdateStaging", Nid: specLocalNid, State: st})
}

// SpecTraceReceiveVote fires after a vote is accepted into the tracker.
func SpecTraceReceiveVote(p *player, v vote) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	ev := specEvent{
		Name:  "ReceiveVote",
		Nid:   specLocalNid,
		State: st,
		Vote: &specVote{
			Sender:     specTraceNid(v.R.Sender),
			Round:      uint64(v.R.Round),
			Period:     uint64(v.R.Period),
			Step:       uint64(v.R.Step),
			Value:      digestString(v.R.Proposal),
			OrigPeriod: uint64(v.R.Proposal.OriginalPeriod),
		},
	}
	specEmit(ev)
}

// SpecTraceReceiveProposal fires after a proposal-vote is accepted.
func SpecTraceReceiveProposal(p *player, v vote) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	ev := specEvent{
		Name:  "ReceiveProposal",
		Nid:   specLocalNid,
		State: st,
		Msg: &specMsg{
			Round:  uint64(v.R.Round),
			Period: uint64(v.R.Period),
			Value:  digestString(v.R.Proposal),
		},
	}
	specEmit(ev)
}

// SpecTraceCalculateFilterTimeoutShort fires when the dynamic clamped
// branch was taken.
func SpecTraceCalculateFilterTimeoutShort(p *player) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	specEmit(specEvent{Name: "CalculateFilterTimeoutShort", Nid: specLocalNid, State: st})
}

// SpecTraceCalculateFilterTimeoutDefault fires when the static branch was taken.
func SpecTraceCalculateFilterTimeoutDefault(p *player) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	specEmit(specEvent{Name: "CalculateFilterTimeoutDefault", Nid: specLocalNid, State: st})
}

// SpecTraceRecordCredentialArrival fires after the lowestCredentialArrivals
// store completes.
func SpecTraceRecordCredentialArrival(p *player) {
	if !SpecTraceActive() {
		return
	}
	st := SpecTracePlayerSnapshot(p)
	specEmit(specEvent{Name: "RecordCredentialArrival", Nid: specLocalNid, State: st})
}

// SpecTraceCatchupInstall is invoked by catchup/service.go after EnsureBlock
// returns. We accept primitive types so this file does not need to import
// the agreement package's certificate type into the catchup package.
func SpecTraceCatchupInstall(round uint64, value string) {
	if !SpecTraceActive() {
		return
	}
	state := specPlayerState{
		Round:          round,
		InstalledValue: value,
	}
	specEmit(specEvent{Name: "CatchupInstall", Nid: specLocalNid, State: state})
}
