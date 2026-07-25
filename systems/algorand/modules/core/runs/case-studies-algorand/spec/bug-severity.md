# Severity Classification — algorand

## Summary

- Total bugs: 11
- Critical: 0
- High: 0
- Medium: 2
- Low: 8
- FALSE POSITIVE (no severity): 1

## Per-bug classification

| Bug | Title | Status | Severity | Reasoning |
|-----|-------|--------|----------|-----------|
| 1   | CR-1 — `fetchRound` fork detection is log-only | REPRODUCED | Medium | A code-promised "panic as loudly as possible" safeguard for fork detection only logs and silently retries against other peers, so a genuine fork condition is un-escalated and operators see only a routine ERROR log; reachable via any adversarial or fork-participating peer in `catchup/service.go:819-840`. Safety is not directly violated, but the operational invariant ("hard fail on fork") is broken with downstream risk. |
| 2   | CR-2 — `voteTracker` panics on Byzantine-majority equivocation (DoS surface) | REPRODUCED | Low | Trigger requires a Byzantine majority producing equivocating votes — a state under which the honest-node safety assumption is already violated — and the `Panicf` is the developer's deliberate fail-stop choice consistent with Algorand's safety-first stance, so the process-abort is defensible hardening rather than an exploitable defect. |
| 3   | CR-3 — `voteAggregator` "bad round" panic is unreachable through public message path | FALSE POSITIVE | — | `voteFresh` at `voteAggregator.go:198-263` filters every public-path vote to `PlayerRound..PlayerRound+1` before dispatch, making the panic structurally unreachable; the FP call is sound and the TODO is a debug-time-invariant cleanup. |
| 4   | CR-4 — "It should be impossible to hit this condition" dead branch | REPRODUCED | Low | The defensive remap-to-`NoLateCredentialTrackingImpact` branch in `proposalManager.go:184-188` is unreachable because upstream emitters only produce two whitelisted enum values; pure dead-code hygiene with no runtime effect. |
| 5   | CR-5 — `lowestCredentialArrivals` is reset on crash recovery | REPRODUCED | Low | After any algod restart, the 40-sample credential-arrival history is replaced with an empty buffer so `calculateFilterTimeout` reverts to the default ~2 s value for ~40 rounds — a self-recovering, bounded latency regression that matches the in-memory-only `msgp` design, with safety preserved and the impact only an undocumented post-restart timeout uptick. |
| 6   | CR-6 — `proposalTracker` silently overwrites `Staging` on threshold | REPRODUCED | Low | The unconditional `t.Staging = e.Proposal` assignment is reachable in isolation but caught by upstream guards (`voteTracker` single-threshold emission, `proposalTracker.Duplicate`), so it is a missing defense-in-depth check rather than a bug; no protocol-surface trigger exists. |
| 7   | CR-7 — `none.fresherThan(none) == true` is reflexive (and the cert-cert short-circuit) | REPRODUCED | Low | Both non-standard cases (reflexive `none` and cert-cert short-circuit) are intentional in `events.go:745-779`; the cert-cert case at worst causes an honest node to rebroadcast a stale-but-already-certified cert under a fork, which cannot violate safety. Documentation-vs-behavior mismatch only. |
| 8   | CR-8 — `BlockValidator.Validate` TODO ("second Round argument") | REPRODUCED | Low | The TODO is informational — the validator already extracts the round from the supplied block — so it is unactioned design commentary rather than a behavioral bug. Static-source finding only. |
| 9   | CR-9 — Redundant `Hash()` call in `verifyProposer` | REPRODUCED | Low | A duplicate Ed25519-VRF hash per proposal verification; pure micro-inefficiency in `proposal.go:245-247` with no correctness consequence and the developer's TODO already acknowledging the redundancy. |
| 10  | CR-10 — PR #5286 TODO file still present, not actioned | REPRODUCED | Low | A maintainer-authored `agreement/TODO` file flags two un-investigated next-vote-bundle concerns with no articulated trigger; without the author's original context the items are unbounded maintenance debt rather than a confirmed behavioral defect, so they classify as hygiene/follow-up rather than a runtime bug. |
| 11  | PR #5341 — `AsyncVoteVerifier.Quit` shutdown race | REPRODUCED | Medium | A TOCTOU between `verifyVote`'s `ctx.Done` check and `Quit`'s `wg.Wait` lets a late `wg.Add(1)`/`EnqueueBacklog` slip in, with downstream risk of "send on closed channel" panic during `algod` shutdown; the race is detected under `-race` and the panic is low-probability but reachable on any shutdown that coincides with in-flight vote verification. Blast radius is bounded to the shutdown window, hence Medium rather than High. |
