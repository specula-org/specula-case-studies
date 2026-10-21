# Independent harness review: candidate v1

Reviewer: `/root/harness_review`, a separate read-only review agent delegated by `/root`. The reviewer did not author the candidate. This review is limited to Phase 2.5 and the exact frozen candidate listed below.

Disposition: **INCOMPLETE. Material findings remain open. Do not treat candidate v1 as reviewed approval for dependent verification or trace acceptance.** The clock issue remains a limitation even if future TLC exploration finds a matching interleaving. No kernel build, guest run, Linux control, TLC run, or runtime trace inspection was performed in this review. The parent reported only C fixture compilation before review. No controller lock was acquired, and no candidate or source file was changed.

The candidate's eight manifest hashes were recomputed and matched. All 19 current source files in its applied receipt also matched when read back during review. Git HEAD is `0c60537098f4c2949ad2d382aaf499de72263d76` and its tree is `4693fdec88cd7da14bed4f1541eba593f123059c`. References to `src/` and `patches/` below are relative to `evidence/candidate-v1`. References to kernel and OSTD paths describe the applied version bound by that receipt.

## Material findings

### R1. Instrumentation puts imports before inner module documentation

Status: **OPEN. This blocks Rust compilation.**

`src/instrument.py:33-34` prepends the tracing import immediately after the license header. Its applications at lines 90-95 insert an item before existing inner documentation in both PID-table and process-status modules. The frozen patch shows this at `patches/instrumentation.patch:26-28` and `168-170`. Applied `kernel/core/src/process/pid_table.rs:3-10` and `process/status.rs:3-5` contain `use ostd::wr_trace as wr;` followed by `//!` documentation. Rust inner documentation must precede module items. This placement is a compile error, independently of the successful C fixture compilation. This is a static finding, not a claimed compiler execution.

Minimal correction: insert each import after the complete inner documentation block. Update the application generator and regenerated patch together, then preserve a new candidate and obtain its exact-version review before building.

### R2. Unfenced TSC samples do not establish sound operation intervals

Status: **OPEN. This blocks trace acceptance under the current contract.**

`src/wr_trace.rs:60-64` uses the existing `read_tsc`, whose implementation at `ostd/src/arch/x86/mod.rs:137-141` directly calls `_rdtsc()`. The fixture likewise calls `__rdtsc()` at `src/wait_reap_trace.c:48`. These reads do not by themselves establish execution ordering before and after the measured memory operations. CPU pinning at fixture lines 54-60 and 209-220 prevents the fixture's intended migration, but does not supply instruction ordering or an established bound on cross-vCPU clock offsets and drift.

The 64 handshakes at fixture lines 141-145 and 224-232 check only that those particular four reads were numerically ordered. They do not bound timestamp reordering around each zombie store/load, token swap, queue RMW, or runqueue transition. Passing those samples cannot prove that an event end preceded another actor's start in real execution. Yet `src/collect.py:159-165` compresses all raw values into one exact total timestamp order, and `spec/Trace.tla:143-146` uses that order to forbid competing interleavings. The collector correctly labels the sidecar `CALIBRATED_SAMPLES_ONLY_UNFENCED_TSC` and `NOT_VALIDATED` at lines 166-170, but the grouped input itself remains consumable by a validator without establishing this precondition.

The instrumentation contract requires operation-bracketing timestamps, documented clock ordering, cross-CPU calibration, and rejection of clock-incomparable events (`spec/instrumentation-spec.md:135-139`). A future complete `TraceSearch.cfg` witness would establish a match for the supplied numbers only. It cannot repair their missing relation to the implementation schedule or justify a protocol/concurrency acceptance claim.

Minimal disposition now: keep this candidate and any diagnostic records explicitly incomplete and ineligible for trace acceptance. Closing this finding requires a separately preserved and independently reviewed clock/environment method that establishes the needed interval ordering while respecting the instruction not to add a fence across the synchronization bridge. Do not silently add fences, discard the timestamp constraints, widen intervals from expected-model ordering, or reinterpret passing handshakes as proof. If such a method is unavailable in this phase, return the limitation to the controller for continuation.

### R3. The fixture cannot exercise three required competing histories

Status: **OPEN. This blocks the requested scenario-coverage claim.**

The only competing scenario fixes the worker to waitid WEXITED at `src/wait_reap_trace.c:200-201` and the main task to blocking wait4 at lines 234-241. All noncompeting scenarios enable the worker only after the main task finishes consumption, at lines 249-258. Both WNOWAIT observations also execute synchronously on that same main task before consumption, at lines 250-255.

Consequently this candidate cannot generate WR-06's two wait4 consumers, WR-07's two waitid consumers, or WR-08's WNOWAIT observer/consumer overlap. In particular, there is no route for an observer to retain a selection, let the other task consume it, and then complete output late. These schedules are explicit requirements in `wait-reap/contracts.md:88-90` and `spec/instrumentation-spec.md:157`, and WR-08 directly supports priority question 2. Varying `exit_delay_us` cannot make these program-order exclusions disappear.

Minimal correction: allow the two established waiter tasks to select the required API combinations, and add an observer/consumer scenario. Preserve real hook evidence for the late-observer history. Any schedule control must respect the prohibition on blocking solely to force a schedule while holding a modeled lock. If the history cannot be obtained with admissible controls, record it as uncovered and return incomplete instead of declaring the whole matrix covered.

WR-09 and WR-10 may occur opportunistically in the current competing scenario, but the user-space started bits and sleep duration do not establish either internal window. Their disposition must be based on the recorded failed scan, registration, recheck, token, park, unpark, and completion boundaries. No runtime evidence currently exists to make those dispositions.

### R4. The false park-check interval ends after tracing lookups

Status: **OPEN. This does not meet the specified false-branch boundary.**

At `patches/instrumentation.patch:660-662`, corresponding to applied `ostd/src/task/scheduler/mod.rs:457-459`, the actual load result is saved correctly. However, before obtaining its end timestamp the code calls `wr_trace::parking()`, then `waiter_event()`. Those helpers perform current-task and actor lookups and atomic metadata reads (`src/wr_trace.rs:66-82,88-95,145-147,212`). Only the last helper calls `stamp()` for the event end. The explicit false-branch rule requires saving the end immediately after the load, before these capture/serialization operations (`spec/instrumentation-spec.md:128,135`). The current placement can manufacture additional apparent interval overlap during tracing overhead, while the target runqueue guard remains held.

Minimal correction: save the false-branch end next to the saved `has_unparked()` result and pass both timestamps to the emission helper. Keep the true-branch end after `reschedule` returns, as the candidate already does. Do not replace the saved load result with a reread, and do not add a fence. The clock limitation in R2 remains separate.

## Source and model observations

The review found several sound structural choices that should survive correction:

- Hooks are in the real wait, process-exit, signal, queue, and scheduler paths. The decoder maps observed branches and operation outcomes to control labels rather than advancing a standalone expected protocol.
- Consuming removal remains inside the children's mutex. The cloned Process Arc survives removal, and output-read, copyout, explicit WaitStatus drop, and kernel return are distinct hooks. The caller's return and errno are separately collected and merged by actor/generation (`src/collect.py:91-95`).
- Each traced Waker stores its original generation pair. Queue snapshots preserve duplicate and closed entries, and notifications use the child's stream. Old entries are not retargeted using the waiter's current call counter.
- The signal-slot guard spans wake_up and is explicitly dropped before WakeFinish. The queue pop/count update occurs under the existing queue lock and releases it before its separate wake.
- The token swap return values are saved directly. The false park check retains the runqueue guard, dequeue has a separate event after guard release, and the true branch emits no dequeue/resume. Scheduler unpark still calls the original enqueue path with its CPU-assignment retry. These are source observations, not runtime proof.
- The collector rejects reported drops, mismatched stream counts, local interval overlap, kernel/user timestamp inversions, and oversized/truncated queue snapshots. It compresses timestamps monotonically without sorting each actor's event array. It does not fabricate optional spurious-return events.
- `Trace.tla` has exact post-record checks for all 41 events, full base-action dispatch, no silent actions, and a completion condition covering returns and notifier completion. `TraceSearch.cfg` is the stated existential acceptance configuration. A temporal failure in the optional universal `Trace.cfg` is not by itself an existential rejection.

The structural checks do not close the findings. In particular, field values derived from a confirmed construction, removal, or local guard boundary are reasonable projections. They are not a substitute for timestamp ordering or runtime schedule evidence. Optional `ParkCurrentSpurious` remains uncovered and must be documented rather than inferred from timeout or token state.

## Scope and next gate

The frozen candidate does not include `run.sh` or `INSTRUMENTATION.md`. Their eventual orchestration, environment provenance, timeouts, actual SMP, binary/kernel/model hashes, Linux control identity, coverage disposition, and acceptance handling are outside this exact-version review. The review does not approve end-to-end execution or certify Phase 2.5 completion.

All four findings remain unresolved in v1. The parent should preserve this review with the candidate, make the narrow corrections or record an incomplete handoff, and request review of the resulting exact candidate before dependent verification. No kernel defect, lost wakeup, WR-SQ reproduction, WR-CF result, Linux-control result, or concurrency result is established here.

## Reviewed SHA-256 identities

The first table contains the immutable candidate manifest, followed by every entry it binds. The applied-source table repeats every source identity checked against the frozen receipt. Additional source files were read to verify scheduler, mutex, task-context, and exit boundaries. The last table pins the contract and model inputs used for this review.

Review artifact written at `2026-10-05T17:57:03.697963+00:00`.

| Candidate path | SHA-256 |
| --- | --- |
| `hashes.json` | `033da3a79244740318d39509eefa347cd19427ae0518d6b158867150c1228fb4` |
| `src/wr_trace.rs` | `e5d9d3b21ba6c33f3081e0bfc9011361e39216911429d2c78d35d41078988716` |
| `src/wr_syscall.rs` | `a8b77d01860ce6aa39f23c6d352a1f84e3574c6ce2b38088fe7a85b5a0b6f5af` |
| `src/instrument.py` | `6600d1821da741e1f83325adcc77a6869aebbed4790e278bc9ef3861a9f14a9b` |
| `src/Makefile` | `124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb` |
| `src/wait_reap_trace.c` | `ab86a3a7e03154df540f9663f13e0bf332ea2990351583108b139af1bb03fe82` |
| `src/collect.py` | `7bf7d42bb2054500d9e0e6f3480229ad9095bc1ca43b6051f87abcd1cefae5c2` |
| `patches/instrumentation.patch` | `e3243c445276bd71a769b92d64c053b733152bc1f716a737b513e08ac6e92e7d` |
| `evidence/applied.json` | `c2d5926c2892109b1f9d66f5e64d2e04dd96ad13ecada4c9b28e93ad2983ccb5` |

| Applied source path | SHA-256 |
| --- | --- |
| `ostd/src/lib.rs` | `acc93d827d3b3d3272da051161e88f435255425400e08fc3667199c755d6cbaa` |
| `kernel/core/src/syscall/mod.rs` | `f92b828c3becdcdd3d5311481f7fde262fabdae72497edb9badc1d68665b6482` |
| `kernel/core/src/syscall/prctl.rs` | `1889faa968e8c7a991c973644dd6b8fa3a1e5b26af0627c7f9b302c8ec31ba3a` |
| `kernel/core/src/syscall/wait4.rs` | `1c91f491697c2b7ef2e7bbf77ec4b09f6d122a3957851d5f7b53534d7b788a50` |
| `kernel/core/src/syscall/waitid.rs` | `cfb93db7fe03c45998e31f1e8082d0886c3b8f0464fe4560d6d665cd0e882f19` |
| `kernel/core/src/process/wait.rs` | `6591eb9912c2e0374b61f4c62dc09317e97a3d069897c5e883c8c1e4c471a14f` |
| `kernel/core/src/process/pid_table.rs` | `e3ae8ee517dfd21554050c185b771843da4c5ee217f5d3541b84b65bf6d9c815` |
| `kernel/core/src/process/status.rs` | `e4206cbc5171e0940437af38a7c2d31ea7afe8bfcc51f9c7016652bb582de373` |
| `kernel/core/src/process/signal/pause.rs` | `41f07bc9e62acadf6c7fac53467ab9926e5ccdb60c54d93f64e1762f088f582f` |
| `kernel/core/src/process/posix_thread/mod.rs` | `3d6d588ef244fabc616ab94db45e0f2f7afa09f92cfb4a0ec588ede82f1e9dcc` |
| `kernel/core/src/process/process/mod.rs` | `0bbae0b5c78dc3f0bf935956f6be545aa4756b079c20e3a71e4077916fa7c680` |
| `kernel/core/src/process/exit.rs` | `9af4203cdde3f5943fc7ef9acae04de9dd215c0eb9c928537dc56a1c6a9716fd` |
| `ostd/src/sync/wait.rs` | `9ca169153a14e7169de647d43f8d09c1b78e0edfd3428358bf899572b4ce511a` |
| `ostd/src/task/scheduler/mod.rs` | `a86748b190ca6a1132e1b0d92cbd07e0924d76a0e5896f38f634b9ac384ce21b` |
| `test/initramfs/src/regression/process/Makefile` | `52e77399113a2ec9227425bc21d9445ea49715e0b1b8792e71796161568a0fbe` |
| `ostd/src/wr_trace.rs` | `e5d9d3b21ba6c33f3081e0bfc9011361e39216911429d2c78d35d41078988716` |
| `kernel/core/src/syscall/wr_syscall.rs` | `a8b77d01860ce6aa39f23c6d352a1f84e3574c6ce2b38088fe7a85b5a0b6f5af` |
| `test/initramfs/src/regression/process/wait_reap_trace/wait_reap_trace.c` | `ab86a3a7e03154df540f9663f13e0bf332ea2990351583108b139af1bb03fe82` |
| `test/initramfs/src/regression/process/wait_reap_trace/Makefile` | `124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb` |

| Additional input path | SHA-256 |
| --- | --- |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/sync/mutex.rs` | `af64fd9e97afbaa399277683c570fa314b3ff63f3a5599b434a59dfbd275e71e` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/arch/x86/mod.rs` | `dd2b26d445b8dca9b72d02e0a6008b0ef8670d55e44146f1cf85ed35727f0fdc` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/task/mod.rs` | `7458cb746d2a769313b4e12b525db56df1eba9aff09429cf535f53a7eed86b4f` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/irq/level.rs` | `1220a7a8035ec2a48789b736dd363e5e9fd50f2f191e5fef438433606e389632` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/sched/sched_class/mod.rs` | `b506d98f66793b0c65f63f5de56d52cbf97f065bf64e7f0999c031b811ea46a6` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/time/wait.rs` | `704a9d8841850d1be34f2dffa682f36a8a7f9bdbb831aca1ab028c54df4327b7` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/process/posix_thread/exit.rs` | `c48c21b8e9abc4590f097588b2d16c6072a43b2da0cdd67e426623acfcc26044` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/instrumentation-spec.md` | `69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/Trace.tla` | `94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/Trace.cfg` | `82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/TraceSearch.cfg` | `a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/base.tla` | `abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10` |
| `/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json` | `830ddc08b8aab37da0412f916e5bc9da0f7c60871c169204d1eded197d40f26e` |
| `/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/contracts.md` | `b0398a42c9ccfe551d8cd47cad45b7ac130e075e1a42c829a98ec762ccc19096` |
| `/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/SKILL.md` | `6fa44f719ef7196a5136465e3526c6d7d4631b13cddabd7d2dc8a4027731e568` |
| `/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/guide.md` | `5bf9df32d1917dfd23e4fbf60b32356d8a3d5195fd8e1618b7ca0b0cbe01a18b` |
| `/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/references/concurrent-timebox-guide.md` | `d137e242df46c0357d6f02b70d75722181e925a3c7f72e5d6f2789ab56528f22` |
| `/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/references/trace-module-patterns.md` | `7d89dbfab3253947d40c5ecc503692f8360abf0d55c06dbfec7fc6dcfc048c99` |
