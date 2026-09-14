# NVFlare Payload Transfer Completion and Source Lifetime

## Goal
Assess whether payload transfer completion, receiver outcomes, and source lifetime remain consistent through ordinary concurrent downloads, confirmation, timeouts, cancellation, and cleanup. Produce source-grounded evidence for the selected functional contracts and make coverage gaps explicit.

## Scope
- Follow DownloadService transactions, object references, receiver progress and finalization, Consumer completion/confirmation, TransferOutcome, transfer waiters, and source release.
- Include the minimum caller integration necessary to establish what observers may conclude from a completed waiter or outcome callback.
- Keep the main scenario on the supplied version with receiver-confirmed completion enabled and explicit expected receivers. Document legacy/disabled-confirmation semantics separately when relevant.
- Exclude full FedAvg rounds, job scheduling, whole external-trainer process management, HA recovery, GPU/tensor numerical behavior, serialization internals, and the implementation of underlying byte-stream transports.

## Priority Questions
1. When the producer has served the terminal data but the consumer has not yet completed or confirmed consumption, can the transfer be reported as successfully completed?
   Expected contract: receiver-confirmed mode distinguishes terminal serving from confirmed receiver success; legacy producer-served behavior must not be judged by a stronger contract.
2. When different receivers complete different object references, can an aggregate outcome claim full success or a usable quorum that no corresponding receiver set actually holds?
   Expected contract: success is evaluated over the declared receivers and complete payload; FINISHED, completed, and quorum_met retain their documented meanings.
3. When confirmation, cancellation, timeout, and deletion overlap, can receiver outcomes or the final transaction outcome become inconsistent, or can settlement be published more than once?
   Expected contract: the supported termination paths preserve consistent final receiver information and transaction settlement, including in-flight operations and bounded drain behavior.
4. When one receiver continues making progress while another stalls or never starts, can activity tracking incorrectly suppress the latter's configured acquisition/idle termination or prematurely terminate healthy work?
   Expected contract: each configured budget follows its actual activity and receiver scope, including its relationship to transaction lifetime.
5. When finalization callbacks raise or source cleanup overlaps outstanding operations, can a waiter observe an outcome inconsistent with the required callback/release ordering, or can owned sources and waiters remain unresolved?
   Expected contract: follow the documented source-release and outcome-recording obligations, including error handling and bounded shutdown behavior; establish those obligations from both callers and callees.

## Must-cover Interactions
- DownloadService request/confirmation/cancellation handlers with per-reference receiver state and transaction ownership.
- Consumer completion and confirmation with producer-side provisional/final statuses.
- Receiver and transaction monitors with activity tracking and in-flight operation admission/draining.
- Outcome computation, callbacks, source release, outcome retention, and waiter resolution.

## Assumptions
- Participants are cooperative and use supported APIs with ordinary payloads; failures are ordinary runtime failures and asynchronous scheduling.
- Respect the API's supported object-registration lifecycle; do not invent concurrent late object additions prohibited by that contract.
- Establish the caller's actual receiver count/identity mode and timeout settings before judging outcomes; distinguish disabled confirmation and legacy peers explicitly.
- Limit implementation checks to local functional regression tests. Security-vulnerability reproduction and exploit development are outside this run.

## Suggested Starting Points
- nvflare/fuel/f3/streaming/download_service.py: DownloadService, _Ref, _Transaction, Consumer, TransferWaiter
- nvflare/fuel/f3/streaming/transfer_outcome.py: TransferOutcome, compute_transfer_outcome
- nvflare/fuel/f3/streaming/transfer_progress.py: progress and terminal states
- tests/unit_test/fuel/f3/streaming/receiver_confirm_test.py
- tests/unit_test/fuel/f3/streaming/receiver_budget_test.py
- tests/unit_test/fuel/f3/streaming/transfer_waiter_test.py
- tests/unit_test/fuel/f3/streaming/test_pass_through_e2e.py: distinguish real Cell paths from simulated hops

## Evidence Requirements
Address every priority question without assuming it is a known defect. Derive contracts from the current API and implementation context; do not encode the desired outcome as an assumption that makes violations impossible. Preserve the distinction between source analysis, model counterexamples, trace conformance, local regression evidence, known fixes, and incomplete work. Explore additional functional questions only within this transfer lifecycle boundary.
