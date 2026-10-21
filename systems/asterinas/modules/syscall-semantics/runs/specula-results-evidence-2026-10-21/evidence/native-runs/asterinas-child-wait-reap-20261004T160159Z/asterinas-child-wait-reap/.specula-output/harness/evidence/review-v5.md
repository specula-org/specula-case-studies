VERDICT: NOT_APPROVED

**C1 — Medium — The generated QMP socket paths prevent guest startup.**

Evidence: [run.sh:13](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/run.sh:13) adds a UUID to the attempt directory. Lines 149 and 161 place guest logs there. [boot.py:22–25](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/boot.py:22) derives the QMP socket pathname from that log path.

Even with PID `1`, the shortest case produces this **110-byte** pathname:

```text
/work/.specula-output/harness/evidence/20261006T000000Z-1-00000000000000000000000000000000/guest-nohang-37.qmp
```

All 15 cases exceed Linux’s 108-byte `sockaddr_un.sun_path` capacity. QEMU rejects oversized Unix socket paths, so guest execution cannot reach trace collection. This defect was introduced in v4 and remains in v5. This is a static finding, not an observed QEMU run. [QEMU socket validation](https://raw.githubusercontent.com/qemu/qemu/master/util/qemu-sockets.c)

Minimal fix: keep the evidence paths, but use a short container-local QMP pathname such as `/tmp/wr-<uuid>.qmp`. Preserve command recording and cleanup. Review the corrected hashes before execution.

No other High or Medium findings were identified.

**Disposition of R2 under the weaker claim**

R2 remains **OPEN** for real global order, store visibility, and a run-wide clock bound. The reviewed encoding supports exactly `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`. I found no clock-method blocker to that narrower claim. Candidate execution remains blocked by C1.

The following checks support that disposition:

- **Stamps and synchronization:** [wr_trace.rs:63–76](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/wr_trace.rs:63) and [wait_reap_trace.c:54–61](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/wait_reap_trace.c:54) contain `lfence; rdtsc; lfence`. Rust omits `nomem`, `readonly`, and `pure`. C uses volatile assembly with a `memory` clobber. No new MFENCE, CPUID, locked RMW, or remote acknowledgement enters a measured kernel bridge. CPUID and calibration exchanges occur outside those bridges. LFENCE’s local execution ordering does not guarantee prior-store visibility. [Intel SDM, §8.2.5](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf)

- **Calibration and encoding:** [collect.py:137–195](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/collect.py:137) derives `B` from that invocation’s pre/post samples. Neither Linux-control measurements nor model results supply it. Across CPUs, `end + 2B < start` can only remove raw precedence edges because `B ≥ 0`. Same-CPU comparisons remain unchanged. The endpoint constraints, strict-cycle refusal, and complete pairwise audit at [collect.py:255–355](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/collect.py:255) preserve precisely that relation and local non-overlap. Integer ranks satisfy the unchanged `TraceShapeOK`; equality creates no precedence under `Trace.tla:143–146`.

- **Claim and interpretation:** Grouped output and sidecars carry the fixed consistency claim, unestablished visibility/clock fields, and `NOT_RUN` validation. The documentation explicitly retains unseen offset excursions, store visibility, discarded clock-error correlations, and instrumentation effects. Only a complete `TraceNoCompleteMatch` witness with the preceding invariants intact qualifies. It cannot justify actual-global-order validation, physical-overlap coverage, or weak-memory correctness.

- **Refusals and approval:** The v4 calibration function is AST-identical. Its measurement refusals and the decoding/completeness refusals remain on the shared path. [review_gate.py:8–33](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/review_gate.py:8) requires `APPROVED`, candidate `v5`, matching live/frozen hashes, and the consistency scope for grouped output. Grouped collection additionally requires explicit opt-in. Diagnostics remain available and `INELIGIBLE`. Linux controls cannot emit grouped kernel traces.

- **Runner controls:** The review gate precedes source application and execution. The 10 GiB admission occurs before execution and again immediately before kernel build. The pinned image ID associated with `asterinas/dev:0.18.1-20260926`, `--pull=never`, required container prefix, Linux controls/calibration, `-smp 2`, recorded guest CPU count, and count cross-checks are present. The runner records locks without reacquiring `heavy.lock`. C1 prevents the prepared guest path from operating.

- **Preservation:** `spec/`, `modeling-brief.md`, hooks, instrumentation patch, `cases.tsv`, and expected-outcome logic remain unchanged from v3. All six decoder helpers, including the 41-event mapping, are AST-identical to v3. Recorder/fixture differences concern the clock method, calibration, affinity checks, and provenance. All 20 installed-source hashes match the historical v3 receipt. Execution therefore still requires controller installation of the reviewed candidate and rebinding of its installed receipt.

A hand-constructed adversarial example demonstrates the refusal boundary. Let `B = 10`:

| Actor | CPU | Event | Raw interval |
|---|---|---|---|
| w1 | A | a1 | `[110,111]` |
| w1 | A | a2 | `[112,113]` |
| w2 | B | b | `[100,101]` |
| child | B | c | `[120,121]` |

The same-CPU relation retains `b < c`. Widening removes both `a1 < c` and `b < a2`. Preserving those absent edges together with w1’s local order requires:

```text
S_c ≤ E_a1 ≤ S_a2 ≤ E_b < S_c
```

That is impossible. The code’s strict-cycle check therefore refuses with `UNREPRESENTABLE_LOCAL_ORDER`, without emitting a grouped trace or claiming a model mismatch.

At the equality boundary, `B = 5`, `e.end = 20`, and another CPU’s `f.start = 30` yield `20 + 2×5 == 30`. The encoder correctly retains no `e < f` edge.

All 23 supplied hashes matched before review and again afterward. Python syntax and Bash syntax checks passed. The workspace remains clean. No files were edited, and no harness execution, Docker, build, QEMU, or TLC run occurred.

## REVIEWED INPUTS

Paths are relative to `harness/`.

```text
6328a279f03d7d085fcc598573f763c7cf8438232db9385f401aca7bcd417511  src/boot.py
f47ea876227669dd3ded951d661a1716b9c8b75b2cc2abfc25575dbd20e7d283  src/collect.py
a89ecd347eadb36b2a25c16d8cd96dd3c04964bd50c6bd0ff570d4e186c72561  src/initramfs.py
3cdd3187ca71d4f3705063e010ebea20995d30947f08f84ef8544128a4e21ef7  src/instrument.py
124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb  src/Makefile
2d23fd66b008a1f41938dd4fee0348397af01949133b7c7af30581399c9dae9e  src/review_gate.py
e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3  src/wait_calibration.c
c321494aed02c1bfb89d676b7c2c1ed5f1ecd9c9923400be76f43a929d232e12  src/wait_reap_trace.c
aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b  src/wr_syscall.rs
ec9aed3f6b032b626f86ff8a97636ecaa37e6f3fa037662264889cd445232219  src/wr_trace.rs
a31c69536a7b5ba8bdac945c773b98cbf830a7fb493600934659612d083ef8f8  run.sh
88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448  apply.sh
3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044  clean.sh
eba30152db35a608f521984474ad0ad7bab0ef67e7785b7259b50a116003efbc  cases.tsv
10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb  patches/instrumentation.patch
1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d  evidence/applied.json
3e5e8f0fcd7de09c4bc0a72ed026d597b3c7cdcfda890f48433132820c4e7e06  INSTRUMENTATION.md
252e97d05d2216ef6714f2679169e00a8c56df7d5d5d16bac1007bf67528c752  evidence/clock-method-v5.md
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

These four additional inputs required by the receipt checker were also reviewed and verified:

```text
88f6b43c9d8d7b4350af1a268ccf1f89ee43e18d19f60e1f584dc88efd45b4a3  STATUS.md
fcaca87d2aa3f748f9e0dff21faa9b1ee242f1d9cd4170be48e8f8e03130134d  evidence/clock-method-v4.md
49f6a47ce73dbb6e11f6ecdc3ecde6b5640d29eb097840ab3fb9fa103b8bea2b  evidence/v5-inputs.json
c418fe14f65633c8802b61d2d734b4182d79e168fbab645a561b36089e6f3817  evidence/candidate-v5/hashes.json
```

