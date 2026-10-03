# V00 Quality integration — 2026-09-13

The five Quality contracts now execute through the ordinary MC and full Trace paths. All five original real traces pass complete post-state matching with all 24 original and five added invariants. All six original invalid prefixes are rejected at their edited event. Production protocol and scenario code are unchanged.

This targeted round started at 12:08:30 UTC. It is a model-quality improvement, not initialization acceptance, a CI verdict, or a safety proof. Prior files and reports are retained in `output/quality-integration-20260913-1208/prior/`; earlier execution evidence retains its original input versions.

## Normal integration and source contracts

`base.tla` owns the five contracts and the last-action `quality` observation. Each of the 36 public reference actions calls its unchanged `Protocol...` relation and assigns the observer unconditionally. Init initializes it. Nonrelevant actions clear it. No protocol guard consults it. MC inherits these actions through its existing base instance; `vars`, `mcvars` and `traceVars` fingerprint the observer. Trace's six production/caller post-state components and `TraceMatched` are unchanged. Compatibility Quality/QualityTrace modules delegate to the same implementation.

All normal base/Trace/MC/smoke/hunt configurations retain their original text, bounds, actions and applicable properties, and additionally enable:

- VoteDecisionEligibility
- CampaignDecisionEligibility
- TransferDecisionEligibility
- RequestCorrelatedConfigurationEffects
- ProposalConfigurationDecisions

The preservation audit compares 199 original definitions, including protocol relations and original properties, modulo action names/whitespace. It also verifies the unchanged MC/Trace module bytes and supplied Go/harness-source hashes. This is a structural audit, not a refinement theorem.

`harness/verify.sh` still selects ordinary Trace. Its validation driver now uses the pinned registered task manager's start/wait functions and blocking waits instead of a private Java launcher and blanket concurrent-TLC refusal. The normal report checks the complete local import/config hash set, including OracleTrace. `run-checks.sh` performs normal syntax, MC/simulation and trace checks through the same manager; the legacy convergence launcher delegates to it. Both normal launch paths were executed successfully. A subsequent import of completed receipts into the normal harness report launched no duplicate jobs.

| Contract | V00 evidence and retained outcomes |
|---|---|
| Vote decision | raft.go:789–928, log.go:279: term/lease dispatch, log freshness, repeat votes, learner silence; removed nonlearners and candidates outside the receiver's voters are not forbidden by an invented membership check. |
| Campaign decision and outputs | raft.go:622–632,733–775,863–887: Hup eligibility and unapplied-configuration refusal, automatic election ticks, repeated PreCandidate PreVotes, singleton elections. |
| Transfer decision | raft.go:1038–1046,1163–1199: unknown/learner/same-target ignore, self cancellation of another transfer, lagging target admission, caught-up TimeoutNow. |
| Configuration effect | README.md:120, node.go:135–163, raft.go:1420–1514: committed request identity/target, promotion/removal, update and learner-demotion no-ops, deterministic zero-target callback cancellation. API-wait cancellation does not undo a handed-off log entry. |
| Proposal decision | raft.go:965–1002,1236–1250: admission and allowed rejection/forwarding in both directions, transfer/quota/role decisions and anonymous pending-change rewrite. |

Campaign expectations use captured decision inputs, not StepHup, Promotable or campaign decision helpers. The observer records outgoing vote-message bag increments: sender, recipient, kind, term, last index/term, forced-transfer bit and multiplicity. Thus unchanged role/term cannot hide an illicit output. Every Tick is observed before eligibility is tested, including nonvoters and attempts before timeout. Leader ticks may legitimately step down under CheckQuorum. Hup expects unforced elections; TimeoutNow's forced election and PreVote-response continuation remain distinct reference paths, with independent continuation contracts still deferred.

## Executed checks

Evidence root: `output/quality-integration-20260913-1208/`. Exact inputs, native task receipts, outcomes and counters are indexed by `quality-integration-results.json`.

| Check | Actual result |
|---|---|
| Normal syntax | Ten modules passed SANY; Python and shell entrypoints parsed. |
| Ordinary Trace | 5/5 accepted; 3,543 events; full state equality, original 24 + new 5 invariants, TraceMatched. |
| Original invalid traces | 6/6 correspondence failures at lines 14, 6, 240, 69, 136 and 1076. |
| Retained observation-only predicates | Five real traces accepted; five intended named failures; missing durable entry remains correspondence-only. |
| Decision-context consistency | Six completed sets: 3,456 vote, 48 campaign, 96 Tick, 66 transfer, 160 effect and 2,048 proposal observations. These are local contexts, not distributed reachability. |
| Decision sensitivity | All 11 retained and 7 added invalid observations rejected by the intended contract. |
| Outgoing-bag observer checks | Three valid observations accepted; six faulty before/after message-bag cases rejected, covering ineligible Hup/Tick, repeated PreVote missing/extra increments, wrong recipient and wrong log term. |
| Retained source-alignment fixtures | 81 states completed; unchanged snapshot/empty-refill precedence checks passed. |
| Ordinary MC.cfg BFS | Five-minute budget ended without reported violation; last sample depth 3, 3,052,515 distinct / 3,051,748 queued. Incomplete. |
| Ordinary election/transfer simulation | Five-minute budget ended without reported violation; last sample 1,301,784 checked states / 1,500 generated traces, configured depth cap 100. Sampled exploration. |
| Ordinary configuration/application simulation | Same limit; 1,281,016 checked states / 1,391 traces, depth cap 100. Sampled exploration. Raw trace-length mean/variance is not used because of the previously recorded runtime reporting limitation. |
| Normal MC smoke entrypoint | Completed: 1,605 distinct states, zero queued, all applicable original and five added properties. |

The summary tool cannot auto-detect the supplemental initial-state observer failures without JSON trace output; their literal invariant errors and printed observations are retained. This tooling limit is not reported as a missing or successful protocol execution.

## Connected progress before commitment

`ConfigurationProgress.tla` starts from operational states immediately after real Propose events at membership-snapshots lines **192, 1078, 1081 and 1284**. Full replay already established those prefixes. Each seed has a handed-off, core-accepted configuration request whose resulting entry is neither committed nor applied. They cover adding a learner, promotion, an anonymous pending-change no-op, and a canceled Remove callback. The seed manifest correlates request, exact resulting entry and source line; it does not invent request identity for the anonymous no-op. Prior accumulated ghosts reset at the window boundary; no claim about unchecked earlier history follows from that reset.

The driver uses the same Ready, persistence, Storage visibility, publication, replication Receive/rejection/retry, application and Advance actions. It begins before these produce commitment. A cyclic node/service scheduler is weakly fair as a whole; it invokes enabled service operations and skips idle slots. Fairness never assumes successful commitment, successful application or an enabled success transition. API cancellation remains optional. A separate scenario allows one ordinary leadership transfer at any service slot while the origin is leader.

The explicit environment is a continuing quiet service window: all seeded nodes live, their seeded voter quorums are usable, storage completes, communication services valid messages, no new crash, loss, duplication, proposal or autonomous timeout is introduced. The finite delivery-policy variants are labeled separately. These are sufficient scenario restrictions to investigate progress, not an assertion that arbitrary partitions or every accepted proposal must terminate.

The obligation is eventual application of the exact resulting log entry on the boot cluster. It permits logged no-op/canceled effects and does not equate API return with membership change. Configuration effects are checked independently by the normal contracts. Rejection before handoff, later request retries and overwritten/lost proposals are outside this obligation.

| Progress configuration | Actual result and meaning |
|---|---|
| Arbitrary valid per-node delivery, four seeds | Five-minute budget, incomplete temporal exploration; last sample 19,162 distinct, depth 183, 454 queued. |
| Same with optional transfer, one seed | Five-minute budget, incomplete; 25,611 distinct, depth 297, 240 queued. |
| Fixed delivery choice, arbitrary publication | Stable and optional-transfer checks also budget-limited; retained separately, not passes. |
| Fixed publication and delivery choices, four seeds | **Completed temporal check: 2,920 distinct states, four initial states, zero queued.** Optional API cancellation remains. This proves only this finite service-policy case. |
| Delivery-stalled controls | Expected temporal cycles under continuing caller service; reliable, fixed-delivery and fixed-publication variants all detected stalled progress. |
| Distributed commitment coverage | Negated coverage invariant failed after 99 states: actual replication/storage service reached a new commitment from the uncommitted seed. |
| Application during transfer coverage | Negated coverage invariant failed after 301 states: actual TransferLeader, vote/replication/service actions and request-correlated configuration callbacks reached application across the boot cluster after the origin lost leadership. The endpoint has origin 1 as Follower and target 2 still Candidate in term 3; it demonstrates a transfer/configuration interaction, not completed leader handoff or universal transfer progress. |

There is no replacement toy configuration protocol or replayed successful suffix. The fixed-choice case selects a valid message at each publication/delivery service point independently of its contents or eventual outcome; the more general cases and their incomplete results remain available. General message-instance fairness, further proposals/failures, recovery, transfer cancellation/timeouts and broader configurations remain open.

## Actual interaction coverage and limits

The five full replays contain 14 incoming vote decisions (two amid configuration disagreement), seven explicit Hups, all 21 Ticks (19 before timeout), three leader-local transfer decisions, six configuration proposals, one pending-change rewrite and 20 request-correlated callbacks. There are 25 callbacks amid configuration disagreement, five with inflight replication and three after restart. Four promotion effects, four canceled callbacks and four update no-ops are observed. Exact trace lines are in `output/quality-integration-20260913-1208/interaction-coverage.json`.

Those traces do not witness repeated PreCandidate Hup, automatic campaign output, ineligible Tick, callback overlap with an outstanding read/transfer, or callback after API-wait cancellation. The distributed progress witnesses add transfer/configuration and cancellation/commit paths. Three additional small no-client-workload queries used unchanged MC transitions and original fault bounds. An ineligible automatic Tick was reached in 18 states: joining node s4 had no voters, elapsed 4/timeout 5, emitted no votes, and retained its role/term. Repeated PreCandidate Hup and successful automatic-campaign queries did not produce witnesses before their three-minute budgets (last samples 3,050 and 3,054 simulation traces, configured depth cap 200); they remain unvisited distributed paths in this evidence set. Local fixtures alone are never counted as distributed executions.

Remaining work: generalize the checked progress policy without pruning legal communication orders; cover additional Ready/Advance and commit-only durability orders, Storage-call concurrency, full Node cancellation/stop and retry/result correlation; independently audit TimeoutNow/PreVote continuation and transfer dispatch across term/role changes. No large interface redesign was attempted. No production source, existing finding/confirmation verdict, CI pointer or published baseline was changed.

All 72 native tasks are terminal. Peak own reserved TLC allocation reconstructed from their receipts was 101 GiB / 27 workers; reserving the initially observed foreign 40 GiB / 12 workers plus 5 GiB for SANY keeps this round below 200 GiB / 60 workers. Foreign tasks were left alone. State caches follow the pinned wrapper cleanup policy; inputs, logs, receipts and counterexamples are retained. The final report index records no unexpected contract failure or new implementation finding.
