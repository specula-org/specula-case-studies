# Spec Generation Review: asterinas-fd-epoll

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All six brief scenarios have explicit base-spec sections, extension state, and focused hunt configs. |
| Action Design | 3/5 | Most implementation boundaries are split and named well, but `FcntlSetFl` collapses lookup/use, `SysCloseRangeCloexec` splits a single lock scope, and several actions have no production counterpart. |
| Source Annotations | 2/5 | Actions usually have one function-level citation, but helpers, invariants, guards, `LET` branches, and state-update blocks are not individually annotated as required. |
| Invariant Coverage | 3/5 | Every brief invariant is defined, wrapped, and enabled in a hunt, but the Scenario 4 safety oracle has a false-positive intermediate state and several other oracles are constructional or history-vacuous. |
| MC Spec Structure | 3/5 | Symmetry, a counter-free view, constraints, and focused bounds are present. Normal delivery/wakeup steps are also bounded, while an uncaused callback action remains unbounded. |
| Trace Spec Design | 3/5 | The Category B timebox ordering, direct base-action dispatch, field validation, and `TraceMatched` check are strong. Actor and target identities are conflated for cross-thread wake/signal events. |
| Instrumentation Mapping | 3/5 | The table covers every action name, but it is not 1:1 with production code: some actions combine sites, use test-only hooks, or describe a branch absent from the pinned source. |
| Logical Correctness | 2/5 | All modules pass SANY, but a hunt reaches a false-positive invariant, callbacks can occur without a producer notification, and multiple properties cannot detect the behavior named in the brief. |

## Overall: 24/40

## Issues Found

- `SignalfdBindingCoversConsumer` can fail during a correct `epoll_ctl(ADD)` intermediate state. `EpollAddInterest` inserts and enables the key before moving `ctl` to `"poll"` (`base.tla:668-681`), while `EntryUpdatePoll` registers and binds it in the next action (`base.tla:736-749`). The invariant quantifies every key in `interest` without requiring `registered` or completed control (`base.tla:1684-1691`). A bounded Scenario 4 simulation stopped on exactly this pre-registration state, so the hunt does not establish MC-3.

- `ReadySetPush` is enabled for any registered, enabled key without a source transition or pending notification (`base.tla:773-789`). In Rust it is reachable only through `Observer::on_events` after `SyncSubject::notify_observers` invokes the callback (`kernel/core/src/events/epoll/entry.rs:280-283`; `kernel/core/src/events/subject.rs:126-149`). The model can therefore fabricate readiness and satisfy or mask notification properties.

- Two Scenario 1 actions use incorrect concurrency granularity. `FcntlSetFl` re-reads `slots[fd]` and updates the OFD in one action (`base.tla:559-571`), although `get_file_fast!` captures an OFD before `update_status_flags` (`kernel/core/src/syscall/fcntl.rs:87-94`; `kernel/core/src/fs/file/file_table.rs:335-367`). Conversely, `SysCloseRangeCloexec` models one independently interleavable action per slot (`base.tla:573-586`), while the implementation holds one file-table write lock across the complete loop (`kernel/core/src/syscall/close.rs:80-101`). This can hide a reuse window in the first case and invent impossible MC-8 interleavings in the second.

- The readiness-cache PC omits the loaded cache value and checker identity. `PolleePollWithBeginCheck` tests the current `cacheState` and installs a single generic `"checking"` marker atomically (`base.tla:958-967`), so two threads cannot both load `INV_STATE` before either performs the later swap. The implementation separates the load, branch, task-pointer swap, live check, and compare-exchange (`kernel/core/src/process/signal/poll.rs:106-148`). That missing interleaving is material to a Category B cache model.

- Trace events use `line.tid` both as the executing thread and as the target waiter or signal queue. `MatchEvent` passes `t` directly to `SigQueuesEnqueueThread`, `WaiterReadinessWake`, `WaiterTimeoutExpires`, and `WaiterSignalInterrupts` (`Trace.tla:394-410`), with no target argument. The instrumentation envelope defines `tid` as the executing POSIX thread (`instrumentation-spec.md:35-44`), but the signal row redefines it as the destination thread (`instrumentation-spec.md:131`). Producer callbacks and timer callbacks may wake another thread, so their timebox order cannot be represented faithfully.

- Several invariants are not mutation-sensitive. `NoCrossReuseDelivery` compares two values assigned from the same prepared key (`base.tla:893-907,1658-1661`); `CapturedReferenceStable` compares values assigned from the same capture (`base.tla:379-407,1625-1627`); `AcyclicEpollGraph` is guaranteed by the only graph-insertion guard (`base.tla:1388-1411,1704-1707`). `LevelReadyEventuallyRedelivered` and `RegisteredTransitionNotLost` also accept historical membership in `deliveredKeys` or `observedReady`, which is not cleared per readiness epoch (`base.tla:1713-1729`). These checks can pass after a later delivery or notification is lost.

- The instrumentation mapping has explicit non-1:1 exceptions: `CapturedFileOperation` combines unrelated consumers (`instrumentation-spec.md:84`), `FileLikeFinalDrop` requires a fixture-only hook (`instrumentation-spec.md:99`), `ResetWait` is test-controller state (`instrumentation-spec.md:148`), and `EpollRejectNestedCycle` has no pinned-source branch (`instrumentation-spec.md:150`). The last action is nevertheless in `base.Next` and `Trace.MatchEvent` (`base.tla:1532-1535`; `Trace.tla:419-422`).

- The MC wrapper counter-bounds normal reactive delivery actions `ReadySetPopDeleted` and `ReadySetPop` (`MC.tla:86-89`) and the readiness callback (`MC.tla:127-128`). This conflicts with the rule that deterministic/reactive completion steps remain unbounded and can make a target path disappear when an unrelated delivery consumes the shared budget.

- Scenario hunts are not isolated per independent oracle. Scenario 2 enables final-drop, copyout, identity, and one-shot checks together; the short `MCNoDeadInterest` violation terminates TLC before copyout coverage is demonstrated. Scenario 4 similarly combines the false-positive safety check with `MCRegisteredTransitionNotLost`. Being listed in a cfg is therefore weaker than being effectively hunted.

- Source citations are too coarse for the generation contract. For example, the multi-branch delivery update (`base.tla:858-875`), wait return selection (`base.tla:1314-1356`), helpers (`base.tla:226-295`), and all invariant bodies (`base.tla:1621-1729`) lack block-level `file:line` annotations.

- Validation status: SANY accepted `base.tla`, `MC.tla`, and `Trace.tla`. Random TLC smoke runs completed for `base.cfg` and `MC.cfg`; focused simulations reached `MCNoDeadInterest`, `MCCachedReadinessSound`, `MCSignalfdBindingCoversConsumer`, and `MCVisibleReadyWinsTerminalRace`. These were bounded simulations, not exhaustive proofs. Trace replay was not run because no trace file is present. VAV results were inconclusive because the analyzer failed on aliases/import resolution while incorrectly returning success.

## Verdict: NEEDS_IMPROVEMENT
