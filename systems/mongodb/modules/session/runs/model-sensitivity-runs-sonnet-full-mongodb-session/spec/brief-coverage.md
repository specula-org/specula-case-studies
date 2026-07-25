# Brief Coverage Self-Audit (Phase 2.5)

Mapping: brief §2 (Bug Families) → §5 (Invariants) → §6.1 (Model-Checkable Findings) → spec/MC artifacts.

---

## §2 Bug Families → Hunt Configs

| Brief Family | Hunt Config | Target Invariant(s) | Notes |
|---|---|---|---|
| Family 1: Refresh-Reap Race | `MC_hunt_family1.cfg` | `TxnRecordSafeWhileLive` | Both `StartRefresh` and `StartReap` enabled; no kill faults |
| Family 2a: notify_all ordering | `MC_hunt_family2a.cfg` | `NoWaitersStuckAfterKillComplete` + temporal `NoLivelockAfterKill` | Three-step kill release split in base spec captures the ordering |
| Family 2b: registerChange fail | `MC_hunt_family2b.cfg` | `NoOrphanKillRequest` | `MaxKillChangeFailLimit = 1`; single session sufficient |
| Family 3: runningOp drop | `MC_hunt_family3.cfg` | `NoRunningOpDropped` | `MaxRefreshFailLimit = 3`; `refreshFailedWhileRunningOp` tracks drop |
| Family 4: two-phase reap | `MC_hunt_family4.cfg` | `NoDanglingImageWithoutTxnRecord`, `NoStaleCheckoutAfterMemoryReap` | `MaxRevivifyLimit = 2` enables checkout between reap phases |

**Coverage: 5/5 families have targeting hunt configs.** ✓

---

## §5 Invariants → Hunt Config Coverage

| Brief §5 Invariant | TLA+ Name | Enabled in ≥1 Hunt Config | Config |
|---|---|---|---|
| `TxnRecordSafeWhileLive` | `TxnRecordSafeWhileLive` | ✓ | `MC_hunt_family1.cfg` |
| `NoWaitersStuckAfterKillComplete` | `NoWaitersStuckAfterKillComplete` | ✓ | `MC_hunt_family2a.cfg` |
| `NoOrphanKillRequest` | `NoOrphanKillRequest` | ✓ | `MC_hunt_family2b.cfg` |
| `RunningOpSessionNotSilentlyDropped` | `NoRunningOpDropped` | ✓ | `MC_hunt_family3.cfg` |
| `NoDanglingImageWithoutTxnRecord` | `NoDanglingImageWithoutTxnRecord` | ✓ | `MC_hunt_family4.cfg` |

**Coverage: 5/5 brief §5 invariants are enabled in at least one hunt config.** ✓

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding ID | Description | Hunt Config | Fault Setup |
|---|---|---|---|
| MC-1 | `_reap` deletes txnRecord for session `_refresh` just upserted | `MC_hunt_family1.cfg` | Both workers enabled concurrently; `MaxTime=4` allows refresh within reap window |
| MC-2 | Normal checkout waiters stuck after kill release (notify before decrement) | `MC_hunt_family2a.cfg` | Three-step `KillReleaseClearCheckout` → `KillReleaseNotify` → `KillReleaseDecrement` split; `waiters > 0` reachable via `CheckoutSession` being blocked |
| MC-3 | `registerChange` throws → `killsRequested > 0` forever | `MC_hunt_family2b.cfg` | `MaxKillChangeFailLimit = 1`; `RegisterKillChangeFail` fires after `RequestKill` |
| MC-4 | runningOp session fails refresh, expires via TTL | `MC_hunt_family3.cfg` | `RefreshFail` with `sessionSource = "runningOp"` fires; `refreshFailedWhileRunningOp` set, not cleared |
| MC-5 | Checkout between memory-reap and disk-reap, no txnRecord found | `MC_hunt_family4.cfg` | `MCRevivifySession` fires after `MemoryReap` but before `DiskReapTxn` |

**Coverage: 5/5 §6.1 findings have a hunt config whose fault setup makes them reachable.** ✓

---

## Gaps and Honest Omissions

### Family 5: shouldRegisterKill stale-read (LOW priority)

**Not modeled.** The brief rates this LOW and classifies it as a code-review target rather than a TLA+ bug. The stale-read involves `lastClientTxnNumberStarted` which is only updated at checkin; modeling it would require adding the txnNumber dimension to the SRI state, significantly expanding the state space. The spec comments note this omission at the `RequestKill` / `RegisterKillChangeSucceed` split. No hunt config for Family 5.

### Dead code cluster (CR-2, CR-3)

**Not modeled.** `_isDead`, `_lastRefreshTime`, `staleSessions` are cleanup-only per the brief. No protocol impact, no TLA+ representation needed.

### TTL expiry as an explicit event

**Simplified.** The brief mentions TTL expiry for Family 3 (session expires if refresh consistently fails). The spec does not model an explicit `TTLExpire` action; instead, `refreshFailedWhileRunningOp` captures the necessary and sufficient condition (session dropped without retry). The TTL outcome is a consequence of the drop, not a separate protocol event. This simplification does not reduce bug-detection power for Family 3.

### Two refresh workers racing (same-type, SERVER-122193)

**Not modeled.** The brief notes that `_refreshMutex` was added to prevent two concurrent `_periodicRefresh` calls. Since the fix exists for same-type racing, adding a second `refreshRunning` worker would only reproduce an already-fixed bug (equivalent to `git revert SERVER-122193`). The unfixed cross-type race (refresh + reap) is what Family 1 models.

---

## MC.cfg Invariant Organization Verification

Checked by reading `MC.cfg` directly:

- Structural invariants (`TypeOK`, `AtMostOneCheckout`, `CheckoutImpliesInCatalog`, `KillCheckoutRequiresToken`, `KillReleasePhaseConsistency`, `DiskReapConsistency`) → **enabled** in `MC.cfg` (convergence validation)
- Extension invariants (`TxnRecordSafeWhileLive`, `NoWaitersStuckAfterKillComplete`, `NoOrphanKillRequest`, `NoDanglingImageWithoutTxnRecord`, `NoStaleCheckoutAfterMemoryReap`) → **commented out** in `MC.cfg` ✓
- All extension invariants enabled in exactly one hunt config ✓
