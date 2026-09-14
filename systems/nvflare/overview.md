# NVFlare

## Scope

Specula analyzed and tested NVFlare's FedAvg training-round and task/result lifecycle, and streamed-payload completion, including contribution acceptance, duplicate results, aggregation, receiver confirmation, cancellation, settlement callbacks, source release, and timeouts.

## Bugs

Specula found 6 new bugs:

- A lazy tensor materialization failure can leave partial aggregation from a rejected contribution in the saved global model.
- A duplicate result arriving after completed-task cache eviction remains retained in controller context until context replacement, even though it is not aggregated again.
- An executor submission failure after enqueueing can cause inline fallback and a later worker to repeat settlement callbacks and source-release attempts.
- Pipelined EOF can publish completed source progress after receiver cancellation, while receiver status and the final transfer outcome remain failed.
- Multi-target stream sends omit the expected payload receivers, allowing the first receiver's completion to retire the source before later targets download it.
- **Diagnostics:** The receiver-idle warning incorrectly says the budget cannot fire, even though another receiver can refresh transaction activity while a stalled receiver reaches its idle limit.
