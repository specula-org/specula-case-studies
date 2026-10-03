# Brief Coverage Audit — CometBFT BYOM baseline

This audit was produced from the adopted `modeling-brief.md`, `base.tla`,
`MC.tla`, and the actual config files. It records wiring and reachability; it
does not report a current TLC or trace-validation result.

## Scenario coverage

| Brief Scenario | Base actions / state | Targeting config | Audit result |
|---|---|---|---|
| 1. Parameter update validation and installation | `FinalizeBlock`, `SaveFinalizeBlockResponse`, `UpdateStateAccepted`, `UpdateStateRejected`; `pendingParam`, `updatePresent`, `validationOutcome` | `MC_hunt_scenario1_params.cfg` | Both accepted and invalid symbolic parameters are in the finite domain; acceptance and rejection have dedicated reachability configs. |
| 2. Ordered durable boundaries during block application | `SaveBlock`, `ApplyBlockStart`, `SaveFinalizeBlockResponse`, `CommitApp`, `SaveState`, `Crash`; durable/volatile heights and parameter identities | `MC_hunt_scenario2_durability.cfg` | Two blocks and two crashes permit cuts before response save, before commit, and before state save; real and mock replay are reachable without app rollback. |
| 3. Height-matrix startup replay | `AppReportsOlderHeight`, `BeginHandshake`, `ReplayAppBlock`, `SelectRealReplay`, `SelectMockReplay`, `CompleteHandshake` | `MC_hunt_scenario3_recovery.cfg` | One bounded app rollback plus two blocks/two crashes covers app-only, real, mock, and synchronized completion branches. |

The focused initialization supplement confirmed that these three Scenarios
still cover the supplied model boundary. It added no fourth modeled Scenario.
Its adjacent `InitChain`, historical-index, backend-failure, and retry/liveness
items are documented coverage gaps, so BYOM Phase 2 intentionally adds no
actions, invariants, or hunt config for them.

## Safety invariant wiring

`MC.tla` extends `base`, so the base invariants are directly visible to every
MC config. `MCTypeOK` additionally checks the bounded wrapper counters.

| Brief invariant | Definition | Enabled in Scenario hunt config(s) | Status |
|---|---|---|---|
| `TypeOK` | `base.tla`; wrapped by `MCTypeOK` in `MC.tla` | scenarios 1, 2, 3 | Defined, wrapped, enabled. |
| `SuccessfulApplyAdvancesExactlyOne` | `base.tla` | scenario 2 | Defined and enabled. |
| `RejectedUpdateDoesNotInstall` | `base.tla` | scenario 1 | Defined and enabled. |
| `PersistedHeightRelationships` | `base.tla` | scenarios 2, 3 | Defined and enabled. |
| `ParameterUpdateReflected` | `base.tla` | scenario 1 | Defined and enabled. |
| `NormalPhaseIsSynchronized` | `base.tla` | scenarios 2, 3 | Defined and enabled. |
| `RecoveryNormalOnlySupported` | `base.tla` | scenario 3 | Defined and enabled. |

`MC.cfg` also enables the complete neutral invariant set. The narrower hunt
configs remain the Scenario-directed entry points.

## Model-checkable finding coverage

| Brief finding | Trigger represented by | Expected invariant(s) | Targeting config(s) | Status |
|---|---|---|---|---|
| `V0-MC-1` | `Crash` at cuts between block save, response save, application commit, and state save, followed by handshake/replay | `PersistedHeightRelationships`, `NormalPhaseIsSynchronized` | scenarios 2 and 3 | Trigger and checks wired. |
| `V0-MC-2` | `FinalizeBlock(pBad)` followed by response persistence and accept/reject branching | `RejectedUpdateDoesNotInstall`, `ParameterUpdateReflected` | scenario 1 | Invalid value is present and both outcomes have reachability witnesses. |
| `V0-MC-3` | bounded app rollback plus synchronized, app-only, real-last-block, and mock-last-block replay selection | `RecoveryNormalOnlySupported`, `NormalPhaseIsSynchronized` | scenario 3 | All replay selectors and completion have reachability configs. |

## Reachability witnesses

The `MC_reach_*.cfg` files deliberately assert a `NeverReached*` invariant; an
expected invariant violation is the witness that the target branch is
non-vacuous.

| Witness config | Target marker |
|---|---|
| `MC_reach_accepted.cfg` | accepted parameter update |
| `MC_reach_rejected.cfg` | rejected parameter update |
| `MC_reach_crash.cfg` | crash cut |
| `MC_reach_app_replay.cfg` | app-only replay |
| `MC_reach_real_replay.cfg` | real-app final-block replay |
| `MC_reach_mock_replay.cfg` | saved-response/mock final-block replay |
| `MC_reach_handshake_complete.cfg` | successful handshake completion |

## Trace and instrumentation handoff check

- `Trace.tla` has event-specific wrappers and a non-stub
  `ValidatePostState` covering every state field in `instrumentation-spec.md`.
- `Trace.cfg` selects trace-derived parameter domains and requires
  `TraceMatched`, preventing successful prefix-only replay.
- the default trace path is `../traces/apply_valid.ndjson`, with `IOEnv.JSON`
  available for per-trace selection.
- all modeled executable actions are mapped to source hook locations;
  `Crash`, `AppReportsOlderHeight`, and `EnvironmentStutter` are explicitly
  model-only.

The retained traces and harness remain Phase 2.5 inputs. Their existence and
schema were inventoried here, but no Phase 3 validation result is claimed.

## Phase 2 adoption checks

- SANY parsed, semantically processed, and linted `base.tla`, `MC.tla`, and
  `Trace.tla` from this workspace with the bundled TLA+ and Community Modules
  libraries.
- at the Phase 2 handoff, byte comparisons found no differences between the
  supplied and adopted reference/MC/Trace modules, configs, or instrumentation
  mapping. Phase 2.5 later reconciled the mapping's message-field table to the
  supplied patch and retained traces; no TLA+ action or state mapping changed.
- `git apply --check` accepted the supplied instrumentation patch against source
  commit `af998de26e82b796590b14fb2417864fc3c31202`.
- all six retained NDJSON files were nonempty, JSON-decodable, and conformed to
  the documented top-level trace envelope.

These are Phase 2 usability checks only. Model checking and trace replay remain
the responsibility of the later validation phase.
