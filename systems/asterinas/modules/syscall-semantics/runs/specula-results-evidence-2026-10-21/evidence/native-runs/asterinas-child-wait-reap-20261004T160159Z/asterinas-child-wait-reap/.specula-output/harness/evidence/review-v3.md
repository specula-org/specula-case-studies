# Independent harness review: candidate v3

Reviewer: `/root/harness_review`, the separate read-only agent delegated by `/root`. The reviewer did not author this correction. This is the final narrow review of the exact frozen v3 candidate, `correction-v2-v3.diff`, the applied receipt, the two v2 findings, and the execution/collection gate.

Disposition: **INCOMPLETE because R2 remains open. R5 and R6 are closed by static inspection. No new material findings were identified in the v2-to-v3 changes.** This disposition does not approve the clock method, dependent execution, implementation trace acceptance or Phase 2.5 completion. The existing gate must remain closed.

All 19 candidate-manifest entries and all 20 installed-source entries were independently rehashed and matched. The live applied receipt is byte-identical to the frozen v3 receipt. Git remains at HEAD `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The changed manifest entries are exactly the C fixture, runner, gate receipt, status page and applied receipt. The instrumentation patch, recorder, decoder, scheduler correction and scenario matrix retain their v2 hashes.

No build, fixture, Linux control, guest, collector, gate script or TLC was run by this reviewer. No controller lock was acquired. No candidate or source content was changed. The only write was this review artifact. Static closure does not certify successful compilation or execution.

## Findings disposition

### R5. Kernel artifact path: closed

`candidate-v3/run.sh:89-91` now supplies the explicit OSDK output directory `/work/.specula-output/harness/build/kernel`. Its host-side existence check and hash use `harness/build/kernel/asterinas-osdk-bin.elf` at lines 94-96. Both primary and calibration guest invocations use the corresponding mounted path at lines 109 and 119. These paths identify the same file.

This agrees with the pinned source: `kernel/Cargo.toml:2` names the crate `asterinas`, `osdk/src/base_crate/mod.rs:176` appends `-osdk-bin`, and `osdk/src/commands/build/bin.rs:88-96` appends `.elf` in the selected output directory. `make_elf_for_qemu` modifies and returns that same file at lines 135-155. `osdk/src/cli.rs:179-185` accepts `--output`, and `commands/build/mod.rs:39-45` uses it for the generated artifacts.

The incorrect `aster-kernel-osdk-bin.qemu_elf` references are removed. This closes the concrete product-name and stale-wrong-path finding. No generated kernel image is claimed to exist yet.

### R6. Linux observer-delay metadata: closed

`candidate-v3/src/wait_reap_trace.c:71-78` provides `observer_delay_cycles()`. It returns 50 million only for an Asterinas overlap run and returns zero for Linux. The guest control registration uses that helper for actor 1 at lines 81-83, and the shared metadata output uses the same helper at lines 302-307. The Linux branch of `control()` still makes no private instrumentation syscall.

Linux overlap evidence will therefore report zero kernel observer-delay cycles. The metadata no longer claims that Linux applied the guest-only retained-output intervention. This closes the specific false-provenance finding. It does not establish that a late-observer schedule occurred on either system.

### R2. Clock ordering: remains open

The recorder and C timestamp helper remain unfenced. This revision introduces no admissible method establishing that timestamps bracket each operation or supply the required cross-actor ordering. The sample handshake remains diagnostic. A future matching TLA+ interleaving cannot close this clock precondition by itself.

`candidate-v3/review-gate.json` retains `status: INCOMPLETE`, names R2, and points to the exact v2 review hash. `src/review_gate.py:9-12` rejects this status before interpreting approval inputs. `run.sh:23-28` exits 78 before fixture builds, Linux controls or the kernel build. `src/collect.py:117-118` checks the same gate before parsing or producing grouped input. These unchanged checks preserve the intended incomplete state. This review must not be used as an approval receipt for execution.

## Other delta checks and remaining evidence

The runner now records `cc --version`, the resolved `/usr/bin/cc` link, and selected wait/syscall/siginfo header plus static-libc hashes (`run.sh:41-43`). These are future execution-time provenance records. Their presence in the script is not evidence that the commands or fixture builds ran. No material static error was identified in these additions.

R1 and R4 retain the static closures recorded in review v2. The R3 scenario paths remain prepared, while actual same-interface concurrency, observer selection before removal with late output, WR-09/10 windows, event coverage and interval-overlap quality remain unobserved. WR-SQ and WR-CF remain separate unexecuted controls. The current model and instrumentation contract remain unchanged.

The source's actual CPU count, current resource admission, compiler/header/library identities, kernel and fixture binaries, Linux runtime identity, real traces and complete trace-validation witness must still be collected after the clock method receives independent exact-version review. This review performs none of those steps and establishes no kernel defect or protocol pass.

Preserve candidates v1, v2 and v3, their diffs, reviews and applied receipts. Return the R2 limitation and unfinished runtime obligations to the controller for continuation of the same campaign. Keep Phase 2.5 incomplete.

## Reviewed SHA-256 identities

Review artifact written at `2026-10-05T18:16:42.634109+00:00`.

| Candidate path | SHA-256 |
| --- | --- |
| `hashes.json` | `18705706b2f93983edd6b8e998da1b8d9e46edb5df04b439b4ff7ff32182cae3` |
| `src/wr_trace.rs` | `7b883bb76828bc2039020cfe6e2e09e33cf3242f276ddf164aa6f7562978f13c` |
| `src/wr_syscall.rs` | `aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b` |
| `src/instrument.py` | `8a42a9184e7283d9b700a5afcc6cd20cafe86a1c905141464a2d484077fcc3d2` |
| `src/Makefile` | `124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb` |
| `src/wait_reap_trace.c` | `1437deb6fbd7b77faccfc76b96d75b4cca2b2d501f3d5b029c266b9c543c27fd` |
| `src/collect.py` | `dd87d3321b6704033729299371f0031377b19844e31bbc01fea3b9f65bbe691d` |
| `src/wait_calibration.c` | `e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3` |
| `src/initramfs.py` | `589bd1c0855c9c024cae21275fd2d47d801bb867398bd7349eb5f59e1d007152` |
| `src/boot.py` | `14d03df277cb12a685fbefff3af63cdee0089e3f205e35e729bf2930dd986163` |
| `src/review_gate.py` | `30be9c210a387115234b7d0377ebda7076b056b86829505216b65cc481e77041` |
| `apply.sh` | `88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448` |
| `clean.sh` | `3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044` |
| `run.sh` | `6ff90d165c5458c5ffe57b4bd29ede29bc13351a413bcf470d6ab3be4bc9493a` |
| `cases.tsv` | `eba30152db35a608f521984474ad0ad7bab0ef67e7785b7259b50a116003efbc` |
| `review-gate.json` | `41a7a047c28dfd58e78f1f27fab855208584d24b60ce1892abae62393d8134c2` |
| `INSTRUMENTATION.md` | `182b291c1c69f91712504baa7b2d75ebd4a680b4665dee36a23a2c4256f631f9` |
| `STATUS.md` | `469a6a87434eb96cdbd7858b71897b7a1eb92a0325cded8753e8c07ba7a3dfea` |
| `patches/instrumentation.patch` | `10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb` |
| `evidence/applied.json` | `1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d` |

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
| `test/initramfs/src/regression/process/wait_reap_trace/wait_reap_trace.c` | `1437deb6fbd7b77faccfc76b96d75b4cca2b2d501f3d5b029c266b9c543c27fd` |
| `test/initramfs/src/regression/process/wait_reap_trace/wait_calibration.c` | `e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3` |
| `test/initramfs/src/regression/process/wait_reap_trace/Makefile` | `124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb` |

| Supporting input | SHA-256 |
| --- | --- |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/candidate-v2/hashes.json` | `e273e0c92860823fa5cffd1d01a96995134742d1ba13af00ca103df22c1dc42a` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/correction-v2-v3.diff` | `f0cd584fca628ce067ee1aa7660325eafc0d81a3905aed8629a8e1b812eb4ba5` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/review-v1.md` | `84f96ba7d8d48e73f3a4d14b40ea0fe318dbbf7badcd93f86fad281eacbf085f` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/harness/evidence/review-v2.md` | `119a2d239343f432911349c6161d8a02edd949ad010ce3514fab93369f658cc6` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/Cargo.toml` | `b87a7f700d502bb915e2d1705add1d41d8f8eda6b0d9b2f7385f414eb2bf8226` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/base_crate/mod.rs` | `490aa4fc7a57362e1816c3778690de6d4d1af9508c2d4aec2e2c9524b4a74676` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/cli.rs` | `4aa3017d0719197161793784808b13b70d1b2e6b9db716ec81032d796e18d471` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/commands/build/mod.rs` | `164e8849ac70088d3eba37bba4b6f1ac0a1fdb1263584b53ae33d9b5ab8f10fa` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/commands/build/bin.rs` | `a2e2a29889daacb247d0043e03ffb6a61fa9d0de58e90884f5f6e7c3ee6ce0fb` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/instrumentation-spec.md` | `69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/base.tla` | `abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/Trace.tla` | `94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/Trace.cfg` | `82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0` |
| `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/.specula-output/spec/TraceSearch.cfg` | `a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824` |
| `/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json` | `830ddc08b8aab37da0412f916e5bc9da0f7c60871c169204d1eded197d40f26e` |
