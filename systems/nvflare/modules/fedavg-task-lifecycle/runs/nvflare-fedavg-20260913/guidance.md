# NVFlare FedAvg Round and Task Lifecycle

## Goal
Assess whether the current FedAvg workflow preserves round, task, and contribution consistency through ordinary asynchronous execution, retries, errors, and cancellation. Produce source-grounded evidence for the selected functional contracts and make coverage gaps explicit.

## Scope
- Follow the current Recipe FedAvg path through FedAvg, BaseModelController/ModelController, WFCommServer, broadcast task management, and the client task/result boundary.
- Include task publication and retrieval, protected broadcast input, result dispatch and acceptance, aggregation callbacks, task termination, and handoff to the next training round.
- Follow adjacent callers and callees when necessary to establish this lifecycle. Keep this run on the current FedAvg path; ScatterAndGather, Swarm, and other workflow policies are separate scopes.
- Exclude model convergence and floating-point accuracy, GPU kernels, job admission/resource scheduling, HA recovery, and the internals of streamed payload transport. Payload transport is an interface whose actual delivery/completion guarantees must be stated.

## Priority Questions
1. When clients retrieve the same broadcast at different times while earlier results are being processed, can they observe different global-model versions or changed task data?
   Expected contract: the broadcast provides its documented protected input consistently to its targets; contribution processing must not silently change another target's input.
2. When an ordinary client retries a result submission or a previous task's result arrives late, can it be counted twice or affect a later round?
   Expected contract: task/client/round association and duplicate handling follow the selected workflow's real contract, including the limits of completed-task history.
3. When a result is received but conversion, validation, or the aggregation consumer rejects it or raises an exception, can acceptance events, contribution accounting, and task completion disagree?
   Expected contract: receipt and accepted contribution are distinguished; any published acceptance reflects the consumer's actual decision and error policy.
4. When result callbacks, task termination, cancellation, and round advancement overlap, can an ended task change a later round's aggregation state or leave inconsistent completion information?
   Expected contract: lifecycle and round isolation remain consistent. Establish the actual cancellation boundary; do not assume cancellation rolls back already accepted work or instantly stops every callback.
5. When selected clients finish, or a configured error/dead-client/cancellation condition applies, can a task remain unnecessarily standing or the workflow report an inconsistent outcome?
   Expected contract: progress and final outcomes follow the actual configured policy. Default FedAvg waits for all selected clients and does not set a task timeout; a permanently missing response is not by itself evidence of a defect.

## Must-cover Interactions
- FedAvg round control and aggregation callbacks with BaseModelController result conversion and acceptance reporting.
- WFCommServer task request/submission handling, monitor, completed-task bookkeeping, and broadcast completion policy.
- Task identity and round metadata across normal client execution and server result dispatch.
- The real lock, callback, and event boundaries governing concurrent execution; avoid assuming a whole round or handler is atomic without source evidence.

## Assumptions
- Participants are cooperative and use supported APIs with ordinary task/result data; failures are ordinary runtime failures and asynchronous scheduling.
- Use the supplied pinned source and record the actual configuration. Do not import ScatterAndGather threshold/grace semantics into default FedAvg.
- Limit implementation checks to local functional regression tests. Security-vulnerability reproduction and exploit development are outside this run.

## Suggested Starting Points
- nvflare/recipe/fedavg.py: FedAvgRecipe._create_controller
- nvflare/app_common/workflows/fedavg.py: FedAvg.run, _aggregate_one_result
- nvflare/app_common/workflows/model_controller.py: ModelController.send_model
- nvflare/app_common/workflows/base_model_controller.py: broadcast_model and result callbacks
- nvflare/apis/impl/wf_comm_server.py: WFCommServer
- nvflare/apis/impl/bcast_manager.py: BcastTaskManager
- tests/unit_test/apis/impl/controller_test.py: FakeClock and task lifecycle tests
- tests/unit_test/app_common/workflow/fedavg_test.py: aggregation and acceptance tests

## Evidence Requirements
Address every priority question without assuming it is a known defect. Derive contracts from the current API and implementation context; do not encode the desired outcome as an assumption that makes violations impossible. Preserve the distinction between source analysis, model counterexamples, trace conformance, local regression evidence, known fixes, and incomplete work. Explore additional functional questions only within this lifecycle boundary.
