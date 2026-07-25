# Brief Coverage Self-Audit

Mapping of modeling-brief.md §2 / §5 / §6.1 → spec and MC artifacts.

---

## §2 Bug Families → Hunt Configs

| Family | Priority | Hunt config | Spec actions that make it reachable |
|---|---|---|---|
| F1: Version × Cap × Algo Coherence | HIGH | `MC_hunt_family1.cfg` | `RspHandleNegotiateAlgorithms` (MEL_CAP/MEAS_CAP conditional, lines 718–731) |
| F2: Capability Compatibility Asymmetry | HIGH | `MC_hunt_family2.cfg` | `RspHandleGetCapabilities` (models actual buggy code: PSK_CAP==3 check absent, KEY_EX/no-cert check absent) |
| F3: Struct Table Mirroring | HIGH | `MC_hunt_family3.cfg` | `RspHandleNegotiateAlgorithms` (struct_alg_types = req_types constraint) |
| F4: Transcript Integrity on Error Paths | MEDIUM | `MC_hunt_family4.cfg` | `RspErrorInCapabilities`, `RspErrorInAlgorithms` |
| F5: Version-Gated Error Response Encoding | LOW | **Not modelled** — per brief §3.2, not a TLA+ target (formatting issue, not protocol safety) |

All HIGH families have a dedicated hunt config. F5 is explicitly out of scope.

---

## §5 Invariants → Hunt Config Enablement

| Invariant | Defined in | Enabled in |
|---|---|---|
| `NegotiatedCoherence` | `base.tla` | `MC_hunt_family1.cfg` ✓ |
| `VersionAlgoScope` | `base.tla` | `MC_hunt_family1.cfg` ✓ |
| `CapabilityCompatibility` | `base.tla` | `MC_hunt_family2.cfg` ✓ |
| `AlgTableMirroring` | `base.tla` | `MC_hunt_family3.cfg` ✓, `Trace.cfg` ✓ |
| `TranscriptCoherence` | `base.tla` | `MC_hunt_family4.cfg` ✓ |
| `TypeOK` | `base.tla` | All configs ✓ |

All §5 safety invariants are enabled in at least one hunt config.

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding | Config | How it becomes reachable |
|---|---|---|
| MC1: MEL_CAP=1, MEAS_CAP=0 → mspec≠0 but mhash=0 | `MC_hunt_family1.cfg` | `RspHandleNegotiateAlgorithms` allows `mspec=ALGO_SOME` when MEL_CAP∈rsp_cap_flags but keeps `mhash=ALGO_NONE` when MEAS_CAP∉rsp_cap_flags. `NegotiatedCoherence` checks `measurement_hash_algo = ALGO_SOME ⟺ HasMeasCap(rsp_cap_flags)`. TLC explores rsp_cap_flags containing MEL_CAP but not MEAS_CAP. |
| MC2: PSK_CAP==3 reaches AFTER_CAPS through responder validator | `MC_hunt_family2.cfg` | `RspHandleGetCapabilities` explicitly does NOT block `ReqPskCapBothBits(req_flags)` (modelling the actual code). `CapabilityCompatibility` does not directly check PSK_CAP==3 (that is a req-side structural constraint; the asymmetry is captured by the fact that the spec allows both sides to reach AFTER_CAPS via different validation paths). To expose the exact MC2 scenario, `CapabilityCompatibility` must be extended with: `~ReqPskCapBothBits(req_cap_flags)` as a post-AFTER_CAPS condition — this is a known gap; see note below. |
| MC3: rsp_alg_types ≠ req_alg_types at NEGOTIATED | `MC_hunt_family3.cfg` | `RspHandleNegotiateAlgorithms` enforces `struct_alg_types = req_types`. If this constraint were absent (or weakened by a future spec edit), `AlgTableMirroring` would fire. The current spec faithfully models the fixed code — the config confirms no violation exists after the fix. |
| MC4: req_appended=TRUE, rsp_appended=FALSE in stable state | `MC_hunt_family4.cfg` | `RspErrorInCapabilities` / `RspErrorInAlgorithms` set req_appended=TRUE without setting rsp_appended=TRUE, then clear in_flight_msg. `TranscriptCoherence` requires `in_flight_msg="none" ⟹ ∀ phase: req_appended[phase] ⟹ rsp_appended[phase]`. Violation is directly reachable on the first RspError firing. |

### MC2 gap note

`CapabilityCompatibility` does not currently encode `~ReqPskCapBothBits(req_cap_flags)` as a post-condition, because the spec models the **responder's** acceptance decision and the responder's code rejects PSK_CAP==3 (so the invariant would never be violated for MC2 in the base spec as written). The actual MC2 asymmetry is: the **requester's outgoing validator** would allow PSK_CAP==3 in its local flags, but the responder's check rejects it — meaning a requester that sets PSK_CAP==3 will get a rejection where the spec says acceptance is legal. To fully capture this, the harness should test TV1 (sending GET_CAPABILITIES with both PSK_CAP bits set to a real responder) rather than TLC. This is consistent with the brief's §6.2 (TV1 is listed as a test-verifiable finding, not a model-checking finding for the responder path).

---

## Coverage Gaps

| Gap | Reason | Mitigation |
|---|---|---|
| F5 error encoding | Not a TLA+ target per brief §3.2 | Code review (CR* items in brief §6.3) |
| PSK_CAP==3 requester-outgoing path | MC2 partially covered; TV1 test needed for full confirmation | Brief §6.2 TV1 test case |
| OOB read TV2 (libspdm_req_get_capabilities.c:357-363) | Buffer size / pointer arithmetic — not expressible in this abstract TLA+ spec | Fuzz test per brief §6.2 TV2 |
| Copy-paste ASSERT CR3 | Implementation typo (wrong field in ASSERT) | One-line code review per brief §6.3 CR3 |
