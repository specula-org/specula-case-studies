# Search strategy and proof boundaries — 2026-09-11

The user explicitly authorized tractable abstractions, separate contract checks and per-check budgets in this continuation. The original three-work/six-record `MC.cfg` and its 2026-09-10 timeout are preserved. No smaller check is presented as completion of that original search. Global run limits and routing were not edited: TLC admission remains 112 GiB and 32 workers. Checks request 16 GiB heap plus 32 GiB off-heap, using 32 workers alone or two 16-worker checks.

## Why the original search was shallow

The detailed model preserves 85 action types, independent writer/reader/metadata/dispatch phases, caller and Worker receipts, owner lifetimes, fault budgets, opaque History UUIDs and audit journals. Independent failures/expiry/obsolescence can occur before work enters the queue. Retired frames and UUID labels multiply states even when their future queue behavior is equivalent. The original run reached 307,620,915 distinct states but only depth 16. A new 120-second run with unchanged original bounds and `ContractView` also remained incomplete; it is retained rather than substituted for a pass.

## Semantic reductions

`MCContract.tla` preserves the detailed actions. Its view removes only retired frame fields and non-controlling audit journals. The guarded use sites were inspected: idle reader fields are overwritten before use; completed calls remain fully represented while any writer/dispatch still refers to them; free reader-lock cachePoller, inactive GC count/bound and non-stopping stopStep are overwritten before use. `cacheRead` is retained because CursorOrder reads it. Accepted/committed sets, replacement lineage, durable rows/ack, all owner/read/lock state and fault counters remain. The complete priority-invariant truth vector remains in the view. TypeOK is also included; MCTypeOK retains its counters and subsumes TypeOK.

History RequestIds are opaque equality tokens. `UsedStarts` reserves active RPC and accepted History IDs; a retired failed attempt cannot participate in a later comparison. `ContractNext` chooses one fresh alias, preserving transport retry identity and every live equality comparison. It does not equate two live requests or turn an unknown accepted effect into noncommit. Raw and reduced current-model checks on the same one-work normal scope both completed at depth 41 (68,392 versus 11,282 distinct states). This is a finite cross-check, not a general refinement proof.

`GCOrdered.tla` additionally moves Worker-receipt cleanup before independent queue steps in its explicitly asserted no-crash/no-loss scope. A successful Worker response follows History acceptance and task completion; its action changes only the completed poller's availability and `history.worker`. Queue safety properties do not depend on that bit. The RequestId remains reserved by History, and another action cannot reuse that poller before receipt. Moving receipt left across other owners' store/read/ack/metadata steps preserves their queue-state effects. This reduction must not be reused for a receipt-timing property or with crash/loss enabled.

`GCOrbit.tla` uses role-specific alpha renaming of the two interchangeable poller slots and live opaque RequestIds. It renames dispatch keys, cachePoller, writer poller and append-queue poller references together. Work identities, storage IDs, owner IDs/ranges, read/ack boundaries and seed stage remain fixed. The same equivalence class is used for pending and accepted RequestId comparisons. This does not remove either poller or an out-of-order completion. The seed has one concrete source-action path per stage; after its frontier the transition relation and checked properties are insensitive to these names.

## Separate source-action frontiers

`Scenario_*.tla` starts at MCInit and executes an explicit prefix of existing base/MC actions before exploring all enabled suffix interleavings. It does not load guessed state or infer missing implementation observations. Safety invariants remain enabled during the prefix. The stage variable distinguishes prefix positions; reaching a depth beyond SeedLength proves the frontier was entered. Work symmetry is disabled in these named-prefix checks.

- Acceptance: initial write submitted, before its store outcome. Write uncertainty, receipt loss and same-work caller retry are checked in the completed one-owner scope; combined takeover/store-failure variants retain incomplete results.
- Read/bypass: a real-style read is outstanding while the first successful writer still needs to notify/bypass. Two work items and two pollers remain; the completed backoff scope includes a read failure and independent timer wakeup. The wider expiry/uncertain-write combination remains separately incomplete.
- GC/ownership: two accepted records, first History start accepted but completion not yet acknowledged; the second record is still eligible. Owner replacement, captured metadata and unfenced old-owner GC remain concurrent. Receipt and name reductions preserve both records and pollers.
- Replacement: the original is accepted and the History no-start rejection has entered re-spooling. Definite rejection, committed-but-error replacement, retry, lease renewal and terminal failure remain in the completed one-owner write scope. Combined additional owner replacement/stop is a wider retained incomplete check.

## Conditional progress

The original many-instance strong-fairness formula exceeded TLC's temporal DNF limit before exploration. `RecoveryFairness.tla` groups writer, reader, completion and poller steps, with weak fairness for continuously enabled metadata completion. The current detailed MC!ProcessingFairness per-action assumptions imply these weaker finite-group assumptions (the extra uncertain-return writer alternative has the same enabling condition as a normal successful return). The progress predicate was not weakened.

The two recovery checks use no state constraint, no symmetry and no VIEW. Their legal prefixes establish accepted pending work: one at replacement, one after supported stop/reacquisition. After the prefix, the store is available and there are no further injected failures or new arrivals; a stable owner and eventual eligible processing/polling are explicit assumptions. They do not prove recovery under arbitrary fault histories or absent pollers. Both prefixes reach their frontier and both complete temporal checking of the entire finite graph.

## Conditional contract composition

`QueueContracts.tla` is a separate composition model, not a replacement implementation model. It assumes prefix soundness when an owner advances ack, the obligation checked in the detailed reader/completion scopes. It models resolved-write maxRead advertisement, monotone per-block allocation, atomic range-fenced writes, metadata snapshot/commit/return, takeover closing the old block, and unfenced GC with an old captured bound. It permits a higher durable copy of the same logical work to carry the obligation and requires coverage for every committed work, which is stronger than coverage of successful caller receipts alone.

The four-record/two-work/two-owner result is conditional on that prefix obligation and the selected resolved-outcome store contract. It does not independently prove the reader algorithm, unresolved remote transaction behavior, or general History durability. No GC-time recheck of prefix soundness is assumed. The normal model completed; deliberately deleting one record beyond the captured bound and permitting an old-range write both produced counterexamples. Those are oracle controls, not Temporal findings. An initial sticky-flag expression error found by a control was corrected and all three checks rerun.

## Retention and incomplete work

Every run has copied models/configs, exact hashes, command, resources, full output and a process result. Timed-out counts are last logged samples. Checkpoints are retained and successful resumes keep the original fingerprint polynomial and verify model/config hashes. Resumed distinct counts are cumulative; generated counters are reported per TLC invocation and are not summed as unique coverage.

The original full search and wider mixed-fault checks remain INCOMPLETE. The four supplied hunt bounds also received depth-100 simulation at 120 seconds each; sampling is not exhaustion or convergence. Their unexecuted process-crash/transport observation paths and actual History lifecycle remain limitations. SQLite V1 implementation traces calibrate priority behavior; the separate SQLite V2 fairness diagnostic does not certify the entire fairness model or other persistence backends.

Hard-crash handoff: before treating Crash-enabled simulations as implementation confirmation, reconcile buffered local receive/shutdown actions (SyncTaskReceive, AppendTaskReceive and AppendTaskShutdown) with process death using an external driver. Current completed detailed scopes use CrashLimit=0 and do not discharge that observation/fidelity obligation.
