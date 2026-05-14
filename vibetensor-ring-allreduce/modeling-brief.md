# Modeling Brief — VibeTensor Ring AllReduce Collective

## 1. System Overview

- **Name**: `vbt_ring_allreduce` plugin of VibeTensor (NVIDIA Labs, 108k LoC total).
- **Scope modelled here**: the ring AllReduce collective only. ~4.3k LoC of device code under `ring_allreduce_plugin/94_blackwell_ring_allreduce/cutlass/experimental/distributed/collective/` plus ~1.25k LoC of host orchestration in `ring_allreduce_plugin/vbt_ring_allreduce/vbt_ring_allreduce_plugin.cu`.
- **Language**: CUDA/C++.
- **Category**: **A — Distributed / Message-Passing.** N ranks coordinate via per-rank atomic flag arrays accessed through CUDA P2P / UVA (system-scope atomics). Each rank is an independent process unit that publishes and polls flags; the protocol is a message-passing state machine modulo memory ordering, not a lock-free shared structure.
- **Algorithm**: Baidu 2017 Ring AllReduce (reduce-scatter → all-gather), SM100/SM103 specialization, with a two-phase ring-token **completion barrier** bolted on for status coherence.
- **Deviations from the reference paper**:
  - No global RS→AG barrier; each tile independently transitions RS→AG through per-tile flag chains.
  - Explicit **abort/error propagation** via `self_abort` (system atomic) + first-writer-wins `self_error` CAS.
  - Explicit **timeout** (`timeout_iters`, `timeout_cycles`) on every wait; a kTimeout publisher also sets abort.
  - **Ring-token barrier** (`ring_allreduce_barrier_sm100.cuh`) after drain to agree on a final status across ranks.
  - Host-assigned **epoch** tags every flag/token so stale values from prior runs are ignored (`epoch == 0` is reserved as "not this epoch").
  - Host **watchdog** (`wait_for_events`, CPU-side polling with deadline) layered above the device-side timeouts.
- **Concurrency model**: per-rank CUDA stream, one `ring_allreduce_sm100` kernel per rank launched on its stream. Inside the kernel: warp-specialized producer / consumer layout, CTA0-thread0 as sole barrier/drain/status writer. System-scope atomics are the cross-device communication channel.

---

## 2. Bug Families

### Family 1 — Status-coherence hole: CAS-first-writer-wins defeats precedence elevation

**Mechanism**: The barrier broadcasts a merged `final_status` using `merge_status` precedence (`kInvalidParams > kTimeout > kAbortObserved > kOk`), but every rank latches the broadcast via `ring_allreduce_publish_error_and_abort`, which uses a **CAS expecting `kOk`** (`drain.hpp:102–107`). If a rank has already written a lower-precedence code (e.g. `kAbortObserved` from hop propagation) before the barrier receives a higher-precedence broadcast (e.g. `kTimeout`), the CAS fails and the rank's `self_error` is NOT elevated. The final `out_status[rank]` written at `kernel_sm100:2544` reads back `self_error` — so ranks disagree.

**Evidence**:
- Code: `ring_allreduce_drain.hpp:102–110` (CAS from `kOk` only).
- Code: `ring_allreduce_barrier_sm100.cuh:330–332` (rank 0 post-barrier latch via `publish_error_and_abort`).
- Code: `ring_allreduce_barrier_sm100.cuh:400–402` (non-zero rank latch via `publish_error_and_abort`).
- Code: `ring_allreduce_kernel_sm100.cuh:2543–2545` (kernel final-status write reads `local_status`, not the broadcast).
- The sample `94_blackwell_ring_allreduce.cu:728–736` explicitly asserts "`status coherence violated: ranks returned different error codes under abort injection`" — the kernel's own test case already acknowledges this hazard class.

**Affected code paths**: `ring_allreduce_barrier_gather_release`, `publish_error_and_abort`, kernel epilogue at `kernel_sm100:2541–2544`.

**Suggested modeling approach**:
- Variables: per-rank `self_error[r]`, `self_abort[r]`, `barrier_final_status[r]`.
- Actions: `hop_observe_abort(r)` sets `self_abort[r]=1` (no error published); `drain_timeout(r)` publishes kTimeout via CAS; `barrier_publish_error_and_abort(r, broadcast)` CAS from kOk.
- Split the barrier "decide final status" from "latch final status locally" into two separate actions so the interleaving is visible to TLC.

**Priority**: **High**. It violates a contract the benchmark itself test-asserts; directly targets the `ExactlyOnceStatus` / cross-rank agreement property.

---

### Family 2 — Partial-reduce data visible through `ag_ready[0]` under concurrent abort

**Mechanism**: In the warp-specialized AG path, rank r publishes `self_ag_ready[0, tile] = epoch` unconditionally once its own RS finishes (`kernel_sm100:1619–1621`, `2223–2225`). If during RS another CTA on rank r observes `peer_abort[left] == 1` (hop propagation, `smem.hpp:144–153`) and sets `self_abort = 1`, the ag-publish warp may still publish step-0 ready for a chunk whose reduction is partial (because left neighbor aborted mid-RS and never delivered its contribution). Right neighbors then read partial data as if it were final.

**Mitigation currently relied on**: peers will also observe abort (hop propagation via `peer_abort[left]`) and discard output. The protocol treats "output payload under abort" as don't-care. But this is an undocumented contract.

**Evidence**:
- `kernel_sm100:615–617, 1619–1623, 2223–2225` — unconditional `store(epoch)` on AG step 0.
- `smem.hpp:144–153` — hop-propagation writes `self_abort=1` but does NOT roll back any data already computed.
- No comment anywhere states "peer_data is undefined under abort"; downstream callers (e.g. the plugin) read the output tensor back in-place — on an aborted run the caller must trust `status != kOk` and ignore data.

**Suggested modeling approach**:
- Variables: per-rank `data[r, chunk] ∈ {Final, Partial}`, `ag_ready[r, s, tile]`.
- Actions: `publish_ag_ready(r, 0, tile)` does not require `self_abort[r] == 0` — the published flag does not imply finalness.
- Invariant: `AgReady0ImpliesFinalOrAbort: ag_ready[r, 0, tile] = epoch ⇒ data[r, owned_chunk(r)] = Final ∨ self_abort[r] = 1`.

**Priority**: Medium. Safety is preserved only through the abort fence; TLA+ can verify the fence is tight.

---

### Family 3 — Asymmetric abort liveness in the release barrier

**Mechanism**: In Phase B (release) of the completion barrier, rank 0 disables its wait-timeout whenever `final_status == kOk` (`barrier_sm100.cuh:315`). Non-zero ranks arm their release-wait timeout only **after** observing abort (`barrier_sm100.cuh:345–348`). Abort observation is strictly **one-hop** (`left_abort` only, `barrier_sm100.cuh:498, 65`). If rank k hangs mid-release (e.g., kernel launch race, compiler bug) while its left neighbor k-1 never aborts and rank 0 expects a clean lap, all ranks between 0 and k deadlock with no timeout.

**Evidence**:
- `barrier_sm100.cuh:314–316, 336–367, 395–402`.
- The release wait loop at `barrier_sm100.cuh:342` uses relaxed reads and does **not** early-exit on abort; only arms timeouts (`abort_obs.observed()` side-effect only).

**Suggested modeling approach**:
- Actions: `rank_stuck(k)` (environmental; non-deterministic fault).
- Invariant (liveness): `Eventually(∀ r: out_status[r] is written)` under fair scheduling and finite-tolerance faults.
- Explicitly model the asymmetry: rank 0 unconditional-timeout-off when kOk vs non-zero rank timeout-only-if-abort-observed.

**Priority**: Medium. Liveness, not safety. Triggered only when the "trusted sequencer" rank 0 is hung.

---

### Family 4 — Host-side cross-device ordering between per-run resets and ring kernel launches

**Mechanism**: The plugin builds a cross-device "inputs ready" fence at `vbt_ring_allreduce_plugin.cu:888–942` after construct+reset+staging-copy. It then enqueues **another** round of `cudaMemsetAsync` resets to `self_abort / self_error / self_tiles_finished / barrier_*` on each rank's own stream (`plugin.cu:1010–1031`), which is **not** re-fenced across devices. The subsequent ring kernel on rank q can read `peer_abort[r]` before rank r's stream has executed the post-fence memset.

**Why it's benign today but formally broken**: the prior `reset_rank_atomics_init_kernel` already wrote the same zero values through the fence. The second memset is duplicative dead reset. Any future change (e.g., per-epoch non-zero reset) would break this silently.

**Additional concern**: `cudaMemsetAsync` over storage containing live `cuda::atomic<uint32_t>` objects is strictly undefined under ISO C++; it works only because libcu++'s atomic is layout-compatible with `uint32_t` and default-constructed to 0.

**Evidence**:
- `plugin.cu:888–942` — single fence point.
- `plugin.cu:1010–1031` — unfenced post-fence memsets on each rank's stream.
- `plugin.cu:763, 770` — `construct_rank_atomics_kernel` already default-initializes; `reset_rank_atomics_init_kernel` already writes 0 — both run before the fence.

**Suggested modeling approach**: code-review-only (not modellable in a protocol-level TLA+ spec without modelling the CUDA execution fence graph). Flag in the brief so the spec author does not try to model memset races as separate actions.

**Priority**: Low (latent). Fix recommended; not a TLA+ target.

---

### Family 5 — Watchdog timeout / launch failure leaks device state and can hang the system

**Mechanism**: On watchdog timeout (`plugin.cu:1067–1071`) or `cudaEventRecord` failure after a kernel launch (`plugin.cu:1057–1062`), the host returns **without** (a) signalling `self_abort` on any rank, (b) freeing `atomics` / `device_status` / `done_events`, or (c) synchronizing the streams. Kernels remain live on the GPU writing to buffers the host believes it has released conceptually; repeat invocations leak events and memory monotonically. Because the device-side `timeout_iters = 1<<18` (`plugin.cu:962`) is finite, kernels eventually self-terminate, but between fire and self-termination, any subsequent reuse of those buffers is a use-after-free hazard.

**Evidence**:
- `plugin.cu:1035, 1049–1052, 1057–1062, 1067–1071` — error paths intentionally skip cleanup with comment "kernels may still be running".
- `plugin.cu:637–656` — watchdog default 20s; not synchronized with device `timeout_iters`.

**Suggested modeling approach**:
- Host-level model: actions `host_watchdog_fire` (poisons `self_abort` on all ranks before returning), `host_free_resources` only after `cudaStreamSynchronize`.
- Invariant: `NoUseAfterFreeHost: ∀ call c: free(atomics[c]) happens-after every kernel on every rank has exited`.

**Priority**: Medium. Safety + resource-leak hybrid; the trigger requires a CUDA-level fault so the model is high-level.

---

### Family 6 — Epoch monotonicity / stale-flag freshness

**Mechanism**: Per-tile flags are *equal-to-epoch* checks; a reader in epoch E sees "ready" iff the flag's stored value equals E. Flags are NOT cleared between epochs; the host simply passes a new `epoch` each call. If epoch is ever reused (e.g., the plugin hardcodes `p.epoch = 1u` for every call at `plugin.cu:950`), a rank could observe stale flags from a previous run of the same allocation as "ready" for the current run.

**Why it's benign today**: the plugin freshly allocates atomics per call and destroys them at cleanup — no allocation is reused across calls. So the "epoch = 1" constant is effectively a per-allocation identity, not a per-run identity. But this contract is not enforced by the protocol; if the plugin ever switched to a pool to avoid repeat cudaMalloc cost, stale flags would immediately appear.

**Evidence**:
- `types.hpp:135` (implied, `epoch == 0` only reserved) and `barrier_sm100.cuh:463` (rejects epoch=0).
- `plugin.cu:950` — `p.epoch = 1u` literal.
- `kernel_sm100:246, 294; smem.hpp:138, 187` — equality-with-epoch freshness check.
- No code path clears the flag arrays; `reset_rank_atomics_init_kernel` does clear to 0 but only runs at allocation time.

**Suggested modeling approach**:
- Variable: `epoch_sequence`, per-run distinct epoch.
- Invariant: `FreshnessInvariant: wait_flag_at(r, s, tile) returns Ready ⇒ flag was written in the same epoch`.
- Additional environmental assumption: `epoch_is_strictly_unique_per_run`.

**Priority**: Medium. Latent. A good TLA+ target because it gates future reuse-of-buffers optimizations.

---

### Family 7 — Drain counter is not abort-responsive

**Mechanism**: `ring_allreduce_drain_tiles_finished` (`drain.hpp:167–219`) polls `self_tiles_finished` for exact equality with `expected_tiles`, checking timeouts each iteration but **not** early-exiting on `self_abort == 1`. If a producer CTA publishes abort mid-progress and never signals its own tile (e.g., warp 6 publishes kInvalidParams via the any-thread path at `drain.hpp:119–141` and exits its tile without the CTA reaching signal), `done` never reaches `expected_tiles` and the drainer waits the full timeout.

**Evidence**:
- `drain.hpp:188–217` — exit conditions are (i) `done == expected_tiles`, (ii) `timed_out_iters`, (iii) `timed_out_cycles`. `self_abort` is loaded but not branched on (`drain.hpp:194–195`).
- Contrast with `wait_flag_warp` (`smem.hpp:144–153`) which **is** abort-responsive.

**Suggested modeling approach**:
- Actions: `producer_abort_and_skip_signal(r, tile)` leaves `tiles_finished[r]` short; `drain_spin(r)` polls; `drain_timeout(r)` fires.
- Invariant: `DrainTerminates: timeout_iters > 0 ⇒ eventually drain exits within O(timeout_iters)`.
- Check: under mixed abort+timeout injection, does `out_status` still get written by every rank?

**Priority**: Medium. A liveness degradation; model-checkable with bounded timeouts.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

1. **Per-rank RS→AG per-tile state machine**: phases `RS_publish(r, s, tile)` → `AG_publish(r, s, tile)` gated by `wait_flag` on `peer_ag_ready[left]` / `peer_rs_ready[left]`. Target Families 1, 2, 6.
2. **System-atomic flag store with release + epoch-tagged value + acquire-confirm read**. Encode the relaxed+acquire re-read pattern from `kernel_sm100:246, 294`. Target Family 6.
3. **`self_error` + `self_abort` scalars with CAS-from-kOk semantics.** Model `publish_error_and_abort(r, err)` as first-writer-wins. Target Family 1 explicitly.
4. **Two-phase ring-token barrier** (`gather` + `release`) with rank-0 asymmetry and `final_status` broadcast. Target Families 1, 3.
5. **Drain counter** as `tiles_finished[r] ∈ 0..num_tiles_total`, polled by CTA0 with timeouts but NOT abort-responsive. Target Family 7.
6. **Debug abort hooks** (`debug_abort_before_ag_publish`, `debug_abort_after_ag_publish`, `debug_release_delay_rank`) should be exposed as TLC constants: they already encode the protocol's failure scenarios.
7. **Host watchdog** as an abstract "kill switch" that sets `self_abort` on all ranks after a bounded wait — target Family 5 at a high level.

### 3.2 Do Not Model (with rationale)

1. **CUTLASS shared-memory ping-pong staging** (`ring_allreduce_smem.hpp`, wait_flag_warp internals, `__syncwarp` / `__shfl_sync`). Kernel-internal concurrency; TLA+ would over-approximate without adding useful coverage. Code-review target.
2. **CUDA event / stream graph** (`plugin.cu` fence logic). Family 4 is a CUDA API ordering issue; not a protocol bug. Code-review target.
3. **`validate_ring_p2p_caps_and_enable_peer_access`** and all host P2P validation. These are environmental preconditions; the spec should **assume** P2P + native atomics hold.
4. **Compute-capability check (SM103 requirement)**, tiling math (`ring_allreduce_tiling.hpp`), numeric overflow checks. Pure host-side arithmetic; unit-test target.
5. **Placement-new / destructor / memset of `cuda::atomic<>` storage** (`plugin.cu:153–279, 1014–1030`). ISO-C++ UB concern; not a protocol bug.
6. **Reduction correctness (numerical)**. The TLA+ model should abstract "reduced chunk" as opaque symbols (InitVal, SumOf{r}); do not try to model float arithmetic.

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Per-tile ready flags | `rs_ready[r, s, tile]`, `ag_ready[r, s, tile]` ∈ `{0, epoch}` | Models system-atomic flag chain | 2, 6 |
| Epoch tagging | `epoch[r]` (set to a per-run constant) | Detects stale-flag acceptance | 6 |
| Per-rank error/abort scalars | `self_error[r]`, `self_abort[r]` | Models CAS-first-writer-wins and hop propagation | 1 |
| Barrier tokens | `barrier_gather_token[r]`, `barrier_gather_status[r]`, `barrier_release_token[r]`, `barrier_release_status[r]` | Models the two-phase ring-token barrier | 1, 3 |
| Drain counter | `tiles_finished[r]` | Models drain termination & timeout interaction | 7 |
| Debug injection vars | `inject_abort[r, ag_step, when]`, `inject_release_delay[r]` | Parameterizes bug scenarios | 1, 2, 3 |
| Host watchdog | `host_done`, `host_watchdog_fired` | Models host-level timeout interaction | 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `AgreementOnKOk` | Safety | If any rank writes `out_status[r] = kOk`, every rank writes `out_status = kOk`. | Family 1 |
| `StatusCoherence` | Safety | Under any fault injection, `∀ r1, r2 ∈ ranks: out_status[r1] = out_status[r2]`. | Family 1 (expected to fail; spec should *find* the counter-example) |
| `StatusElevation` | Safety (conditional) | If the barrier's final_status is `E`, every rank latches `self_error ⊒_precedence E`. | Family 1 (expected to fail) |
| `AgReady0ImpliesFinalOrAbort` | Safety | `ag_ready[r, 0, tile] = epoch ⇒ data[r, owned_chunk(r)] = Final ∨ self_abort[r] = 1`. | Family 2 |
| `OwnedChunkFinalOnKOk` | Safety | On the all-kOk terminal, `data[r, owned_chunk(r)] = Σ_{r'} initial_input[r', owned_chunk(r)]` for every r. | Baseline correctness |
| `PerTileMonotonicity` | Safety | Each `rs_ready[r,s,tile]` / `ag_ready[r,s,tile]` transitions at most once per epoch (0 → epoch). | Family 6 |
| `FreshnessInvariant` | Safety | Any flag observed `= epoch` was written in the same epoch. | Family 6 |
| `DrainTerminates` | Liveness | With `timeout_iters > 0`, every rank exits `ring_allreduce_drain_tiles_finished` within O(timeout_iters). | Family 7 |
| `BarrierTerminates` | Liveness | With `timeout_iters > 0` and finite faults, every rank exits `ring_allreduce_barrier_gather_release`. | Family 3 |
| `AbortPropagation` | Safety | `self_abort[r1] = 1 ⇒ eventually ∀ r2: self_abort[r2] = 1` (assuming peer links healthy). | Family 3 |
| `NoHostUAF` | Safety | Host does not free per-call atomics until every rank's kernel has exited. | Family 5 |
| `WatchdogPoisons` | Safety | Host watchdog fire ⇒ host sets `self_abort[r] = 1` on every rank before returning. | Family 5 (proposed strengthening) |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| F1-A | CAS-gated latch of barrier final_status lets ranks diverge under mixed abort+timeout | `StatusCoherence` | 1 |
| F1-B | Rank r latches `kAbortObserved` before barrier; barrier broadcasts `kTimeout`; rank r keeps `kAbortObserved` | `StatusElevation` | 1 |
| F2 | AG step-0 flag published despite concurrent abort; peer reads partial data | `AgReady0ImpliesFinalOrAbort` (intended tight) | 2 |
| F3 | Rank 0 release wait with timeouts_off + mid-ring hang → deadlock | `BarrierTerminates` under finite faults | 3 |
| F6 | Epoch-equality flag check sees stale flag from a reused allocation | `FreshnessInvariant` (if allocation pool is modelled) | 6 |
| F7 | Drain spins full `timeout_iters` despite self_abort set, because drain does not early-exit on abort | `DrainTerminates in O(hop_propagation)` (tight) vs `O(timeout_iters)` | 7 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|--------------------------|
| T1 | `tile_elems > 256` (kStageElemsMax) overflows smem staging | Fuzz `tile_elems` in the host validator against known smem budget |
| T2 | `find_ring_perm` degenerates to exponential on large N | Benchmark with artificially-sparse `ok[][]` matrix |
| T3 | Watchdog env var `VBT_RING_ALLREDUCE_WATCHDOG_MS` parsing rejects malformed input | Integration test over corner strings (empty, space, negative, overflow) |
| T4 | Repeated invocation with watchdog firings leaks `cudaEvent` handles | Soak test: run N times with forced watchdog, assert event-pool count bounded |
| T5 | Benchmark's status-coherence assert (94_blackwell_ring_allreduce.cu:728–736) actually catches the F1 scenarios | Add mixed abort+timeout injection to the existing test harness |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| C1 | `cudaMemsetAsync` over `cuda::atomic<>` storage (plugin.cu:1014–1030) is redundant and technically UB | Remove the second-pass memsets; rely on `reset_rank_atomics_init_kernel` |
| C2 | `ready_events` destroyed immediately after `cudaStreamWaitEvent` — relies on CUDA refcount semantics (plugin.cu:934–942) | Add explicit comment citing CUDA runtime contract |
| C3 | Alloc-failure cleanup path frees atomics without synchronizing streams that already launched construct/reset kernels (plugin.cu:778–797) | Add `cudaStreamSynchronize` per rank before `cudaFree` |
| C4 | Watchdog timeout + event-record-failure paths skip cleanup; leak cudaEvents and device memory (plugin.cu:1049–1071) | Add abort-signal-all-ranks then bounded-wait-then-cleanup |
| C5 | Epoch literal `1u` (plugin.cu:950) couples freshness to per-call allocation freshness — brittle for future pooling | Use a per-call counter + reset flags if pooled |
| C6 | `ring_allreduce_signal_tile_finished` return is lossy for non-thread0 callers (drain.hpp:80–89) | Mark function with a caller-contract comment or remove the return type |
| C7 | `any-thread publish_error_and_abort` (drain.hpp:119–141) and thread0 variant share first-writer-wins semantics; warp6-lane0 allowlist is a by-convention lock | Document the allowlist invariant as a `static_assert` if possible |
| C8 | Release wait's `timeouts_enabled = (final_status != kOk)` on rank 0 relies on "no-fault post-gather" (barrier_sm100.cuh:315) | Consider an absolute cap even on kOk, at the cost of a rare false-timeout |

---

## 7. Reference Pointers

- Full analysis report: `./analysis-report.md` (same directory as this brief).
- Core source files:
  - Host plugin: `ring_allreduce_plugin/vbt_ring_allreduce/vbt_ring_allreduce_plugin.cu:1–1249`
  - Benchmark / demo: `ring_allreduce_plugin/94_blackwell_ring_allreduce/94_blackwell_ring_allreduce.cu:1–806`
  - Protocol kernel: `ring_allreduce_plugin/94_blackwell_ring_allreduce/cutlass/experimental/distributed/collective/ring_allreduce_kernel_sm100.cuh:1–2549`
  - Barrier: `.../ring_allreduce_barrier_sm100.cuh:1–528`
  - Drain: `.../ring_allreduce_drain.hpp:1–253`
  - Types: `.../ring_allreduce_types.hpp:1–199`
  - Tiling: `.../ring_allreduce_tiling.hpp:1–178`
  - Smem staging: `.../ring_allreduce_smem.hpp:1–219`
  - Host validation: `.../ring_allreduce_host.hpp:1–383`
- GitHub: https://github.com/NVlabs/vibetensor (1 commit total in history, 0 issues, 2 unrelated PRs — no useful archaeology).
- Reference algorithm: Baidu 2017 Ring AllReduce; NCCL implementation is the industry cousin.

---

## 8. Category Carry-Forward

- **Category A (Distributed / Message-Passing).** Use `distributed-analysis.md` and `distributed-trace-validation.md` downstream.
- Rationale: the protocol is N per-rank state machines communicating through release/acquire atomics over P2P. The kernel's intra-rank warp-level concurrency is a modeling abstraction target (collapse to atomic actions), not a Category B lock-free structure in its own right. Protocol bugs dominate; lock-free bugs are out-of-scope.
