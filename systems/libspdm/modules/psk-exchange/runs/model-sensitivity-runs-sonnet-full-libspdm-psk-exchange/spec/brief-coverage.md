# Brief Coverage Self-Audit

Phase 2.5 self-check: maps brief §2 / §5 / §6.1 → spec/MC artifacts.
Filled by reading actual cfg files, not from memory.

---

## §2 Bug Families → Hunt Configs

| Family | Priority | Hunt config              | Invariant enabled | Status  |
|--------|----------|--------------------------|-------------------|---------|
| Family 1: zero-version session (opaque_length=0) | High | `MC_hunt_family1.cfg` | `ValidVersionOnEstablish` | ✓ Covered |
| Family 2: triple-call version mismatch | Medium | `MC_hunt_family2.cfg` | `VersionAgreement` | ✓ Covered |
| Family 3: wrong command code in MAC_CAP error | Low | — | — | Out of scope (copy-paste defect, no state-machine impact; brief §3.2 explicitly excludes) |
| Family 4: asymmetric opaque bounds check | Low | — | — | Out of scope (hardening gap, not a reachable invariant violation; brief §3.2 excludes) |

---

## §5 Proposed Invariants → Spec + Config

| Invariant | Defined in spec | Enabled in MC.cfg | Enabled in hunt cfg |
|-----------|-----------------|-------------------|---------------------|
| `ValidVersionOnEstablish` | `base.tla` ✓ | Commented out (convergence) | `MC_hunt_family1.cfg` ✓ |
| `VersionAgreement` | `base.tla` ✓ | Commented out (convergence) | `MC_hunt_family2.cfg` ✓ |
| `NoEstablishWithoutHmacVerify` | `base.tla` ✓ | `MC.cfg` ✓ | Both hunt cfgs ✓ |
| `PskFinishRequiredIfContext` | `base.tla` ✓ | `MC.cfg` ✓ | Not in hunt cfgs (psk_cap init is PSK_CAP_REQUESTER_ONLY in hunt cfgs — irrelevant) |

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding | Hunt config | Fault setup | Reachable? |
|---------|-------------|-------------|------------|
| MC1: PSK session ESTABLISHED with version=0 when opaque_length=0 in SPDM 1.2+ | `MC_hunt_family1.cfg` | `MaxSendLimit=1` (allows one no-opaque send), `MaxDropLimit=0`, `PSK_CAP_REQUESTER_ONLY` → immediate ESTABLISHED path | ✓ Reachable |
| MC2: Requester and responder assign different versions due to nondeterministic callback | `MC_hunt_family2.cfg` | `MaxSendLimit=0` (only with-opaque sends), nondeterministic `CHOOSE` in `GetResponsePskExchange` picks different versions for call 2 vs call 3 | ✓ Reachable |

---

## Known Gaps / Honest Notes

1. **`PskFinishRequiredIfContext` not in hunt cfgs**: The hunt configs use `PSK_CAP_REQUESTER_ONLY` (the shorter path to ESTABLISHED) to reduce state space for the targeted families. This invariant is still checked in `MC.cfg` during convergence runs.

2. **Family 2 nondeterminism**: `GetResponsePskExchange` in `base.tla` uses `CHOOSE` for the triple-call version selection. `CHOOSE` in TLA+ is deterministic per model (picks an arbitrary fixed element). For TLC to actually explore divergence between call-2 and call-3 versions, the spec uses separate `CHOOSE` expressions for `ver_call2` and `ver_call3`, which TLC will enumerate over all combinations. This is correct TLC behavior.

3. **`FinalOpaqueWrite` silent action**: The optional Family 2 instrumentation point (`FinalOpaqueWrite`) described in `instrumentation-spec.md` does not yet have a corresponding wrapper in `Trace.tla`. It is handled as a silent action. If harness generation adds this event, `Trace.tla` should be updated to consume it explicitly.

4. **Single-session scope**: The spec models exactly one session (session_id=1). Multi-session interaction (e.g., session ID collision) is explicitly out of scope per modeling brief §3.2.
