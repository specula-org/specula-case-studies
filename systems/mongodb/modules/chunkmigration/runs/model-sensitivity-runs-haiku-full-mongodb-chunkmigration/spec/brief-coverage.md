# Brief Coverage Audit: MongoDB Chunk Migration

Phase 2.5 self-audit mapping the Modeling Brief's bug families, invariants, and findings to spec artifacts.

---

## Coverage: Bug Families (Brief §2)

| Family | Mechanism | Hunting Config | Coverage |
|---|---|---|---|
| **Family 1** | Non-atomic commit/abort decision with crash windows between persistence and cleanup | `MC_hunt_family1.cfg` | ✓ Tight bounds on crashes (CrashLimit=3), targets DecisionDurabilityLeadsToCompletion |
| **Family 2** | Filtering metadata inconsistency when config server commit fails | `MC_hunt_family2.cfg` | ✓ Focused on metadata state consistency during failure, targets MetadataReflectsDecision |
| **Family 3** | Range deletion task lifecycle mismatch in abort path | `MC_hunt_family3.cfg` | ✓ Models abort path with donor task deletion before recipient notification, targets RangeDeletionConsistency |
| **Family 4** | Async critical section release failures leaving recipient blocked | `MC_hunt_family4.cfg` | ✓ Models release failure modes, targets CriticalSectionReleaseBeforeDone |
| **Family 5** | Error handling in abort notification to recipient | `MC_hunt_family5.cfg` | ✓ Models ShardNotFound exceptions during abort cleanup, targets RangeDeletionConsistency |
| **Family 6** | Interruptibility gaps (uninterruptible sections during critical operations) | — Not modeled | ✗ Out of scope: implementation liveness detail, not protocol safety. Modeling brief recommends "skip for initial modeling" |

---

## Coverage: Safety Invariants (Brief §5)

| Invariant | Type | Definition | Enabled In | Notes |
|---|---|---|---|---|
| **ChunkOwnershipConsistency** | Safety | At most one shard owns the chunk | MC.cfg (all) + Trace.cfg | Core property; enabled in all configs |
| **DecisionDurabilityLeadsToCompletion** | Safety | Once decision persists, migration completes consistently | MC.cfg (all), MC_hunt_family1.cfg, MC_hunt_family5.cfg, Trace.cfg | Targets completion guarantees; primary target for Family 1 |
| **RangeDeletionConsistency** | Safety | Donor task not ready before recipient ready | MC.cfg (all), MC_hunt_family3.cfg, MC_hunt_family5.cfg, Trace.cfg | Targets task lifecycle bugs; critical for abort path (Family 3, 5) |
| **NoDoubleCommit** | Safety | Migration cannot commit twice | MC.cfg (all), Trace.cfg | Structural safety; checked in all configs |
| **MetadataReflectsDecision** | Safety | If committed, metadata reflects new ownership | MC.cfg (all), MC_hunt_family2.cfg, Trace.cfg | Targets metadata consistency; primary target for Family 2 |
| **CriticalSectionReleaseBeforeDone** | Liveness | Critical section released before migration done | MC.cfg (all), MC_hunt_family4.cfg, Trace.cfg | Targets release failures; primary target for Family 4 |

**Invariant Enablement Summary**:
- **MC.cfg**: All Safety invariants enabled; EventualCompletion commented out
- **MC_hunt_family1.cfg**: Focus on DecisionDurabilityLeadsToCompletion + core safety
- **MC_hunt_family2.cfg**: Focus on MetadataReflectsDecision + ChunkOwnershipConsistency
- **MC_hunt_family3.cfg**: Focus on RangeDeletionConsistency + DecisionDurabilityLeadsToCompletion
- **MC_hunt_family4.cfg**: Focus on CriticalSectionReleaseBeforeDone + ChunkOwnershipConsistency
- **MC_hunt_family5.cfg**: Focus on RangeDeletionConsistency + DecisionDurabilityLeadsToCompletion
- **Trace.cfg**: All Safety invariants (foundation for real execution validation)

---

## Coverage: Model-Checkable Findings (Brief §6.1)

| Finding | Question | Trigger Mechanism | Expected Violation | Hunt Config | Reachability |
|---|---|---|---|---|---|
| **MC1** | Can donor crash after committing decision leave chunk stuck between shards? | Crash between decision persist (line 240) and cleanup completion | DecisionDurabilityLeadsToCompletion | MC_hunt_family1.cfg | ✓ Reachable: DonorPersistCommitDecision followed by DonorCrash |
| **MC2** | Can config server commit fail clear metadata while recipient in critical section? | Config commit fails (line 681) before metadata refresh, critical section still active | MetadataReflectsDecision | MC_hunt_family2.cfg | ✓ Reachable: ConfigServerCommitFails while CriticalSectionActive=TRUE |
| **MC3** | Can abort leave orphaned range deletion task forever? | Donor deletes task (line 350) before recipient marked ready (line 382), crash in between | RangeDeletionConsistency | MC_hunt_family3.cfg | ✓ Reachable: AbortDeleteDonorRangeDeletionTask → DonorCrash → abort path cannot notify recipient |
| **MC4** | Can critical section release failure leave recipient blocked indefinitely? | Release RPC fails (ShardNotFound at line 417), coordination forgets migration (line 226) | CriticalSectionReleaseBeforeDone | MC_hunt_family4.cfg | ✓ Reachable: CriticalSectionReleaseFails followed by ForgetMigration, recipient never released |
| **MC5** | Can abort error during recipient notification orphan range deletion task on recipient? | Recipient notification fails (line 365-375), ShardNotFound exception caught, forgetMigration called anyway | RangeDeletionConsistency | MC_hunt_family5.cfg | ✓ Reachable: AbortBumpRecipientTxnNumber succeeds but AbortMarkRecipientRangeDeletionReady fails |

**Finding Trigger Paths**:
- MC1: `DonorPersistCommitDecision` → [crash window] → `DonorCrash`
- MC2: `DonorSendConfigServerCommit` → `ConfigServerCommitFails` (with CriticalSectionActive) → metadata cleared while recipient blocked
- MC3: `AbortDeleteDonorRangeDeletionTask` → [crash window] → `DonorCrash` prevents notification flow
- MC4: `LaunchReleaseRecipientCriticalSection` → `CriticalSectionReleaseFails` → `ForgetMigration` (recipient still blocked)
- MC5: `AbortBumpRecipientTxnNumber` (succeeds) → `AbortRecipientNotificationFails` (ShardNotFound) → `ForgetMigration` (task stuck pending)

---

## Out-of-Scope Items

### Family 6: Interruptibility Gaps
**Brief classification**: "Poor" TLA+ suitability, "Low" priority.
**Decision**: Not modeled. Rationale from modeling brief:
> "Implementation detail; doesn't affect protocol correctness. Liveness is the concern, not safety."

TLA+ is designed for safety violations. Interruptibility is an implementation-level availability concern (can delay shutdown). No spec actions needed.

### §6.2 / §6.3 Test-Verifiable Findings
These are code-review and chaos-test findings (TV1, TV2, TV3, CR1, CR2, CR3), not model-checkable. Out of scope for TLA+.

---

## Spec Action-to-Family Mapping

| Spec Action | Families Triggered | Notes |
|---|---|---|
| `DonorPersistCommitDecision` | Family 1 | Crash window opens here |
| `ConfigServerCommitFails` | Family 2 | Triggers metadata inconsistency |
| `CriticalSectionReleaseFails` | Family 4 | Release failure model |
| `AbortDeleteDonorRangeDeletionTask` | Family 3 | Task deletion before notification |
| `AbortRecipientNotificationFails` | Family 5 | Notification failure in abort |
| `DonorCrash` | Families 1, 3 | Creates crash windows |
| `ForgetMigration` | Families 4, 5 | Final cleanup without full state |

---

## Completeness Check

✓ **All Brief §2 families have targeting hunt configs** (except Family 6, which is out of scope by brief design)  
✓ **All Brief §5 Safety invariants are defined, wired, and enabled in ≥1 hunt cfg**  
✓ **All Brief §6.1 findings are targeted by at least one hunt cfg**  
✓ **No silent coverage gaps** — every family either has a dedicated hunt config or an explicit merger (none for this target)  
✓ **Trace spec includes all safety invariants** for real execution validation  

---

## Notes for Phase 3 (Harness Generation)

The instrumentation-spec.md provides the source code locations and event field mappings for each action. Key instrumentation priorities:

1. **High priority** (triggers bug manifests):
   - `DonorPersistCommitDecision` (Family 1 crash window)
   - `ConfigServerCommitFails` (Family 2 metadata state)
   - `AbortDeleteDonorRangeDeletionTask` (Family 3 task lifecycle)
   - `CriticalSectionReleaseFails` (Family 4 release failure)
   - `AbortRecipientNotificationFails` (Family 5 error handling)

2. **Medium priority** (supporting actions):
   - All range deletion task state transitions
   - Critical section state tracking
   - Decision persistence on multiple nodes

3. **Low priority** (structural completion):
   - Crash/recovery actions (optional; auto-detectable from state resets)
   - Cleanup finalization steps

---

## Spec Convergence Readiness

**Status**: Ready for Phase 3 (Trace Validation)

The base spec and MC configs are structurally sound:
- No missing actions (all brief-identified mechanisms modeled)
- No orphaned invariants (all targeted by ≥1 config)
- Fault injection bounds are reasonable (CrashLimit=2-3, TimeoutLimit=2-3)
- Silent actions are constrained (only crash/recovery, tightly bounded)

Next: Instrument the system and collect execution traces for validation.
