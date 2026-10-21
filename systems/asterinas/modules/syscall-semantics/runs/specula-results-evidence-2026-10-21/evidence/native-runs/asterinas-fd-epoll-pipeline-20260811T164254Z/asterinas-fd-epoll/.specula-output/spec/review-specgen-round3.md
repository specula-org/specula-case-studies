# Spec Generation Review: asterinas-fd-epoll

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All six brief scenarios have dedicated variables, implementation-backed actions, focused hunt configs, and explicit section 2/5/6.1 coverage entries. |
| Action Design | 4/5 | The 70 production actions use implementation names and expose the main semantic boundaries. The eventfd notify/callback lock scope and the dead-before-disabled epoll branch are still ordered less strictly than Rust. |
| Source Annotations | 5/5 | Production helpers, actions, and invariant/property blocks carry pinned `file:line` citations; cited source starts resolve in the pinned checkout. |
| Invariant Coverage | 4/5 | Every brief invariant is defined, wrapped, and enabled in a focused config. `EpollKeyIdentity` is nevertheless implied by `TypeOK`, so its hunt has no independent identity oracle. |
| MC Spec Structure | 4/5 | Counter-bounded introductions, unbounded completions, symmetry, a counter-free view, a state constraint, and fairness are present. `WaiterReadinessWake` introduces readiness without a producer token but is classified as reactive. |
| Trace Spec Design | 3/5 | The Category B timebox ordering, direct base-action dispatch, no silent actions, and `TraceMatched` are present. Some scenario-critical post-state fields are not checked, and the positive fixture can finish with a selected synchronous callback still pending. |
| Instrumentation Mapping | 4/5 | MC, Trace, and instrumentation have identical 70-name sets with concrete source locations. The synchronous notify boundary and omitted epoch fields prevent fully faithful 1:1 state validation. |
| Logical Correctness | 3/5 | SANY/TLC accept the modules and controls are mutation-sensitive, but one extension invariant is type-tautological and several permitted transitions do not preserve source ordering or causality. |

## Overall: 32/40

## Issues Found

- The eventfd lock scope ends too early in the model. `EventfdNotify` publishes callback obligations and immediately sets `producerPhase[t]` to `"idle"` (`base.tla:1688-1705`); `ReadySetPushAcquire`/`ReadySetPush` execute later (`base.tla:1183-1209,2078-2093`). Rust holds `counter.lock()` across `self.pollee.notify(...)` (`kernel/core/src/syscall/eventfd.rs:124-159`), and `Pollee::notify` synchronously invokes `SyncSubject` callbacks (`kernel/core/src/process/signal/poll.rs:167-178`; `kernel/core/src/events/subject.rs:126-149`). The model can therefore run another eventfd mutator before the selected callback, which Rust forbids. `EventfdMutexExclusive` only checks simultaneous `event_notify` phases and cannot detect this early release.

- The supplied positive trace exposes the same ordering gap. Its `EventfdNotify` event reports one selected callback and `eventfd_owner = "no_thread"`, but the trace contains no `ReadySetPush*` event. `TraceMatched` still succeeds because it requires only input-event consumption (`Trace.tla:470-493`), not completion of callback obligations. A real `EventfdNotify` return cannot precede its synchronous callback. The trace protocol needs separate notify-begin/callback/notify-return boundaries, or it must retain the owner until all selected callbacks complete.

- Scenario-critical post-state validation is incomplete. `EpollWaitRegisterConsumer` updates `epollWaiter`, `readyEpoch`, and `consumerReadyEpoch` (`base.tla:1843-1865`), while its Trace branch and instrumentation row check only `epollWaiter` (`Trace.tla:316-317`; `instrumentation-spec.md:130`). `EntryUpdatePoll` similarly changes enablement, trigger mode, slot epoch, bindings, and consumer epochs (`base.tla:1080-1129`), but Trace checks only a subset (`Trace.tla:198-203`). A trace can therefore match while the implementation state central to Scenario 4 disagrees with the model.

- `EpollKeyIdentity` is not an independent invariant. `TypeOK` already requires `interest \subseteq InterestKeys` (`base.tla:2282`), and `InterestKeys` fixes the `epoll`, `fd`, and `ofd` domains (`base.tla:63-65`). `EpollKeyIdentity` repeats exactly those field-domain facts (`base.tla:2472-2478`); it cannot detect using the wrong in-domain OFD or slot generation. Consequently, the successful `MC_hunt_s2_key_identity.cfg` run does not validate the Scenario 2 identity mechanism.

- `EntryPollDisabled` does not preserve the implementation's ordered early returns. Rust upgrades the weak file first and returns `None` on failure before checking whether the entry is disabled (`kernel/core/src/events/epoll/entry.rs:103-124`). The model's disabled action requires only a popped delivery and `entryEnabled = FALSE` (`base.tla:1298-1304`), so a dead-and-disabled entry may take the disabled branch instead of `EntryPollDeadFile`, leaving its interest state unchanged.

- `WaiterReadinessWake` is treated as an unbounded reactive completion (`MC.tla:330-332`) even though its base guard contains no producer, callback, or readiness token and directly creates `visibleReady` (`base.tla:1951-1959`). `MC_hunt_s5_arbitration.cfg` enables it with `SourceLimit = 0` (`MC_hunt_s5_arbitration.cfg:25,33-38`). The reproduced violation is `register -> block -> timeout -> readiness wake -> timeout return`; it demonstrates the arbitration ordering, but not that a scoped implementation readiness path can produce the wake. Link the action to a producer epoch/callback or bound it as an introduction.

- Validation status: the source HEAD is `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`. Base simulation completed 50 traces at depth 35 (1,753 states). All 35 MC/config runs reproduced their documented PASS/CANDIDATE/REACH/CONTROL classifications; neutral `MC.cfg` completed with 288 generated / 156 distinct states, and the longest liveness hunt completed with 8,897 / 2,794. The positive trace completed with 19 / 18 states, while the one-field callback mutation failed `TraceMatched`. MC action names, Trace event names, instrumentation rows, and the union of enabled actions are each the same 70-name set. These checks establish executable model health, not source fidelity; no production Asterinas trace was supplied.

## Verdict: NEEDS_IMPROVEMENT
