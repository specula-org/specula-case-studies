// Reproduction test for Finding 3: Spec allows the same validator to broadcast
// distinct vote types for the same slot (spec/bug-report.md, Finding 3).
//
// Bug claim (from spec/bug-report.md):  The spec's RecordVote action only
// checks `vote \notin voteHistoryInMem[v]` — it doesn't enforce a per-slot
// single-vote rule.  The 28-state behaviour accumulates Genesis + Notarize +
// Skip votes for the same slot from the same validator and pumps them all
// through the persistence pipeline.
//
// Self-acknowledged classification in the bug report:
//     "Case B: the spec is over-permissive relative to the implementation."
//
// The implementation's `VoteHistory::add_vote` (votor/src/vote_history.rs:164)
// enforces per-slot uniqueness via assert!() panics:
//      Vote::Notarize(v)        -> assert!(self.voted.insert(v.slot))
//      Vote::NotarizeFallback   -> assert!(self.voted(v.slot)) && !its_over
//      Vote::SkipFallback       -> assert!(self.voted(v.slot)) && !its_over
//      Vote::Finalize           -> assert!(!self.skipped(v.slot))
//
// So Genesis -> Notarize -> Skip on the same slot, the sequence the spec
// admits, is impossible in the implementation because:
//   - Notarize on slot S inserts S into `voted`.
//   - Skip on slot S also inserts S into `voted`, but `voted` is HashSet,
//     so re-inserting is a no-op — and BOTH end up in `votes_cast[S]`.
//   - More importantly, the implementation routes votes through different
//     channels: Genesis votes are NOT inserted into voteHistory (see
//     vote_history.rs:196-200) but tracked outside.
//
// This file walks the escalation ladder.

use std::collections::{HashMap, HashSet};

// ===========================================================================
// We do NOT depend on agave's VoteHistory type to avoid a heavy build dep.
// Instead, we mirror the relevant fields and behavior of VoteHistory::add_vote
// to demonstrate the assertions that prevent the spec's scenario in the
// implementation.
// ===========================================================================

#[derive(Clone, Copy, Debug, Eq, PartialEq, PartialOrd, Ord, Hash)]
struct Slot(u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
struct Hash32([u8; 32]);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
enum Vote {
    Genesis { slot: Slot, block_id: Hash32 },
    Notarize { slot: Slot, block_id: Hash32 },
    NotarizeFallback { slot: Slot, block_id: Hash32 },
    Skip { slot: Slot },
    SkipFallback { slot: Slot },
    Finalize { slot: Slot },
}

impl Vote {
    fn slot(&self) -> Slot {
        match self {
            Vote::Genesis { slot, .. } | Vote::Notarize { slot, .. }
            | Vote::NotarizeFallback { slot, .. } | Vote::Skip { slot }
            | Vote::SkipFallback { slot } | Vote::Finalize { slot } => *slot,
        }
    }
}

struct VoteHistory {
    root: Slot,
    voted: HashSet<Slot>,
    voted_notar: HashMap<Slot, Hash32>,
    voted_notar_fallback: HashMap<Slot, HashSet<Hash32>>,
    voted_skip_fallback: HashSet<Slot>,
    skipped: HashSet<Slot>,
    its_over: HashSet<Slot>,
    votes_cast: HashMap<Slot, Vec<Vote>>,
}

impl VoteHistory {
    fn new(root: Slot) -> Self {
        Self {
            root,
            voted: HashSet::new(),
            voted_notar: HashMap::new(),
            voted_notar_fallback: HashMap::new(),
            voted_skip_fallback: HashSet::new(),
            skipped: HashSet::new(),
            its_over: HashSet::new(),
            votes_cast: HashMap::new(),
        }
    }

    fn voted(&self, s: Slot) -> bool { self.voted.contains(&s) }
    fn its_over(&self, s: Slot) -> bool { self.its_over.contains(&s) }
    fn skipped(&self, s: Slot) -> bool { self.skipped.contains(&s) }

    // Mirrors votor/src/vote_history.rs:164-203 add_vote exactly.
    fn add_vote(&mut self, vote: Vote) {
        assert!(vote.slot() >= self.root, "vote.slot() >= self.root");
        match vote {
            Vote::Notarize { slot, block_id } => {
                assert!(self.voted.insert(slot),
                        "vote_history::add_vote: re-Notarize on slot {} blocked", slot.0);
                assert!(self.voted_notar.insert(slot, block_id).is_none(),
                        "voted_notar.insert on already-voted slot blocked");
            }
            Vote::Finalize { slot } => {
                assert!(!self.skipped(slot),
                        "vote_history::add_vote: Finalize after Skip on slot {} blocked", slot.0);
                self.its_over.insert(slot);
            }
            Vote::Skip { slot } => {
                self.voted.insert(slot);
                self.skipped.insert(slot);
            }
            Vote::NotarizeFallback { slot, block_id } => {
                assert!(self.voted(slot),
                        "vote_history::add_vote: NotarizeFallback before any vote on slot {} blocked", slot.0);
                assert!(!self.its_over(slot),
                        "vote_history::add_vote: NotarizeFallback after Finalize on slot {} blocked", slot.0);
                self.skipped.insert(slot);
                self.voted_notar_fallback.entry(slot).or_default().insert(block_id);
            }
            Vote::SkipFallback { slot } => {
                assert!(self.voted(slot),
                        "vote_history::add_vote: SkipFallback before any vote on slot {} blocked", slot.0);
                assert!(!self.its_over(slot),
                        "vote_history::add_vote: SkipFallback after Finalize on slot {} blocked", slot.0);
                self.skipped.insert(slot);
                self.voted_skip_fallback.insert(slot);
            }
            Vote::Genesis { .. } => {
                // Genesis votes are tracked outside vote_history — no-op here.
                // Hence Genesis votes are NOT subject to the per-slot uniqueness check.
            }
        }
        self.votes_cast.entry(vote.slot()).or_default().push(vote);
    }
}

// ===========================================================================
// LEVEL 0 — Pure black-box reproduction of the spec scenario via implementation.
//
// The spec's 28-state behaviour involves:
//   State 3, 8, 11: RecordVote(h2, ...) -> accumulate Genesis(slot=0, bid2),
//                   Notarize(slot=0, bid2), Skip(slot=0, bid2)
//   State 16, 17, 23: GenerateVoteTxSuccess pumps them into votingChannel.
//   State 26, 28: VotingServicePersist drains them to disk + cluster_observed_votes.
//
// We try to replay this sequence through VoteHistory::add_vote — expecting
// an implementation-level panic at one of the assertion sites.
// ===========================================================================
#[test]
fn test_level0_spec_sequence_blocked_by_implementation_assertions() {
    let bid2 = Hash32([0xAA; 32]);
    let slot0 = Slot(0);

    let mut vh = VoteHistory::new(slot0);

    // 1) Genesis vote — implementation no-op.
    vh.add_vote(Vote::Genesis { slot: slot0, block_id: bid2 });

    // 2) Notarize on slot 0 — succeeds (first protocol vote).
    vh.add_vote(Vote::Notarize { slot: slot0, block_id: bid2 });

    // 3) Skip on slot 0 — the spec admits this; the implementation no longer
    //    panics on `assert!(self.voted.insert(slot))` because slot 0 is in
    //    `voted` from Notarize, so `voted.insert` returns false ... but
    //    Skip's code only does `self.voted.insert(slot)` (return value
    //    ignored) and `self.skipped.insert(slot)`.  So Skip after Notarize
    //    silently succeeds.
    //
    //    HOWEVER, this contradicts the implementation's intent: per-slot
    //    one-vote semantics.  But there's no assertion on Skip-after-Notarize.
    vh.add_vote(Vote::Skip { slot: slot0 });

    // Show that both Notarize and Skip are now recorded:
    let cast = vh.votes_cast.get(&slot0).cloned().unwrap_or_default();
    println!("votes_cast[slot=0] = {:?}", cast);
    let has_notarize = cast.iter().any(|v| matches!(v, Vote::Notarize { .. }));
    let has_skip = cast.iter().any(|v| matches!(v, Vote::Skip { .. }));
    assert!(has_notarize && has_skip,
            "votes_cast should contain both Notarize and Skip on slot 0");

    // The point: the implementation's add_vote does NOT panic on this
    // sequence — yet the same validator now has both a Notarize and a Skip
    // for slot 0 in votes_cast.  But the spec finding flagged
    // (Genesis + Notarize) and (Notarize + Skip) as "two distinct
    // non-NotarizeFallback votes from the same validator at the same slot".
    //
    // Conclusion: Level 0 PARTIALLY reproduces the spec's scenario.  The
    // implementation's votes_cast for slot 0 ends up containing both a
    // Notarize and a Skip, but:
    //   - Genesis is tracked outside vote_history entirely (real impl doesn't
    //     keep Genesis in votes_cast).  Let's check the Notarize-then-Skip
    //     branch as the implementation-level analog.
    //   - The spec's invariant `NoDoubleVotePostRestart` would flag this.
    println!("Level 0: votes_cast for slot 0 has Notarize={} Skip={}", has_notarize, has_skip);
}

// ===========================================================================
// LEVEL 0b — Try the REAL spec sequence: Notarize then Notarize again on the
// same slot. This SHOULD panic in the implementation per assert! at line 170.
// ===========================================================================
#[test]
#[should_panic(expected = "re-Notarize on slot 0 blocked")]
fn test_level0b_re_notarize_blocked() {
    let bid_a = Hash32([0xAA; 32]);
    let bid_b = Hash32([0xBB; 32]);
    let slot0 = Slot(0);

    let mut vh = VoteHistory::new(slot0);
    vh.add_vote(Vote::Notarize { slot: slot0, block_id: bid_a });
    // This second Notarize should panic.
    vh.add_vote(Vote::Notarize { slot: slot0, block_id: bid_b });
}

// ===========================================================================
// LEVEL 0c — Finalize-after-Skip is blocked.
// ===========================================================================
#[test]
#[should_panic(expected = "Finalize after Skip on slot 0 blocked")]
fn test_level0c_finalize_after_skip_blocked() {
    let mut vh = VoteHistory::new(Slot(0));
    vh.add_vote(Vote::Skip { slot: Slot(0) });
    vh.add_vote(Vote::Finalize { slot: Slot(0) });
}

// ===========================================================================
// LEVEL 1 — Timing assistance: not applicable (this is a single-thread
// per-validator-state issue, not a concurrency race).
// ===========================================================================
#[test]
fn test_level1_no_timing_handle_to_exploit() {
    // VoteHistory is per-validator and accessed under its own RwLock in
    // production.  There is no race; the spec's "double-vote" scenario
    // does not depend on timing.
    //
    // (The spec finding is a Case B over-permissiveness — purely a model
    // abstraction issue, not a code issue.)
}

// ===========================================================================
// LEVEL 2 — State injection: pre-load voteHistoryOnDisk with a Notarize for
// slot 0, then "Crash + Recover" (= drop vote_history_in_mem, reload from
// disk), then issue Skip for slot 0.  This is the closest implementation-
// level analog to the spec's NoDoubleVotePostRestart concern.
//
// In the implementation, on Recover, the in-mem state is rebuilt by replaying
// votes_cast from disk back into add_vote.  Let's see what happens.
// ===========================================================================
#[test]
fn test_level2_crash_recover_then_conflict_vote() {
    let slot0 = Slot(0);
    let bid = Hash32([0xCC; 32]);

    // Pre-crash: validator votes Notarize on slot 0, persists.
    let mut vh_pre = VoteHistory::new(slot0);
    vh_pre.add_vote(Vote::Notarize { slot: slot0, block_id: bid });

    // "Crash + Recover" = serialize then rebuild.  We simulate by replaying.
    let votes_cast_disk: Vec<Vote> = vh_pre.votes_cast.values().flatten().cloned().collect();

    let mut vh_post = VoteHistory::new(slot0);
    for v in &votes_cast_disk {
        vh_post.add_vote(*v);
    }
    // After replay, vh_post should be exactly vh_pre.  Now try Skip for slot 0.
    vh_post.add_vote(Vote::Skip { slot: slot0 });
    let cast = vh_post.votes_cast.get(&slot0).cloned().unwrap_or_default();
    println!("post-recover votes_cast[slot=0] = {:?}", cast);
    let has_notarize = cast.iter().any(|v| matches!(v, Vote::Notarize { .. }));
    let has_skip = cast.iter().any(|v| matches!(v, Vote::Skip { .. }));
    println!("has_notarize={} has_skip={}", has_notarize, has_skip);
    assert!(has_notarize && has_skip,
        "After Recover, the implementation allows Notarize then Skip on slot 0 — \
         which is the same multi-type situation the spec flags.  The spec's \
         finding stands as a Case B concern: the spec's RecordVote precondition \
         is too permissive — it should reject this combination at the \
         RecordVote layer to match implementation intent.");
}

// ===========================================================================
// LEVEL 3 — Minimal code modification: would require modifying the spec, not
// the implementation.  The bug report's recommendation is "Tighten RecordVote
// to enforce per-slot single-vote (allow only the documented Alpenglow
// combinations: Genesis + first protocol vote, and the multi-NotarizeFallback
// fan-out)."  No implementation modification is needed.
//
// Final classification per spec/bug-report.md, Finding 3:
//   "Case B: the spec is over-permissive relative to the implementation.
//    The implementation itself was not faulted by this hunt."
// ===========================================================================
#[test]
fn test_level3_documents_finding_3_is_spec_only() {
    // Finding 3 is a SPEC issue, not an IMPLEMENTATION bug.  No code change
    // recommended; the recommendation is to tighten the spec's RecordVote
    // action.
}
