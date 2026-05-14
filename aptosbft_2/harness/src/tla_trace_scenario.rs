//! TLA+ trace scenarios for Aptos BFT (round 2).
//!
//! This file is copied into
//! `consensus/safety-rules/src/tests/tla_trace_scenario.rs` by
//! `apply.sh`.  It builds N parallel SafetyRules instances (one per
//! validator s1..sN), drives them through realistic 2-chain HotStuff /
//! Jolteon flows, and emits a trace that exercises each spec action
//! the Trace.tla validator recognises.
//!
//! Why this design:
//!   * The bug families in the modeling brief live inside
//!     `safety_rules.rs` / `safety_rules_2chain.rs` — exactly what the
//!     prior round could not split-instrument.  Driving SafetyRules
//!     directly lets the harness observe the sign-vs-persist window in
//!     Family 1, the missing last_voted_round interlock in Family 2,
//!     the missing epoch / extension check in Family 3, etc.
//!   * Each "validator" is a real `SafetyRules` instance with its own
//!     PersistentSafetyStorage and its own SafetyData.  All four share
//!     signer_0's identity (skip_sig_verify is on in LocalClient mode,
//!     so the four can vote on each other's proposals).  The spec only
//!     reasons over per-nid state transitions, so the test driver tags
//!     each instance with a distinct nid (s1..s4).
//!   * Round-manager-level events (Propose, ReceiveProposal,
//!     ReceiveVote, FormQC, ReceiveOrderVote, FormOrderingCert, etc.)
//!     are emitted directly from the test driver at the protocol
//!     boundaries that round_manager.rs would normally hit.

use crate::{
    test_utils::{
        self, make_genesis, make_proposal_with_parent, make_proposal_with_qc, make_timeout_cert,
        test_storage,
    },
    tla_trace, SafetyRules, TSafetyRules,
};
use aptos_consensus_types::{
    order_vote_proposal::OrderVoteProposal,
    timeout_2chain::TwoChainTimeout,
    vote_proposal::VoteProposal,
};
use aptos_crypto::hash::{HashValue, ACCUMULATOR_PLACEHOLDER_HASH};
use aptos_types::validator_signer::ValidatorSigner;
use serde_json::json;
use std::collections::HashMap;
use std::env;
use std::sync::Arc;

const N_VALIDATORS: usize = 4;

/// Map a block round to the spec's abstract value name.
/// Cycles through v1, v2, v3 — matching Trace.cfg's `Values`.
fn value_for_round(round: u64) -> String {
    let names = ["v1", "v2", "v3"];
    names[(round.saturating_sub(1) as usize) % names.len()].to_string()
}

/// Per-validator harness: an instrumented `SafetyRules` plus its
/// stable sid ("s1"/"s2"/...).
struct Validator {
    sid: String,
    rules: SafetyRules,
    /// Most recently observed round_manager-level fields kept by the
    /// test driver (so the round-manager-level emits carry the right
    /// `currentRound`, `highestQCRound`, etc.).
    current_round: u64,
    highest_qc_round: u64,
    highest_ordered_round: u64,
    committed_round: u64,
}

impl Validator {
    fn safety_state(&mut self) -> serde_json::Value {
        let sd = self
            .rules
            .persistent_storage
            .safety_data()
            .expect("safety_data should be readable");
        tla_trace::safety_state(&sd)
    }
}

fn build_validators(signer: &ValidatorSigner) -> Vec<Validator> {
    let mut out = Vec::with_capacity(N_VALIDATORS);
    for i in 0..N_VALIDATORS {
        let storage = test_storage(signer);
        // skip_sig_verify = true so we can drive any validator with
        // proposals signed by `signer` regardless of which sid they
        // play in the trace.
        let rules = SafetyRules::new(storage, true);
        out.push(Validator {
            sid: format!("s{}", i + 1),
            rules,
            current_round: 0,
            highest_qc_round: 0,
            highest_ordered_round: 0,
            committed_round: 0,
        });
    }
    out
}

/// Initialize the trace file path + sid mapping.  Called at the start
/// of every test scenario so each scenario can write its own file.
fn init_tracing(trace_path: &str) {
    if tla_trace::is_active() {
        return;
    }
    let mut map = HashMap::new();
    for i in 0..N_VALIDATORS {
        map.insert(format!("validator{}", i), format!("s{}", i + 1));
    }
    tla_trace::init(trace_path, map);
    let sids: Vec<String> = (1..=N_VALIDATORS).map(|i| format!("s{}", i)).collect();
    tla_trace::emit_config(&sids);
}

fn scenario_path(name: &str) -> String {
    env::var("TLA_TRACE_FILE").unwrap_or_else(|_| {
        format!(
            "{}/../../../../.specula-output/traces/{}.ndjson",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    })
}

/// Emit the round-manager-level events that surround a `SignVote` /
/// `CompletePersistVote` at every validator that votes on the given
/// proposal.
///
/// The pattern:
///   1. proposer emits Propose with the proposal's round/value.
///   2. every validator emits ReceiveProposal.
///   3. every validator calls SafetyRules — this triggers the
///      instrumented SignVote and CompletePersistVote inside the impl.
///   4. every OTHER validator emits ReceiveVote for each per-sender
///      pair.
///   5. once 2f+1 distinct senders are recorded, the receiver emits
///      FormQC.
fn drive_propose_and_vote(
    validators: &mut Vec<Validator>,
    proposer_idx: usize,
    proposal: &VoteProposal,
    tc: Option<&aptos_consensus_types::timeout_2chain::TwoChainTimeoutCertificate>,
) -> Vec<String> {
    let round = proposal.block().round();
    let epoch = proposal.block().epoch();
    let value = value_for_round(round);
    let proposer_sid = validators[proposer_idx].sid.clone();

    // 1. Propose
    {
        let v = &mut validators[proposer_idx];
        v.current_round = round;
        tla_trace::emit_event(
            "Propose",
            &v.sid,
            round,
            epoch,
            json!({
                "currentRound": round,
                "proposalValue": value,
            }),
            None,
        );
    }

    // 2. ReceiveProposal at every validator (including the proposer's
    //    local-self).
    for v in validators.iter_mut() {
        v.current_round = round;
        tla_trace::emit_event(
            "ReceiveProposal",
            &v.sid,
            round,
            epoch,
            json!({
                "currentRound": round,
            }),
            Some(json!({
                "source": proposer_sid,
                "round":  round,
                "epoch":  epoch,
                "value":  value,
            })),
        );
    }

    // 3. SafetyRules sign vote.  Instrumentation inside
    //    guarded_construct_and_sign_vote_two_chain emits SignVote then
    //    CompletePersistVote.
    let mut signers = Vec::with_capacity(validators.len());
    for v in validators.iter_mut() {
        tla_trace::set_active_nid(&v.sid);
        match v.rules.construct_and_sign_vote_two_chain(proposal, tc) {
            Ok(_vote) => signers.push(v.sid.clone()),
            Err(e) => eprintln!(
                "scenario: validator {} could not vote on round {}: {:?}",
                v.sid, round, e
            ),
        }
        tla_trace::clear_active_nid();
    }

    // 4. ReceiveVote: every receiver hears every signer (modulo self).
    let receivers_view: Vec<String> =
        validators.iter().map(|v| v.sid.clone()).collect();
    for v in validators.iter_mut() {
        for src in signers.iter() {
            tla_trace::emit_event(
                "ReceiveVote",
                &v.sid,
                round,
                epoch,
                json!({}),
                Some(json!({
                    "source": src,
                    "round":  round,
                    "epoch":  epoch,
                    "value":  value,
                })),
            );
        }
        // 5. Once 2f+1 distinct authors have voted, the receiver forms
        //    a QC.  We model 2f+1 = 3 of 4 (Quorum=3 in Trace.cfg).
        if signers.len() >= 3 {
            v.highest_qc_round = round.max(v.highest_qc_round);
            // Two-chain commit rule: if round(B0) + 1 = round(B1),
            // commit B0.  We track the previous round's qc presence
            // implicitly via highest_qc_round monotonicity.
            if round > 1 && v.committed_round + 1 < round {
                v.committed_round = round - 1;
            }
            let _ = receivers_view; // keep linker happy
            tla_trace::emit_event(
                "FormQC",
                &v.sid,
                round,
                epoch,
                json!({
                    "highestQCRound":      v.highest_qc_round,
                    "highestOrderedRound": v.highest_ordered_round,
                    "committedRound":      v.committed_round,
                    "currentRound":        round + 1,
                }),
                None,
            );
            v.current_round = round + 1;
        }
    }

    signers
}

/// Drive `construct_and_sign_order_vote` across all validators for a
/// given OrderVoteProposal and emit the surrounding ReceiveOrderVote /
/// FormOrderingCert / ExecuteBlock / SignCommitVote /
/// ReceiveCommitVote / AggregateCommitVotes / PersistBlock events.
fn drive_order_vote(
    validators: &mut Vec<Validator>,
    proposer_idx: usize,
    proposal: &OrderVoteProposal,
) {
    let round = proposal.block().round();
    let epoch = proposal.block().epoch();
    let value = value_for_round(round);
    let _ = proposer_idx;

    // SignOrderVote (instrumented inside the impl).
    let mut signers = Vec::new();
    for v in validators.iter_mut() {
        tla_trace::set_active_nid(&v.sid);
        match v.rules.construct_and_sign_order_vote(proposal) {
            Ok(_vote) => signers.push(v.sid.clone()),
            Err(e) => eprintln!(
                "scenario: validator {} could not order-vote on round {}: {:?}",
                v.sid, round, e
            ),
        }
        tla_trace::clear_active_nid();
    }

    // ReceiveOrderVote at every receiver from every signer.
    for v in validators.iter_mut() {
        for src in signers.iter() {
            tla_trace::emit_event(
                "ReceiveOrderVote",
                &v.sid,
                round,
                epoch,
                json!({}),
                Some(json!({
                    "source": src,
                    "round":  round,
                    "epoch":  epoch,
                    "value":  value,
                })),
            );
        }
        // FormOrderingCert once 2f+1 signers were collected.
        if signers.len() >= 3 {
            v.highest_ordered_round = round.max(v.highest_ordered_round);
            tla_trace::emit_event(
                "FormOrderingCert",
                &v.sid,
                round,
                epoch,
                json!({
                    "highestQCRound":      v.highest_qc_round,
                    "highestOrderedRound": v.highest_ordered_round,
                    "proposalValue":       value,
                }),
                None,
            );
            // Pipeline: ExecuteBlock → SignCommitVote → ReceiveCommitVote →
            // AggregateCommitVotes → PersistBlock.
            tla_trace::emit_event(
                "ExecuteBlock",
                &v.sid,
                round,
                epoch,
                json!({}),
                None,
            );
        }
    }

    // SignCommitVote at every validator that ordered the block.
    // We synthesize the event at the driver level rather than calling
    // the real `sign_commit_vote`, because the latter requires us to
    // hand-build a LedgerInfoWithSignatures whose `commit_info()`
    // matches the round we want — non-trivial without a proper
    // pipeline driver.  The source-level instrumentation in
    // safety_rules.rs is still in place for production observation.
    if signers.len() >= 3 {
        for v in validators.iter_mut() {
            let state = v.safety_state();
            tla_trace::emit_event(
                "SignCommitVote",
                &v.sid,
                round,
                epoch,
                tla_trace::merge_state(state, json!({"epoch": epoch})),
                None,
            );
        }

        // ReceiveCommitVote at every receiver from every signer.
        for v in validators.iter_mut() {
            for src in signers.iter() {
                tla_trace::emit_event(
                    "ReceiveCommitVote",
                    &v.sid,
                    round,
                    epoch,
                    json!({}),
                    Some(json!({
                        "source": src,
                        "round":  round,
                        "epoch":  epoch,
                        "value":  value,
                    })),
                );
            }
            tla_trace::emit_event(
                "AggregateCommitVotes",
                &v.sid,
                round,
                epoch,
                json!({}),
                None,
            );
            v.committed_round = round.max(v.committed_round);
            tla_trace::emit_event(
                "PersistBlock",
                &v.sid,
                round,
                epoch,
                json!({
                    "committedRound": v.committed_round,
                }),
                None,
            );
        }
    }
}

/// Drive `sign_timeout_with_qc` across all validators.
fn drive_timeout(
    validators: &mut Vec<Validator>,
    timeout_round: u64,
    epoch: u64,
    qc: aptos_consensus_types::quorum_cert::QuorumCert,
    tc: Option<&aptos_consensus_types::timeout_2chain::TwoChainTimeoutCertificate>,
) {
    let to = TwoChainTimeout::new(epoch, timeout_round, qc);
    // SignTimeout (instrumented in the impl).
    let mut signers = Vec::new();
    for v in validators.iter_mut() {
        tla_trace::set_active_nid(&v.sid);
        match v.rules.sign_timeout_with_qc(&to, tc) {
            Ok(_sig) => signers.push(v.sid.clone()),
            Err(e) => eprintln!(
                "scenario: validator {} could not sign timeout on round {}: {:?}",
                v.sid, timeout_round, e
            ),
        }
        tla_trace::clear_active_nid();
    }

    // ReceiveTimeout at every receiver from every signer.
    for v in validators.iter_mut() {
        for src in signers.iter() {
            tla_trace::emit_event(
                "ReceiveTimeout",
                &v.sid,
                timeout_round,
                epoch,
                json!({}),
                Some(json!({
                    "source": src,
                    "round":  timeout_round,
                    "epoch":  epoch,
                    "value":  "",
                })),
            );
        }
        // FormTC once 2f+1 signers are recorded.
        if signers.len() >= 3 {
            v.current_round = (timeout_round + 1).max(v.current_round);
            tla_trace::emit_event(
                "FormTC",
                &v.sid,
                timeout_round,
                epoch,
                json!({
                    "currentRound": v.current_round,
                }),
                None,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

/// Normal happy-path: 4 rounds of regular vote → QC → order-vote →
/// ordering cert → commit at every validator.
#[test]
fn tla_trace_normal_flow() {
    let trace_path = scenario_path("normal");
    init_tracing(&trace_path);

    let signer = ValidatorSigner::from_int(0);
    let (proof, genesis_qc) = make_genesis(&signer);
    let mut validators = build_validators(&signer);

    // Initialize every SafetyRules instance.  We do NOT emit a
    // synthetic Recover event here: in the spec, Recover requires a
    // prior Crash, and SilentCrash in Trace.tla picks an arbitrary
    // alive validator — so a string of Recover-bootstraps confuses
    // TLC's search.  The spec's Init already matches the post-init
    // SafetyData layout, so we can move straight to round-level
    // events.
    for v in validators.iter_mut() {
        v.rules.initialize(&proof).expect("initialize");
    }

    // Build a four-round chain: genesis → a1 → a2 → a3 → a4
    let base_round = genesis_qc.certified_block().round();
    let a1 = make_proposal_with_qc(base_round + 1, genesis_qc.clone(), &signer);
    let a2 = make_proposal_with_parent(
        aptos_consensus_types::common::Payload::empty(false),
        base_round + 2,
        &a1,
        None,
        &signer,
    );
    let a3 = make_proposal_with_parent(
        aptos_consensus_types::common::Payload::empty(false),
        base_round + 3,
        &a2,
        Some(&a1),
        &signer,
    );
    let a4 = make_proposal_with_parent(
        aptos_consensus_types::common::Payload::empty(false),
        base_round + 4,
        &a3,
        Some(&a2),
        &signer,
    );

    // Round 1: validator 0 proposes a1, all vote.
    drive_propose_and_vote(&mut validators, 0, &a1, None);
    // Round 2: validator 1 proposes a2, all vote.
    drive_propose_and_vote(&mut validators, 1, &a2, None);
    // Round 3: validator 2 proposes a3, all vote.
    drive_propose_and_vote(&mut validators, 2, &a3, None);
    // Round 4: validator 3 proposes a4, all vote.
    drive_propose_and_vote(&mut validators, 3, &a4, None);

    // Order-vote on a1 (so the 2-chain ordering cert exists for round
    // base_round + 1).
    let ov1 = OrderVoteProposal::new(
        a1.block().clone(),
        a2.block().quorum_cert().certified_block().clone(),
        Arc::new(a2.block().quorum_cert().clone()),
    );
    drive_order_vote(&mut validators, 0, &ov1);

    let ov2 = OrderVoteProposal::new(
        a2.block().clone(),
        a3.block().quorum_cert().certified_block().clone(),
        Arc::new(a3.block().quorum_cert().clone()),
    );
    drive_order_vote(&mut validators, 1, &ov2);
}

/// Timeout flow: round 2 times out, every validator signs a 2-chain
/// timeout (which exercises the canonical persist-then-sign order at
/// safety_rules_2chain.rs:47-49).
#[test]
fn tla_trace_timeout_flow() {
    let trace_path = scenario_path("timeout");
    init_tracing(&trace_path);

    let signer = ValidatorSigner::from_int(0);
    let (proof, genesis_qc) = make_genesis(&signer);
    let mut validators = build_validators(&signer);

    for v in validators.iter_mut() {
        v.rules.initialize(&proof).expect("initialize");
    }

    let base_round = genesis_qc.certified_block().round();

    // Round 1 times out: every validator signs a TwoChainTimeout for
    // round 1 with the genesis QC (qc_round = 0, so safe_to_timeout's
    // `round == next_round(qc_round)` check passes).  This exercises
    // sign_timeout_with_qc → persist → sign → SignTimeout emit.
    drive_timeout(
        &mut validators,
        base_round + 1,
        1,
        genesis_qc.clone(),
        None,
    );

    // Round 2 times out using a TC for round 1.
    let tc1 = make_timeout_cert(base_round + 1, &genesis_qc, &signer);
    drive_timeout(
        &mut validators,
        base_round + 2,
        1,
        genesis_qc.clone(),
        Some(&tc1),
    );

    // After two consecutive timeouts the spec's SignVote precondition
    // (`r = NextRound(tcRound) /\ qcRound >= tcRound`) is unsatisfiable
    // without an interleaving QC, so we do NOT try to vote at round 3
    // — the impl's own `safe_to_vote` uses a different qc_round source
    // and would accept it, but the spec's model is the abstract
    // round-2-chain check.  Document the gap rather than fabricate
    // a vote that the spec cannot replay.

    // EchoTimeout: re-broadcast the current round's timeout without
    // changing persisted state.  The spec's EchoTimeout action uses
    // currentRound[s] as the round; after FormTC fired at round 2,
    // currentRound[s] = 3 (FormTC advances it).  EchoTimeout emits
    // a TimeoutMsg at round 3 in the spec — but no SignTimeout happens.
    for v in validators.iter_mut() {
        let state = v.safety_state();
        tla_trace::emit_event(
            "EchoTimeout",
            &v.sid,
            base_round + 3,
            1,
            tla_trace::merge_state(state, json!({"currentRound": base_round + 3})),
            None,
        );
    }
}

/// Optimistic-proposal flow (Family 7): exercises ProposeOpt.
#[test]
fn tla_trace_opt_flow() {
    let trace_path = scenario_path("opt");
    init_tracing(&trace_path);

    let signer = ValidatorSigner::from_int(0);
    let (proof, genesis_qc) = make_genesis(&signer);
    let mut validators = build_validators(&signer);

    for v in validators.iter_mut() {
        v.rules.initialize(&proof).expect("initialize");
    }

    let base_round = genesis_qc.certified_block().round();
    let a1 = make_proposal_with_qc(base_round + 1, genesis_qc.clone(), &signer);
    let a2 = make_proposal_with_parent(
        aptos_consensus_types::common::Payload::empty(false),
        base_round + 2,
        &a1,
        None,
        &signer,
    );

    // Round 1: optimistic propose by s1.  We emit ONLY ProposeOpt
    // (not Propose) for round 1 — the spec has a `roundProposer[r] =
    // Nil` precondition that would block both from firing.  We still
    // run drive_propose_and_vote-like flow manually to capture the
    // ReceiveProposal + SignVote + CompletePersistVote + ReceiveVote +
    // FormQC events on the optimistic block.
    let value = value_for_round(base_round + 1);
    let proposer_sid = validators[0].sid.clone();
    {
        let v = &mut validators[0];
        v.current_round = base_round + 1;
        tla_trace::emit_event(
            "ProposeOpt",
            &v.sid,
            base_round + 1,
            1,
            json!({
                "currentRound":  base_round + 1,
                "proposalValue": value.clone(),
            }),
            None,
        );
    }
    // ReceiveProposal for every validator.
    for v in validators.iter_mut() {
        v.current_round = base_round + 1;
        tla_trace::emit_event(
            "ReceiveProposal",
            &v.sid,
            base_round + 1,
            1,
            json!({"currentRound": base_round + 1}),
            Some(json!({
                "source": proposer_sid,
                "round":  base_round + 1,
                "epoch":  1,
                "value":  value,
            })),
        );
    }
    // Real SafetyRules signs the opt block — the path is identical to
    // a regular vote (the spec's ProposeOpt is followed by the same
    // SignVote/CompletePersistVote events).
    let mut signers = Vec::new();
    for v in validators.iter_mut() {
        tla_trace::set_active_nid(&v.sid);
        if v.rules
            .construct_and_sign_vote_two_chain(&a1, None)
            .is_ok()
        {
            signers.push(v.sid.clone());
        }
        tla_trace::clear_active_nid();
    }
    for v in validators.iter_mut() {
        for src in signers.iter() {
            tla_trace::emit_event(
                "ReceiveVote",
                &v.sid,
                base_round + 1,
                1,
                json!({}),
                Some(json!({
                    "source": src,
                    "round":  base_round + 1,
                    "epoch":  1,
                    "value":  value,
                })),
            );
        }
        if signers.len() >= 3 {
            v.highest_qc_round = (base_round + 1).max(v.highest_qc_round);
            tla_trace::emit_event(
                "FormQC",
                &v.sid,
                base_round + 1,
                1,
                json!({
                    "highestQCRound":      v.highest_qc_round,
                    "highestOrderedRound": v.highest_ordered_round,
                    "committedRound":      v.committed_round,
                    "currentRound":        base_round + 2,
                }),
                None,
            );
            v.current_round = base_round + 2;
        }
    }

    // Round 2: regular Propose to balance the trace.
    drive_propose_and_vote(&mut validators, 1, &a2, None);
}

/// Epoch-change flow (Family 4): every validator re-initializes after
/// a new epoch boundary, exercising the
/// `Ordering::Less` branch at safety_rules.rs:294-303.
#[test]
fn tla_trace_epoch_change_flow() {
    let trace_path = scenario_path("epoch_change");
    init_tracing(&trace_path);

    let signer = ValidatorSigner::from_int(0);
    let (proof, genesis_qc) = make_genesis(&signer);
    let mut validators = build_validators(&signer);

    for v in validators.iter_mut() {
        v.rules.initialize(&proof).expect("initialize");
    }

    let base_round = genesis_qc.certified_block().round();
    let a1 = make_proposal_with_qc(base_round + 1, genesis_qc.clone(), &signer);
    drive_propose_and_vote(&mut validators, 0, &a1, None);

    // Synthesize epoch change by emitting an EpochChange event for
    // each validator.  The impl's
    // guarded_initialize::Ordering::Less branch is what the spec
    // models; we can't drive that branch directly from a test (it
    // requires a higher-epoch ledger info), so we synthesize the event
    // post-hoc with the expected state.
    for v in validators.iter_mut() {
        let state = json!({
            "epoch":               2,
            "lastVotedRound":      0,
            "preferredRound":      0,
            "oneChainRound":       0,
            "highestTimeoutRound": 0,
            "lastVote":            "",
            "currentRound":        1,
        });
        tla_trace::emit_event("EpochChange", &v.sid, 0, 2, state, None);
        v.current_round = 1;
        v.highest_qc_round = 0;
        v.highest_ordered_round = 0;
        v.committed_round = 0;
    }
}

// Keep the build happy if some helper imports aren't used in all
// scenarios.
#[allow(dead_code)]
fn _unused(_: HashValue) {
    let _ = ACCUMULATOR_PLACEHOLDER_HASH;
    let _ = test_utils::empty_proof;
}
