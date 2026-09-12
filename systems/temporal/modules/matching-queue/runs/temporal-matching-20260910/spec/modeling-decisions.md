# Model boundary and generation record

Category A (Distributed / Message-Passing), as established in modeling-brief.md §1. Source checked at clean `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` in `/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching`.

Generation follows the explicitly supplied `spec_generation/SKILL.md`, `guide.md`, and all five references, sequentially in one agent. The guide's mandatory written Phase 2.5 audit takes precedence over the older checklist's optional wording.

Initial target: SQL TaskStore V1, SQLite semantics; one normal unversioned physical partition, one normalized priority 3, new matcher on, fairness off. Queue setup starts from an observed, empty initialized V1 queue after its fresh empty V2 drain settles. There is no fabricated migration-disable flag. Write batches contain one request; reader batch, reload threshold, range size, GC batch, owner lifetimes, callers and poller slots are explicit constants. This is a bounded queue configuration, not the complete production configuration.

Acceptance means Matching has successfully returned Add (including a response subsequently lost in transport). A committed initial append with a returned error is tracked separately and is not silently promoted to successful acceptance. Replacements of already accepted work retain the original obligation. History acceptance is an external durable-or-recoverable contract; it is distinct from Worker receipt, and a new outer start attempt has a fresh RequestId. Fatal Internal/DataLoss disposal is not assumed legitimate for eligible work.

Local reader critical sections, per-owner DB mutex serialization and single-writer serialization are preserved. Store effect, response, notification, caller receipt, History effect/reply, completion, cache update, metadata and deletion remain separate. Different owner lifetimes can overlap. Read and GC are not range fenced. Durable ack may lag or regress at takeover; priority cursors are monotone only within one owner lifetime.

The brief gates fairness S5/MC-5 on complete priority traces and a bounded baseline, and MC-4 on real backend paging evidence. Neither prerequisite is present at generation start. The coverage audit will state these gates explicitly; SQL empty-page reads must not be made nondeterministically nonterminal, and priority invariants must not be presented as fairness coverage.

No implementation traces or backend runs are produced by spec generation. Parser/model assembly checks, if executed, are recorded separately from implementation validation. The next harness phase must collect complete real queue + SQLite traces, including overlap and failure/reload and negative observation controls.
