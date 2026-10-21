# Independent corrective review of flock harness v2

Verdict: **NEEDS_IMPROVEMENT**. R1-R3 are closed in this exact source revision, but the remaining R4 race can silently omit a real reference decrement. No dependent kernel/guest/TLC verification is approved by this review.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T13:18:17.270346+00:00.

The reviewed immutable input is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v2/inputs`, with `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v2/sha256.json`, `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v2/revision.diff`, and `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v2/reason.md`. All listed snapshot hashes were read and compared with that manifest. The baseline source remains `0c60537098f4c2949ad2d382aaf499de72263d76`. The reviewer made no production-source or harness changes, executed no build, guest, control, test, TLC or trace replay, and acquired no locks. Author-reported OSDK bootstrap is outside this verdict.

## Prior finding dispositions

| Finding | Disposition | Source basis |
|---|---|---|
| R1, release timeboxes exclude real unlock | CLOSED by static review | The close wrapper evaluates `trace_unlock_start` before the lexical table guard drops. The scheduler records its release start before actual dequeue or the abort return, and emits after the existing runqueue guard drops. |
| R2, post-free address remains a primitive-hook match | CLOSED for the reported address-reuse path | `Owner.active` excludes retired entries from address lookup, and observed payload cleanup retires that active match while keeping scalar address history. R4 below identifies a separate race caused by consulting this registry only after a primitive has run. |
| R3, C08 accepts a stale park marker | CLOSED by static review | Boundary publication includes the event index. C08 requires a park index greater than the worker event count captured before releasing the first blocker. Ordinary resume/wait events cannot satisfy that fresh-park check. Actual second-blocker identity must still be inspected in runtime traces. |

The borrowed lookup now caches its corrected reference packet before the later no-put event. Raw OFD/task mappings have a read-only export. C07-notify gates the real waiter after its failed notification-consumption swap and before its park recheck, so it can exercise a retained notification without adding a reference or moving a production lock boundary.

## R4. Retirement can suppress a nonfinal put whose atomic decrement already ran

The exact source is `src/patch_alloc.py:26-30` and `src/flock_trace.rs:221-252`. The alloc hook calls `__specula_arc_observe` only after the production `fetch_sub`. At callback entry, the observer resolves the owner with the currently active address registry and returns immediately when that lookup yields zero.

A supported execution has two strong references: one descriptor and one in-flight syscall reference. Thread A performs the real nonfinal decrement from two to one and is preempted before its observer executes. Thread B drops the remaining reference, records the last decrement, runs the real destructor to completion, and retires the active OFD address. Thread A then resumes its observer. The active lookup returns zero, so A's valid decrement event disappears without incrementing the dropped-event counter. Reference accounting and the recorded local continuation can no longer replay the actual execution. The same pattern is possible for an open-local reference after insertion.

The current C10/C11 controls constrain much of this window by waiting for specific puts before releasing the other task, but that does not make the primitive hook correct for the supported concurrent final-release protocol. This is a static reachable ordering, not an observed guest failure.

Disposition: **OPEN**. Resolve a stable scalar OFD token before each real Arc/Weak primitive and pass that token together with its actual atomic result to the observer. Keep the active-address retirement so unrelated later allocations cannot match the old OFD. Do not clone the owner, defer the put, or accept the old address unconditionally after retirement. Preserve v2, record the next diff/reason, obtain an exact-version independent review, and then run the affected verification.

## Additional reviewed boundaries

The new collector preserves per-thread event order, writes raw per-thread NDJSON, keeps the original timestamp set, and applies one monotone compression map across all streams. It does not replay the model to manufacture state. It rejects missing final exports, fixture failures, nonzero dropped counts, and event-count mismatches. Completed traces and deliberate C06/C11 prefixes retain their separate completion status.

The checker compares observed event names with the Trace dispatcher and leaves missing event or overlap coverage incomplete. It retains exact post-state checks and does not relax the supplied 20 percent timebox quality condition. No coverage or overlap has been measured by this reviewer.

The runner now invokes bounded C01-C05 Linux controls on a tmpfs mount, checks host memory before TLC, and requires a reviewed hash marker before its kernel/guest path. The controller must include every load-bearing semantic input in that marker, including the unchanged Trace/model/configuration files and the validation adapter. The v2 snapshot still does not copy/hash `spec/generation-checks/validate_trace.py` with attempt inputs. The author has stated that v3 will bind this adapter and record actual image/command-line evidence. These are required evidence closeout items before a passing phase result.

No definite kernel compile/API mismatch was found in the inspected calls. `Task::current`, `irq::disable_local`, `cpu::num_cpus`, `CString::to_bytes`, `Error::with_message`, the syscall return conversion, and `CurrentUserSpace`'s `VmIo::write_bytes` have matching source interfaces. This is source inspection, not successful compilation. The recorded container environment already supplies `VDSO_LIBRARY_DIR=/root/linux_vdso`; its actual input hash still belongs with the build evidence.

The module remains a bounded fixture implementation. Its unique task registrations, one inode, valid descriptors with the documented normalization, finite queue/list sizes, signal exclusion, and controlled prefix endpoints are assumptions. Build, actual SMP/clock comparability, dropped-buffer absence, Linux outcomes, trace coverage and successful replay all remain NOT_RUN within this review.

## Exact reviewed hashes

Paths below are relative to `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v2/inputs`.

| File | SHA-256 |
|---|---|
| `apply.sh` | `43cd880d879a363e19e68345b0aef97bfde05042345a946e6434d069ae8621eb` |
| `clean.sh` | `241a1c260c373dd47b78cd90e90e3d2933232e44f0d9c9f6c5c6a138de3f3ce1` |
| `patches/instrumentation.patch` | `ed1ef53f17049df6b47e703f04c325c48661eaf627ca8a2f3d00772c5d4211f3` |
| `run.sh` | `90950c18a78eb6a145808f1b321425ae6075a2ecf1288829690a33ef2de09aaf` |
| `src/build.sh` | `3c2b1411f6cb899c73ece1433b9ee5020ba44567597e001994e0170c396e53ea` |
| `src/check_traces.py` | `bb7dafe83fac86d4f6d35a13ff7fb7adf55591d5af1dcabf34eba7bd10922916` |
| `src/collect.py` | `897eb64b51ac6ebe723fed822ad4ed2d4cb798298a31c634416e6d61ba0956f6` |
| `src/flock_trace.rs` | `8fffb1a6b29ddeae0012d0f837f64d6707017eda4799b1d5e824310abd38eb17` |
| `src/patch_alloc.py` | `3c98ffcd54e157af631b186675dddd80e7bec2a35c2f95e503af15f1b2865e56` |
| `src/run_case.sh` | `b8175057daac5ae510a37b7a68607c387c393b779a45d344921937977d1468cd` |
| `src/scenarios.c` | `2463d2faeb623ee8f4503f892e03ddf3ea0b7d329d4124cc14e193cd3491c1d1` |

The unchanged source model and trace contract reviewed in the initial artifact remain the interpretation for this proposal. This artifact does not approve subsequent mutable edits or a later marker merely because its filename is the same.
