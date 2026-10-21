# Spec Generation Review: asterinas-fd-epoll

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 4/5 | All six scenarios have dedicated state, actions, and hunt configs, but several brief-required paths are absent from every MC action set and the ADD path used by Scenarios 2/4 is ordered incorrectly. |
| Action Design | 3/5 | Most actions use implementation names and split real semantic boundaries. ADD/update is reversed, some final Arc releases are omitted, and eventfd counter operations can cross a lock scope that is atomic in Rust. |
| Source Annotations | 5/5 | Semantic helpers, actions, and invariant blocks carry pinned `file:line` citations. The ADD citation points to the right lines but interprets their order incorrectly; that is scored under action and logical correctness. |
| Invariant Coverage | 3/5 | Most brief properties are defined, wrapped, and isolated in dedicated configs. `AcyclicEpollGraph` is missing, and `FdFlagsPerSlot` is tautological and exercised without creating duplicated slots. |
| MC Spec Structure | 4/5 | Introduction actions are counter-bounded, completions are reactive, and symmetry, counter-free view, constraints, and fairness are present. Eight base actions are disabled in every checked config, and readiness introduction is left unbounded. |
| Trace Spec Design | 4/5 | The Category B timebox ordering, direct base-action dispatch, absence of silent actions, post-state checks, and `TraceMatched` property are sound structurally. It inherits the base semantic gaps and hard-codes a fixture instead of supporting the standard runtime trace override. |
| Instrumentation Mapping | 3/5 | The event-name audit is exactly 70 Trace branches to 70 mapping rows, but the ADD row states the opposite production order, terminal OFD-release boundaries are not captured, and one mapped event is unreachable. |
| Logical Correctness | 2/5 | SANY accepts all modules, but the model contains a source-order inversion, a TLC-confirmed phantom-live OFD state, an impossible action guard, and a tautological Scenario 1 oracle. |

## Overall: 28/40

## Issues Found

- `EpollAddInterest` and `EntryUpdatePoll` reverse the production order. The model inserts and enables the interest first, then registers and polls it (`base.tla:887-907,964-1006`). Rust calls `entry.update(...)` before `interest.insert(...)` while holding the interest lock (`kernel/core/src/events/epoll/file.rs:96-124`). Therefore `S4LegalAddIntermediate` (`base.tla:2359-2367`) and `MC_control_s4_legal_intermediate.cfg` witness a state that the pinned source cannot reach. The same incorrect ordering appears in the instrumentation row (`instrumentation-spec.md:93`).

- OFD lifetime accounting leaks the captured `epoll_ctl` Arc. `ofdRefs` counts an active `ctl` target (`base.tla:327-338`), but `EpollDelInterest`, `EpollControlError`, and `EpollControlPushReady` clear `ctl` without applying `AliveAfterOneRelease` (`base.tla:928-962,1008-1040`). Rust owns an `Arc` from lookup until `control` returns (`kernel/core/src/events/epoll/file.rs:65-84`). A focused TLC control reached `ofdAlive[o] = TRUE` with `ofdRefs(o) = 0` in seven steps after close/drop raced with ADD completion. `FileTableCloseFilesOnExec` similarly leaves `ofdAlive` unchanged even though Rust drops the returned `ClosedFile` vector (`base.tla:838-859`; `kernel/core/src/process/execve.rs:378-386`). These omissions can hide `NoDeadInterest` violations and permit impossible OFD resurrection through `FileTableInsert`.

- `PollFilesInitialReady` is unreachable. `Init` sets `visibleReady` false, `PollFilesRegisterPoller` preserves it, and the only action that sets it true requires the waiter already be `blocked` or `woken` (`base.tla:487-496,1742-1757,1785-1797`). `PollFilesInitialReady` instead requires `waitState = "registered" /\ visibleReady` (`base.tla:1759-1770`). A focused exhaustive control enabling register plus initial-ready explored three states and found no witness. No shipped MC config enables `PollFilesInitialReady`, so the mapped Trace event at `instrumentation-spec.md:132` cannot be validated.

- Scenario 1's flag oracle cannot detect shared descriptor flags. Given equal OFDs, `FdFlagsPerSlot` compares `ofdStatus[slots[fd1]]` with the same function value and otherwise only repeats type checks (`base.tla:2231-2239`). `MC_hunt_s1_flags.cfg` enables no duplication action (`MC_hunt_s1_flags.cfg:33-44`), so distinct slots never alias an OFD in that hunt. Its completed 715-state search does not establish the brief's per-slot `FdFlags` property or the duplication half of MC-8.

- The brief's `AcyclicEpollGraph` safety invariant is absent. `SupportedNestedTopology` is used as an MC state constraint (`base.tla:404-410`; `MC.tla:475-478`), which prunes disallowed states instead of checking and reporting the required invariant. The Scenario 6 config checks lock/epoch properties only (`MC_hunt_s6_nested.cfg:47-52`). This does not satisfy modeling brief section 5 (`modeling-brief.md:159`) or the brief-coverage rule that every safety invariant be defined, wrapped, and enabled.

- MC coverage omits production actions that the brief explicitly names. Across `MC.cfg`, all hunt configs, and the control config, the union of `EnabledActions` never includes `SysDup2Equal`, `FileTableDupCeil`, `EpollDelInterest`, `EpollControlError`, `EpollDiscardEmptyPreparation`, `SignalFileReadThread`, `SignalFileReadProcess`, or `PollFilesInitialReady`. This leaves duplicate-allocation, explicit epoll deletion/error, consumer read, empty delivery, and initial-ready branches outside model checking despite their presence in `base.Next` and Trace.

- The eventfd split permits impossible counter interleavings. `EventfdAddCounter` and `EventfdTryRead` mark only the executing thread's `producerPhase`, so another thread may mutate `eventCounter` before `EventfdNotify` (`base.tla:1494-1554`). Rust holds the single counter mutex across the mutation and synchronous `pollee.notify` (`kernel/core/src/syscall/eventfd.rs:124-159`). The split is useful for cache/notification interleavings, but it needs a source-global lock/owner guard to exclude a second counter mutator.

- Trace post-state validation is nontrivial and the 70-to-70 name audit passes, but some multi-key notification branches validate only `pending_callback_count` (`Trace.tla:234-278`). A wrong observer identity can therefore pass if the count is unchanged and the trace ends before the callback event. Capture the selected key/actor pairs or validate the affected per-key epochs.

- Validation status: SANY accepted `base.tla`, `MC.tla`, and `Trace.tla`. Exhaustive TLC runs completed for `MC.cfg` (156 distinct states), `MC_hunt_s1_flags.cfg` (197), `MC_hunt_s5_mask_restore.cfg` (433), `MC_hunt_s6_nested.cfg` (610), and the supplied positive Trace fixture (10). These finite passes establish parser/model health only; they do not override the source-fidelity and reachability defects above. No production Asterinas trace was supplied or replayed.

## Verdict: NEEDS_IMPROVEMENT
