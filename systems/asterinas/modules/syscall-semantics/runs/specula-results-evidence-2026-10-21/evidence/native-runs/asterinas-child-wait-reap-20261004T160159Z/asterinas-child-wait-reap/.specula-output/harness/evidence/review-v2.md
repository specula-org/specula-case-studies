# Independent harness review: candidate v2

Reviewer: `/root/harness_review`, the separate read-only review agent delegated by `/root`. This reviewer did not author v1 or v2. The review compares the frozen v2 candidate with v1, the preserved correction diff, the existing v1 review, the pinned source, and the unchanged instrumentation/model contract. It also inspects the newly added scripts, calibration fixture, guide, status and review receipt.

Disposition: **INCOMPLETE. R2 remains open. New findings R5 and R6 require correction.** R1 and R4 are closed by static source inspection. R3's static scenario exclusions are corrected, while actual scenario coverage remains unproven. This review does not approve builds, guest execution, Linux controls, collection or TLC, and it does not approve the current clock method.

All 19 candidate-manifest entries and all 20 applied-source entries were independently rehashed and matched during review. The source remains at HEAD `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. No build, guest, fixture, TLC, gate script or collection script was executed by this reviewer. No controller lock was acquired. The only write was this review artifact.

The parent reports that one `run.sh` attempt exited 78 at the unresolved gate and recorded available memory below the build threshold. That is a gate/admission observation, not an affected verification run. This reviewer did not independently execute or inspect that attempt's receipt. The candidate's documented runtime and validation results remain `NOT_RUN`.

Unless explicitly qualified otherwise, `src/`, `run.sh`, and other harness references below are relative to `evidence/candidate-v2`.

## Previous findings

| Finding | v2 disposition | Evidence and remaining boundary |
| --- | --- | --- |
| R1, imports before inner documentation | **CLOSED by static inspection.** | `src/instrument.py:33-36` inserts the import before the first existing import. Applied `kernel/core/src/process/pid_table.rs:3-12` and `process/status.rs:3-9` now keep their inner documentation before items. This closes the identified parser error, not all possible build errors. No corrected Rust build ran. |
| R2, unfenced operation timestamps | **OPEN.** | `src/wr_trace.rs:62-65` and the C timestamp helper remain unfenced. No new clock/environment evidence establishes sound intervals. Passing samples or a future matching TLA+ path must not be called implementation trace acceptance. |
| R3, absent same-interface and observer/consumer schedules | **STATIC EXCLUSIONS CORRECTED. Runtime coverage remains NOT_RUN.** | `src/wait_reap_trace.c:190-192,211-212,250-265` supports both consumer API choices and a separate overlap scenario. `cases.tsv:7-16` requests same-interface, mixed-interface and observer/consumer pairs. A preliminary WNOWAIT call establishes an exit before ready-child cases, at fixture lines 245-248. Completion checks allow either legal overlap outcome. They do not prove that the requested late-observer history happened. |
| R4, false park-check end after actor lookups | **CLOSED by static inspection.** | Applied `ostd/src/task/scheduler/mod.rs:457-460` saves the end immediately after `has_unparked()` and before the actor lookup. The true branch still emits only after `reschedule` returns at lines 491-494. R2 remains independent. |

The observer delay is inserted at applied `kernel/core/src/syscall/waitid.rs:62-65`, after `do_wait` returns and before reading the retained status. The parent's children mutex, signal-registration guard, and waiter object have completed their scoped work by this point. `src/wr_trace.rs:134-140` uses only local recording state and a cycle-based spin, with no new modeled-lock acquisition or global handshake. The guest fixture requests 50 million cycles and registration caps the request at 100 million. This makes a late observer possible without blocking while holding a modeled lock. It does not guarantee the schedule, establish a wall-time bound independently of the clock, or remove probe effects. WR-09/10 and overlap quality still need real internal evidence after admission.

## New material findings

### R5. The run script selects a kernel filename this source does not generate

Status: **OPEN. This blocks the prepared build/boot path and can misidentify a stale image.**

`run.sh:91-93` selects and hashes `source/target/osdk/aster-kernel-osdk-bin.qemu_elf`. Both guest commands repeat that path at lines 106 and 116. The pinned package is named `asterinas` in `kernel/Cargo.toml:2`. `osdk/src/base_crate/mod.rs:176` creates its generated executable name by appending `-osdk-bin`. `osdk/src/commands/build/bin.rs:88-96` then appends `.elf` to the executable filename. `make_elf_for_qemu` modifies that existing ELF in place and returns it at lines 135-155. It does not rename the product to `.qemu_elf`.

The product under the current default output directory is therefore `target/osdk/asterinas-osdk-bin.elf`. On a clean checkout, the script's `test -s` fails even after a successful build. If an unrelated old image happens to occupy the hardcoded name, the script can hash and boot that image instead of the current instrumented product.

Minimal correction: choose the pinned source's actual product name consistently for existence check, hashing and both boot commands. An explicit OSDK `--output` directory under the harness build directory also avoids relying on a shared source output path. Preserve the resulting script and exact-version diff for review. This finding is established from the source and script, not from a build attempt.

### R6. Linux overlap metadata claims the guest-only delay was applied

Status: **OPEN. This records a false Linux control intervention.**

`src/wait_reap_trace.c:73-79` passes the 50-million-cycle delay through the private control syscall only when compiled with `__asterinas__`. The Linux variant merely returns `sysconf(_SC_NPROCESSORS_ONLN)` and applies no kernel output delay. Nevertheless, the shared `WR_META` output at lines 294 and 299 writes `observer_delay_cycles: 50000000` for every overlap scenario on both platforms. `run.sh:47-49,52-58` builds and executes that Linux variant, so its evidence would incorrectly report the guest intervention as having occurred on Linux.

Minimal correction: record the actual applied delay as zero in the Linux variant, or separate requested and applied values with an explicit platform distinction. Do not implement a userspace delay and call it the same retained-kernel-output intervention. The primary and Linux control can use different schedule controls when that difference is documented accurately.

## Review gate and honest incompleteness

The current receipt's `status` is `INCOMPLETE`, with R2 named as the blocker. `src/review_gate.py:9-12` rejects that state immediately. `run.sh:23-28` records the incomplete gate and exits 78 before fixture builds, Linux tests or kernel work. `src/collect.py:117-118` checks the gate before reading the log or creating decoded/grouped outputs. Thus the existing gate does preserve the incomplete state. The pre-gate apply step and host-memory observation are preparation, not protocol verification.

An eventual approved receipt also verifies the review artifact hash and mandatory semantic-input hashes (`src/review_gate.py:13-21`). This is a receipt check, not automatic assessment of the review's adequacy, as the guide correctly states. Nothing in this review authorizes changing that receipt to APPROVED. New R5/R6 findings must be preserved alongside R2 for the next exact candidate.

`STATUS.md` and `INSTRUMENTATION.md` keep the corrected candidate unbuilt, runtime controls unexecuted, real traces absent, the schedule windows unobserved and the phase incomplete. They preserve WR-SQ as a source lead and WR-CF as uncalibrated. No synthetic checker fixture is presented as implementation evidence. This is an appropriate current disposition.

## Other inspected controls and scripts

The separate `wait_calibration.c` exercises live-child zeroed/poisoned waitid WNOHANG outputs, then fresh-child consuming wait4/waitid faults and a WNOWAIT fault. It checks actual returns/errno and the following valid wait. It never registers a trace actor, so the tracing begin hook does not pre-read its inaccessible output and change the fault into a pre-consumption failure. The frozen script boots it in a separate guest, keeping these faults outside primary trace construction. No calibration result is established statically.

The fixture Makefile uses the repository's existing regression build rules. Their wildcard C source rule includes the new calibration executable. The minimal initramfs contains a static `/init` with a CPIO trailer. The pinned kernel's `fs/initramfs.rs:66,86-103` supplies `/dev/console`, so omission of that node from this small archive is supported by this source.

The planned Docker/guest path uses the individually exposed `/dev/kvm`, no host `/dev` mount, the specified CPU/memory/PID limits, and outer timeouts. It does not reacquire the controller lock. The host memory check immediately preceding the kernel container is separate from the earlier diagnostic reading. `boot.py` uses two guest CPUs and keeps fixture completion separate from host-directed QMP termination. These are inspected script intentions, not successful runtime evidence.

The correction diff covers changed preexisting candidate files. New script/control contents are preserved and bound by the v2 manifest and were read directly in this review. Their hashes appear below. No wider source audit or general infrastructure approval is implied.

## Next disposition

Preserve v2 and this review. Correct R5 and R6, record a new exact candidate/diff, and obtain the narrow follow-up review. R2 must remain open until the controller provides an admissible clock method and its independent review. All actual runtime schedule coverage, calibration, collection quality and quick trace validation remain outstanding. Do not report Phase 2.5 complete.

## Reviewed SHA-256 identities

Review artifact written at `2026-10-05T18:12:58.997230+00:00`.

| Candidate path | SHA-256 |
| --- | --- |
| `hashes.json` | `e273e0c92860823fa5cffd1d01a96995134742d1ba13af00ca103df22c1dc42a` |
| `src/wr_trace.rs` | `7b883bb76828bc2039020cfe6e2e09e33cf3242f276ddf164aa6f7562978f13c` |
| `src/wr_syscall.rs` | `aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b` |
| `src/instrument.py` | `8a42a9184e7283d9b700a5afcc6cd20cafe86a1c905141464a2d484077fcc3d2` |
| `src/Makefile` | `124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb` |
| `src/wait_reap_trace.c` | `b649c793598d2981f59a25309194ebfa3202ae656a8b5c1ef603ee0212723d3e` |
| `src/collect.py` | `dd87d3321b6704033729299371f0031377b19844e31bbc01fea3b9f65bbe691d` |
| `src/wait_calibration.c` | `e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3` |
| `src/initramfs.py` | `589bd1c0855c9c024cae21275fd2d47d801bb867398bd7349eb5f59e1d007152` |
| `src/boot.py` | `14d03df277cb12a685fbefff3af63cdee0089e3f205e35e729bf2930dd986163` |
| `src/review_gate.py` | `30be9c210a387115234b7d0377ebda7076b056b86829505216b65cc481e77041` |
| `apply.sh` | `88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448` |
| `clean.sh` | `3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044` |
| `run.sh` | `561fa77ecc759d46811a691f745b507c967b3c0ebaf2810266c6574e83544344` |
| `cases.tsv` | `eba30152db35a608f521984474ad0ad7bab0ef67e7785b7259b50a116003efbc` |
| `review-gate.json` | `83140c497fb4fd746236476ba2a5da5c19870a6df49527b479817f7105b7d017` |
| `INSTRUMENTATION.md` | `182b291c1c69f91712504baa7b2d75ebd4a680b4665dee36a23a2c4256f631f9` |
| `STATUS.md` | `8b6c6334afd6aaee20147107e78b58d4e84991d6fdb11a21a0e324058d3d9548` |
| `patches/instrumentation.patch` | `10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb` |
| `evidence/applied.json` | `4462b88c43476937aba0b0f21ee22d5b27f8cedfc4065306d5b6c73873b860e5` |

| Applied source path | SHA-256 |
| --- | --- |
| `ostd/src/lib.rs` | `acc93d827d3b3d3272da051161e88f435255425400e08fc3667199c755d6cbaa` |
| `kernel/core/src/syscall/mod.rs` | `f92b828c3becdcdd3d5311481f7fde262fabdae72497edb9badc1d68665b6482` |
| `kernel/core/src/syscall/prctl.rs` | `a59528cd446cbb07a9bbe0a8021b2bbf374a6e76bcce685a8506d8e027fb8fc8` |
| `kernel/core/src/syscall/wait4.rs` | `1c91f491697c2b7ef2e7bbf77ec4b09f6d122a3957851d5f7b53534d7b788a50` |
| `kernel/core/src/syscall/waitid.rs` | `75a1f5084999d72445603398ff837040c3324876bccde9f4da2e7f7e18e27038` |
| `kernel/core/src/process/wait.rs` | `6591eb9912c2e0374b61f4c62dc09317e97a3d069897c5e883c8c1e4c471a14f` |
| `kernel/core/src/process/pid_table.rs` | `c07b2b498375a5be48d2114357aaca1036d2367dc8c876e42d1b1540f7cac28b` |
| `kernel/core/src/process/status.rs` | `35930b477736595748f08c73e97d052c7841240385d5395789fd6c1cd8f54d6b` |
| `kernel/core/src/process/signal/pause.rs` | `41f07bc9e62acadf6c7fac53467ab9926e5ccdb60c54d93f64e1762f088f582f` |
| `kernel/core/src/process/posix_thread/mod.rs` | `3d6d588ef244fabc616ab94db45e0f2f7afa09f92cfb4a0ec588ede82f1e9dcc` |
| `kernel/core/src/process/process/mod.rs` | `0bbae0b5c78dc3f0bf935956f6be545aa4756b079c20e3a71e4077916fa7c680` |
| `kernel/core/src/process/exit.rs` | `9af4203cdde3f5943fc7ef9acae04de9dd215c0eb9c928537dc56a1c6a9716fd` |
| `ostd/src/sync/wait.rs` | `9ca169153a14e7169de647d43f8d09c1b78e0edfd3428358bf899572b4ce511a` |
| `ostd/src/task/scheduler/mod.rs` | `4a6602138bf8fb1074f60bcbb885fc120f17253fe65879fb895fb09cfe768df7` |
| `test/initramfs/src/regression/process/Makefile` | `52e77399113a2ec9227425bc21d9445ea49715e0b1b8792e71796161568a0fbe` |
| `ostd/src/wr_trace.rs` | `7b883bb76828bc2039020cfe6e2e09e33cf3242f276ddf164aa6f7562978f13c` |
| `kernel/core/src/syscall/wr_syscall.rs` | `aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b` |
| `test/initramfs/src/regression/process/wait_reap_trace/wait_reap_trace.c` | `b649c793598d2981f59a25309194ebfa3202ae656a8b5c1ef603ee0212723d3e` |
| `test/initramfs/src/regression/process/wait_reap_trace/wait_calibration.c` | `e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3` |
| `test/initramfs/src/regression/process/wait_reap_trace/Makefile` | `124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb` |

| Supporting input | SHA-256 |
| --- | --- |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/candidate-v1/hashes.json` | `033da3a79244740318d39509eefa347cd19427ae0518d6b158867150c1228fb4` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/correction-v1-v2.diff` | `7ae6812fec6bfe9bf6d657c56fcaaa9007dbafad015eb1ac573f710d7cddc423` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/review-v1.md` | `84f96ba7d8d48e73f3a4d14b40ea0fe318dbbf7badcd93f86fad281eacbf085f` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/Cargo.toml` | `b87a7f700d502bb915e2d1705add1d41d8f8eda6b0d9b2f7385f414eb2bf8226` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/base_crate/mod.rs` | `490aa4fc7a57362e1816c3778690de6d4d1af9508c2d4aec2e2c9524b4a74676` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/commands/build/mod.rs` | `164e8849ac70088d3eba37bba4b6f1ac0a1fdb1263584b53ae33d9b5ab8f10fa` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/commands/build/bin.rs` | `a2e2a29889daacb247d0043e03ffb6a61fa9d0de58e90884f5f6e7c3ee6ce0fb` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/util.rs` | `7ec9276b0aabcbae7e954606d2fd7d4902f4d11f215b11199c83be3f8f2e681d` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/OSDK.toml` | `155af7cb53b4dffc679393b8fc7c2c1719a74134a0ec2b0812f0c4b53a6c609b` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/tools/qemu_args.sh` | `90cafa4cdbc6fbc80b01c5030c3896c0a0343b463a7946e6aa2498825d28700e` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/Makefile` | `f7d24eb8e81b58d4cf0342862318cbfcf63cd8cff8d0f6f69fb7656295192af6` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/test/initramfs/src/regression/common/Makefile` | `85de0ea51349f7aa83e7212ccfaa0f2f261e8a060515e6eacd45d5eeca4eb0c7` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/fs/initramfs.rs` | `607ec44fef36f8d4c5cdc4028174038477ba4ff37622d8365a9f41d945004ef2` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/process/posix_thread/exit.rs` | `c48c21b8e9abc4590f097588b2d16c6072a43b2da0cdd67e426623acfcc26044` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/instrumentation-spec.md` | `69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/base.tla` | `abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/Trace.tla` | `94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/Trace.cfg` | `82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/TraceSearch.cfg` | `a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824` |
| `/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json` | `830ddc08b8aab37da0412f916e5bc9da0f7c60871c169204d1eded197d40f26e` |
| `/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/contracts.md` | `b0398a42c9ccfe551d8cd47cad45b7ac130e075e1a42c829a98ec762ccc19096` |
