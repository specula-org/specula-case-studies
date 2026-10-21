VERDICT: NOT_APPROVED

Findings (Spec):

**D9-S1 — Medium: yielding cannot perform the assumed migration.**  
The new [loop and comment](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/wait_reap_trace.c:74) assume migration occurs at the next reschedule. The pinned source `0c60537098f4c2949ad2d382aaf499de72263d76` contradicts that assumption:

- [`sched_setaffinity`](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/syscall/sched_affinity.rs:33) explicitly documents unsupported migration and only stores the mask.
- [`yield_now()`](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/task/scheduler/mod.rs:560) schedules from the current CPU’s runqueue. [`try_pick_next()`](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/sched/sched_class/mod.rs:373) requeues the previous task into that same queue.
- Even after blocking, [`select_cpu()`](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/sched/sched_class/mod.rs:285) returns `last_cpu` before consulting affinity.

Consequently, a task on the wrong CPU remains there. D9 adds up to 100,000 yields before the original assertion without fixing the failure. The diagnosis in `d9-amendment.md:12` is therefore incorrect.

**Minimal fix:** remove the ineffective retry and correct the migration claim. Keep acceptance blocked until a separately reviewed solution establishes CPU placement through a mechanism supported by this scheduler. Retain the CPU assertions.

**D9-S2 — Low: the range changes five files, exceeding the stated four-file scope.**  
The additional change is [d8-amendment.md:37](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/evidence/d8-amendment.md:37), which addresses the previous D8-S2 documentation finding and has no runtime effect.

**Minimal fix:** explicitly include this documentation correction in the declared scope or separate it from the range.

Findings (Standards):

**D9-T1 — Low: the amendment violates the prose rule against joining clauses with semicolons.**  
[d9-amendment.md:24](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/evidence/d9-amendment.md:24) contains “The Asterinas behaviour is not checked yet; that needs the guest run.”

**Minimal fix:** replace the semicolon with a period.

Spec has one Medium and one Low finding. Standards has one Low finding.

Disposition: **REJECTED for `OUTCOME_ONLY`** at `0d33a8afbac979828262bfbc2826c61f290f1d03`. **D9-S1 blocks approval.** The earlier approval remains scoped to `6607d1685792fadb71e9c2d1acf30d0bb75ac7bb`.

The remaining checks passed:

- Both C files are byte-identical to the base outside `pin()`. Outcome calls, expectations, comparisons and later `check_cpu()` assertions are unchanged. All six `pin()` call sites hold no wait/reap lock or protocol object.
- The loop bounds yield attempts and retains the original failure assertion. On Linux, successful singleton affinity gives zero loop iterations, adding only a CPU query. [Linux affinity contract](https://man7.org/linux/man-pages/man2/sched_setaffinity.2.html).
- [`getcpu`](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/syscall/getcpu.rs:17) reports the current CPU. The supplied pre-D9 evidence contains 21 matching Linux controls and 21 inconclusive guest outcomes, all with the `pin()` assertion failure. All 42 recorded raw-log digests match.
- All 32 supplied hashes match working files and committed blobs. All 27 manifest entries match live and frozen files, with no missing or extra snapshot files. `evidence/applied.json` was checked as the supplied v3-install receipt.

Read-only static review. `git diff --check` passed and the workspace remains clean. No Docker, builds, QEMU or TLC ran.

REVIEWED INPUTS

```text
124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb  src/Makefile
21b9e2e00c504392357142e9819fbce050ace5c9bd89cbdd683d054c8792eaf4  src/boot.py
1a5bb46944104a65aed8e34eee7c048c7d87e9774b75ea060401cbd0e7bba08f  src/collect.py
94a563da5905689c110f609d608e72541a5f0d588e50b4e7831212a20089be13  src/collect_outcome.py
ee83062435d51ac1563cd638c1e06bf8c5da13392aa40f0f945e25d331c096e4  src/initramfs.py
3cdd3187ca71d4f3705063e010ebea20995d30947f08f84ef8544128a4e21ef7  src/instrument.py
3eb8516d5a452957ded5d66c98e1068d6941a0d998981bd6c2b04c8a7241b78f  src/nproc_probe.c
5d0ebc742f17a49f53b79f42dd19195dc42fe94097ae20acbc0ff7032105a500  src/review_gate.py
e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3  src/wait_calibration.c
f4967bfd3303155d4fa354e58b3154f10424c8ecf56eaf83fb9b24fa25e98926  src/wait_reap_trace.c
aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b  src/wr_syscall.rs
be259a36672e86a0c6710e20ae3a8d6e94c17b7ef8b64849f9073cf40f2167b4  src/wr_trace.rs
fa6027893e37d734274657147bfb3ff409707a3cd434f4ee666b4e82dae144dd  run.sh
88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448  apply.sh
3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044  clean.sh
e41813141c7aeb3f9ccaf5fe023d8d19fe19a8b8c275408b5f6e3af8d72e4b9e  cases.tsv
10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb  patches/instrumentation.patch
1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d  evidence/applied.json
981fce04ee3d7c000e562044419e5a06d467fb91b70582bb437cc26c1241961e  INSTRUMENTATION.md
05047292ab7e422497dc025da64293e249e40559461fe3eba8e416b0698be457  STATUS.md
fcaca87d2aa3f748f9e0dff21faa9b1ee242f1d9cd4170be48e8f8e03130134d  evidence/clock-method-v4.md
252e97d05d2216ef6714f2679169e00a8c56df7d5d5d16bac1007bf67528c752  evidence/clock-method-v5.md
49f6a47ce73dbb6e11f6ecdc3ecde6b5640d29eb097840ab3fb9fa103b8bea2b  evidence/v5-inputs.json
8e3b936025a6028c5794ae568006a5f6abc34ae044173d8b88096e0a7cdb32f1  evidence/candidate-v5/hashes.json
05f55403ef92af50dc752b605cf5da07720abb43137e5b1cf323d5f03132d88b  evidence/outcome-mode-v6.md
435ba914e0fade23fa70921c45bb4191b68fe7da75d9fda78811c0cd856baf3b  evidence/v6-inputs.json
32657fb1b1628219995ef1eb322b4eae79eafce746c0a9d8337af0de3c44140d  evidence/candidate-v6/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

