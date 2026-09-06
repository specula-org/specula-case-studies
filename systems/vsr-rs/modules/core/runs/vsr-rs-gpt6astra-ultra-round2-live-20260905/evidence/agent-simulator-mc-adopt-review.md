# Independent review of proposed MC-ADOPT handoff

Pinned revision: `3ac0104a567092139534c9022205d02281a2da41`. Read-only review; no new test or simulator execution.

**Recommendation: omit MC-ADOPT from modeling-brief §6.1 in its proposed form.** An empty model-checkable finding table with an explicit explanation is more faithful to the code-analysis value criterion than a forced protocol hunt.

Proposed question reviewed: authentic delayed DoViewChange/NewState/RecoveryResponse across successive state adoptions and recoveries, with fresh nonces and correctly durable views, might overwrite an executed prefix or reconstruct client deduplication state incorrectly.

This is an important standard VSR correctness obligation, but the inspected code does not currently supply a concrete unhandled path or implementation deviation that makes it an actionable suspected defect. The AS-01 incremental-oracle weakness means an independent checker can improve assurance; it does not establish protocol reachability of the assumed prefix overwrite.

## Exact compensation checks

- NewState in ordinary state transfer only appends after the current log end (`lib.rs:856-873`). In catchup to a later view it requires `op_number_start == self.commit_number`, retains exactly that committed prefix, and replaces only the uncommitted suffix (`875-889`). The latter path structurally preserves existing executed entries.
- StartView accepts a newer view or the current view while still in ViewChange; it rejects same-view replay once normal (`948-967`). A legitimate newer-view log must preserve committed history by the view-change quorum argument. Showing that the generic helper does not compare prefixes (`1324-1344`) does not invalidate that caller-side protocol argument.
- DVC admission is keyed by view and intended primary (`926-942`); selection uses greatest `(last_normal_view, log.len())` and maximum commit among distinct sender records (`1043-1075`). This implements the standard selection rule. Re-delivery of DVC alone is not an identified new unaudited selection mechanism.
- A recovering object begins with commit number zero through Replica::new and is isolated from non-recovery messages (`478-524,528-535`). RecoveryResponse requires the current nonce while Recovering, quorum responses, a response with state from the highest represented view's primary, and a view at least the persisted one (`1159-1205`). Consequently `install_log` during conforming recovery does not overwrite an already executed prefix in that fresh local state machine. A global-history safety question remains standard recovery correctness, with no new deviation established here.
- `install_log` preserves a cached reply only for an exact matching committed client/request entry (`1324-1344`); `commit_up_to`/`commit_op` execute newly committed entries and cache their replies (`1347-1369`). A prior reply lost from the cache when a later uncommitted request is truncated does not identify an unanswered request under the documented one-request-at-a-time client contract (`272-277`): the client could only have submitted the later request after receiving the former's reply. Client restarts must use fresh identities (`29-31`). Relaxing either contract is a different caller/API scenario, not conforming-library MC-ADOPT.

## Value-litmus result and handoff

Predicted honest Phase 4 conclusion from the current broad question: a finite independent model may find no violation and provide bounded assurance, or may demonstrate that the standard guards are necessary. Neither is a new maintainer-actionable mechanism established by this analysis. The skill explicitly keeps historical defense audits and generic hardening targets out of §6.1. Historical fixes can remain in §2 Evidence and §7 Reference Pointers.

Do not manufacture an adversary that changes durable views, reuses recovery nonces, accepts an arbitrary conflicting StartView, or drops existing guards in order to make this question fail: that either violates its stated conforming-library premise or recreates known protection. Startup-fallback, singleton progress, example nonce policy, sender blocking, parent-directory durability, and AS-01 remain independent direct-test/code-review candidates.

If a faithful baseline specification is still built for future work, tracking global committed history across crashes and checking prefix agreement immediately after every handler are worthwhile scope decisions. Describe this as optional independent assurance, not a pending bug finding. No narrower concrete forward-looking protocol defect emerged in this review. This conclusion does not prove the library correct; it records the present evidence threshold for spending targeted model-checking effort.
