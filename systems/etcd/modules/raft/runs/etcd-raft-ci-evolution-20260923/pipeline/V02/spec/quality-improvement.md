# V00 small quality improvement

Completed the scoped round within the one-hour window. The original model, configurations and bounds, harness, five real traces, and six negative traces are unchanged. Results and execution receipts are in [this round's record](output/quality-round-20260913-0910/quality-results.json).

`Quality.tla` adds five observational properties. They capture inputs and outputs at decision time and do not constrain protocol actions. Their oracles do not call the modeled decision helpers (`Step*`, `Promotable`, `UpToDate`, `RewriteConf`, `ConfigAfter`, `ConfigOf`, or `ExpectedDecision`). Common record/log access and payload summation remain shared abstractions.

| Property | V00 contract and retained outcomes |
|---|---|
| VoteDecisionEligibility | `raft.go:787–928`, `log.go:279`: term/CheckQuorum suppression, learner eligibility, vote reuse and log freshness; both unjustified grants and rejections fail. Removed nonlearners and candidates outside the local voter set are permitted by V00. |
| CampaignDecisionEligibility | `raft.go:863–887`: Hup checks local voter eligibility and unapplied configuration entries; permitted ignore, PreVote, election and compacted-slice fatal outcomes stay distinct. |
| TransferDecisionEligibility | `raft.go:1038–1046,1163–1199`: distinguish unknown/learner/same-target ignore, self cancellation, lagging-target admission and immediate TimeoutNow. |
| RequestCorrelatedConfigurationEffects | `README.md:120`, `node.go:135–163`, `raft.go:1420–1514`: each callback has a committed entry and matching request kind/target; independently derive voter/learner changes, deterministic cancellation, promotion, redundant add, prohibited demotion and Update no-op. API cancellation does not undo an already handed-off entry. |
| ProposalConfigurationDecisions | `raft.go:965–1002,1247–1262`: check admission/rejection and request identity through append or pending-change rewrite to an anonymous normal entry. A returned API call is not a commitment guarantee. |

`QualityTrace` preserves complete matching of all six observed state components, every original invariant, and TraceMatched. Observers retain only the latest action's evidence; the trace interface and base transitions do not change.

| Executed check | Actual result |
|---|---|
| Syntax and five real replays | SANY valid; all **3,543 events accepted**, with all **24 original + 5 new invariants**. |
| Six existing negative checks | All rejected at their original edited events: 14, 6, 240, 69, 136 and 1076. |
| Compact decision-context checks | Complete finite sets: **3,456 vote, 36 Hup, 66 transfer, 160 callback and 1,536 proposal observations**; no violations. These test core-function decisions, not whole-protocol reachability. |
| New sensitivity checks | All **11** deliberately invalid observations rejected by the intended property: unjustified rejection/ignore, forbidden admission, wrong request target, cancellation/demotion errors, and rewritten identity. They are formal diagnostics, not implementation findings. |
| Executable management progress | Five real queued-work windows, **35 states**, depth 4, queue exhausted. Fair ApplyEntry/FinishApplication drains the queued effects and jobs; legal Advance can interleave. Without caller fairness, TLC finds an unfinished-job stuttering cycle after callback and Advance. |

The management windows come from membership-snapshots events 233, 1165, 1338, 1437 and 1536: learner addition, promotion, canceled removal, Update no-op and removal. Initial source/caller states are copied exactly from the validated trace; accumulated pre-window ghosts are reset. This establishes only conditional drainage of existing queued work, with no further failures or new work. It does not establish proposal-to-commit, retry, recovery or system-wide management progress.

[Interaction witnesses](output/quality-round-20260913-0910/interaction-coverage.json) retain exact trace lines: 20 request-correlated callbacks; 25 callbacks and 2 vote decisions amid configuration disagreement; 5 callbacks with in-flight replication; 1 transfer to a learner, 1 with replica lag; 4 promotions, 4 canceled callbacks and 4 Update no-ops. Counts are visitation evidence. Completed reads retained in an observation buffer are excluded from pending-read coverage.

Remaining work is explicit in [remaining-validation-work.md](remaining-validation-work.md). In particular, these real traces do not exercise a configuration callback during an outstanding read or transfer, stale-log vote rejection, learner demotion, or a callback after API cancellation. Decision fixtures cover some missing local branches, not their distributed interactions. Independent TimeoutNow/PreVote-continuation eligibility, broader request/result semantics, Ready/Advance ownership, Storage-call concurrency and general liveness still need refinement. The original ten-configuration campaign was not repeated.

Every new TLC job used registered start_tlc/wait_tlc and a five-minute cap. Peak declared batches were 99 GiB/22 workers and 98 GiB/20 workers, within 200 GiB/60 workers. Native receipts, exact inputs and logs survive wrapper cache cleanup. No production protocol, confirmation verdict or CI state changed; integration remains manual.
