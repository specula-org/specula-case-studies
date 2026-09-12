# temporal-nexus validation changelog

## Round 1 - Trace Validation
- [initialization] Pinned source is 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025 with the existing Phase 2.5 instrumentation. All six core spec files, five hunting configs, 21 raw recordings, and instrumentation handoffs exist. TraceMatched is enabled and ValidatePostState checks full equality.
- [capture-gap] The supplied recordings are implementation-raw receipts, not complete semantic post-state traces. Strict replay must be repaired before Phase 2. Raw receipts and original input hashes are preserved under output/validation-20260911.
- [fix] AddEvents / FinishWFT / GenerateDirtySubStateMachineTasks: capture bufferable Nexus events in the workspace buffer until transaction-close flushing, even without a started WFT. Evidence: healthy_async raw receipts 53, 57; historybuilder/event_store.go Add/Finish and mutable_state_impl.go closeTransactionPrepareEvents.
- [fix] Timer batch actions: retain the actual mutable-state timer groups through inner execution; track consumed logical entries separately in tx.consumed and remove them at FinishStateMachineTimers. Evidence: healthy_timeout receipts 77, 80, 81; timer_queue_task_executor_base.go loop and final assignment. Trace decoding checks the new set field; no post-state check was relaxed.
- [fix] RefreshWorkflowTasks: model timers and first wake already generated when the full refresh returns; preserve those physical wake outputs through subsequent close-transaction generation. Evidence: task_refresher.go refreshTasksForSubStateMachines.
- [fix] UpdateWorkflowExecution: permit independently observed definite pre-store failure directly from Prepared, preserving the path without a History append. Evidence: faultinjection/fault.go and definite_failure/start_definite_failure raw PersistenceFault receipts; successful and unknown outcomes still require Appended.
- [fix] Init: start from the actually recorded first normal WFT Started boundary. All 21 bootstrap database observations agree; EmptyDB still represents an empty unavailable workspace. Evidence: output/validation-20260911/bootstrap-observations.json.

- [validation] Five partial-state boundary diagnostics reject the original model and pass the revised one. Timer debugging used coarse/fine breakpoints and variable evaluation. SANY passes base/MC/Trace with the combined classpath; no full implementation replay passes.
- [evidence] Eleven fresh real SQLite schedules pass, with post-reload observations and healthy controls; 32 raw recordings are joined to independent write/read receipts and all nine observer negatives reject corruption.

## Result

**INCOMPLETE.** Round 1 trace validation remains unfinished: 0/21 original and 0/11 fresh raw files satisfy the complete semantic trace schema. The full observation-derived post-state join, WFT transaction grouping, task ownership and time abstraction remain open. Phase 2 and all five hunting configs were not run; no convergence or completed no-bugs result is claimed. See validation-report.md and output/validation-20260911/validation-summary.json.
