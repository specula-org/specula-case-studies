# Confirmation Report — asterinas-memfd-seal-mapping-admission

## Final Result

Reproduced bugs: 2 = 0 NEW + 2 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 3
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 2 reproduced + 0 env-limited + 0 masked + 3 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | CR-1 | FALSE POSITIVE | no |
| 4 | CR-2 | FALSE POSITIVE | no |
| 5 | CR-3 | FALSE POSITIVE | no |

## Entry 1: Post-seal read-only mappings retain writable accounting

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-1/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
I've read the skill. Now let me set up tasks and begin Phase 1 investigation.
using TaskCreate: Read affected code (map.rs:337, memfd.rs:80, vm_mapping.rs:944, vmo/mod.rs:1199), trace call chain, read counterexample, git history/issue search, write investigation.md
using TaskCreate: Write repro/test_bugMC-1_*.{c,rs,sh}, execute in Asterinas worktree, walk escalation ladder, decide verdict per decision table
using TaskUpdate
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec /home/chin3...
The worktree is at the right commit (0c6053709). Now let me read the counterexample for my finding (the file cited in the finding JSON).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec && ls outpu...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec/output/validation/MC_hunt_scenario...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec && grep -n...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec && tail -60...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec/output/validation/MC_hunt_scenario...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec && awk ' /^...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec && python3...
The model trace is clear: t1 adds F_SEAL_WRITE (OK), then t2 maps PROT_READ|MAP_SHARED via the O_RDWR fd and the model returns EPERM, violating `ReadOnlyAdmissionCompatibility`. Now let me audit the cited source code.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-1/worktree/kernel/core/...
This worktree has TLA-trace instrumentation added on top of the base commit. Let me check what's modified, then read the other cited sites.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
The instrumentation wraps the base logic without changing it. Now let me read the base (uninstrumented) versions of the cited sites. Let me look at the pristine commit versions.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Now let me see how `perms` and `may_perms` are computed at the start of the mmap entry path.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Now I understand the mmap entry path. `may_perms` starts as ALL_MAY_PERMS and only loses MAY_WRITE for a non-writable fd. Let me read the `MappedVmo::new` and the writable-mapping accounting code.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
The accounting mechanism is now clear. Let me fetch the actual Linux v6.16.5 source that the code references, to pin down expected behavior (`mm/memfd.c` and the `seal_check_write` helper).
using fetch_content
using get_search_content
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
running head -5 /tmp/linux_memfd.c && echo === && grep -n "memfd_create" /tmp/linux_memfd.c | head -3
running cd /tmp && rm -f linux_memfd.c linux_fs.h && curl -sL "https://raw.githubusercontent.com/torvalds/linux/v6.16.5/mm/memfd.c" -o linux_memfd.c 2>/dev/null; hea...
running cd /tmp && curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/mm/memfd.c?h=v6.16.5" -o linux_memfd.c && head -3 linux_memfd.c &...
running cd /tmp && grep -n "F_SEAL_WRITE" linux_memfd.c | head -20 && echo ================= && sed -n '150,330p' linux_memfd.c
running cd /tmp && grep -n "seal_check_write" -B5 -A60 linux_fs.h | head -100
running cd /tmp && grep -rn "seal_check_write\|seal_check_future_write" linux_memfd.c; grep -n "mapping_deny_writable\|mapping_map_writable\|i_mmap_writable" linux_f...
running cd /tmp && sed -n '590,640p' linux_fs.h && echo ============ && sed -n '320,400p' linux_memfd.c
Now I have Linux's exact semantics. Let me verify where Linux wires `memfd_check_seals_mmap` and where `mapping_map_writable` is incremented, to confirm the ordering (seal check clears MAYWRITE *before* the writable count is taken).
running cd /tmp && curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/mm/shmem.c?h=v6.16.5" -o linux_shmem.c && grep -n "memfd_check_se...
running cd /tmp && sed -n '2951,2985p' linux_shmem.c && echo ===== && curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/mm/mmap.c?h=v6...
running cd /tmp && sed -n '2660,2700p' linux_mm_vma.c && echo ===MMAP=== && grep -n "memfd_check_seals_mmap\|check_seals" linux_mm_mmap.c | head
running cd /tmp && sed -n '470,510p' linux_mm_mmap.c && echo ==== && grep -n "is_shared_maywrite" linux_mm_vma.c linux_fs.h | head -5
Linux v6.16.5 semantics confirmed: `memfd_check_seals_mmap` (which clears VM_MAYWRITE for read-only shared mappings of sealed files) runs in `do_mmap` BEFORE `mmap_region`'s `mapping_map_writable` accounting, which is gated on `is_shared_maywrite(vm_flags)` — i.e., the accounting decision uses the *post*-seal-check flags. Now let me check `is_shared_maywrite` and then do the developer-knowledge / known-status search.
running cd /tmp && grep -rn "is_shared_maywrite" linux_fs.h linux_mm_vma.c | head -3; grep -n "is_shared_maywrite" -A5 linux_fs.h | head -12; echo ===; grep -n "vma_...
running cd /tmp && curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/include/linux/mm.h?h=v6.16.5" -o linux_mm.h && grep -n "is_shared...
Now Phase 1 Step 2: developer-knowledge search. Git history on the cited sites first.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
adapter error: Connection error.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
The mechanism is now fully traced through history: `d1506171d` introduced writable-mapping counting ("shared mappings that may include the PROT_WRITE permission"), then `6ba1a84ae` inserted the seal check inside the same condition while keeping `is_writable_tracked = true` from the pre-check may_perms. Let me check existing tests and search the upstream tracker (Step 2/3).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Now Step 2/3: issue-tracker search. Let me search the Asterinas GitHub tracker for this exact mechanism (and check what "AST-73" refers to).
using web_search
Key finds: Asterinas PR #2408 introduced this mechanism, and notably Linux itself had and fixed this exact defect (kernel bugzilla 217238, fixed so read-only shared mappings of write-sealed memfds are allowed — current v6.16.5 behavior as cited by the Asterinas code comments). Let me search the Asterinas issue tracker directly via `gh` for a report of this exact defect.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
running cd /tmp && gh search issues --repo asterinas/asterinas "memfd seal" --limit 30 --state all --json number,title,state,url 2>/dev/null | python3 -m json.tool |...
running cd /tmp && gh search issues --repo asterinas/asterinas "memfd" --limit 50 --state all --json number,title,state,url 2>&1 | head -100
running cd /tmp && gh search issues --repo asterinas/asterinas --include-prs "memfd" --limit 50 --json number,title,state,isPullRequest,url 2>&1 | python3 -c " impor...
running cd /tmp && gh search issues --repo asterinas/asterinas --include-prs "seal" --limit 50 --json number,title,state,isPullRequest,url,updatedAt 2>&1 | python3 -...
PR #3481 "Fix inode append and memfd seal races" (open, updated recently) looks highly relevant. Let me inspect it.
running cd /tmp && gh pr view 3481 --repo asterinas/asterinas --json number,title,state,body,files,commits,url 2>&1 | python3 -c " import json,sys d=json.load(sys.st...
PR #3481 is about TOCTOU in append/resize/fallocate seal checks — a different mechanism at different sites, not MC-1. Let me check the upstream code state today (fix landed?) and the local persistent-findings registry, plus targeted issue searches.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
running cd /tmp && gh api repos/asterinas/asterinas/contents/kernel/core/src/vm/vmar/vmar_impls/map.rs?ref=main --jq '.content' 2>/dev/null | base64 -d > /tmp/upstre...
Upstream `main` still has the identical logic — unfixed. Now let me query the persistent-findings registry for the "AST-73" reference mentioned in the finding.
running which specula; cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls .specula-ou...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && cat .specula-output/persisten...
No persistent-findings registry (`previous: null`, no inherited records), so "AST-73" is not in this run's registry. Let me look at the harness evidence directory — the run's own shared Asterinas/Linux comparison infrastructure (not a per-finding file).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && ls -l...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat r...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && grep...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/src/scenarios.c
The harness scenario file itself documents both manifestations — and asserts *different* outcomes for the instrumented Asterinas build (EPERM/EBUSY) vs the reference build (success). Let me check the shared evidence directory for the TV-1/AST-73 provenance (pre-run brief evidence, not per-finding files).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && ls -...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && grep...
`AST-73` appears in the brief (modeling-brief.md) — my task's input document, which the finding cites as "the brief's TV-1 lead". Let me read that section for provenance.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output && grep -n "AST-...
running cd /home/chin39/Documents/play/Specula && ls runs/ 2>/dev/null | head; find . -maxdepth 2 -iname "*catalog*" 2>/dev/null | head; grep -rln "AST-73" --include...
running cd /home/chin39/Documents/play/Specula && grep -rln "AST-73" runs/ datasets/ 2>/dev/null | grep -v "20261003T094028Z" | head -10; ls datasets 2>/dev/null | head
running cd /home/chin39/Documents/play/Specula && ls; grep -rln "AST-73" . 2>/dev/null | grep -v "20261003T094028Z" | head -10
running cd /home/chin39/Documents/play/Specula && ls runs/ | grep -i "asterinas-memfd\|memfd" | head; grep -rn "AST-73" runs/*/README.md runs/*/*.md 2>/dev/null | gr...
running cd /home/chin39/Documents/play/Specula/runs && for d in $(ls -d */ | head -60); do if grep -rql "AST-73" "$d" 2>/dev/null; then echo "$d"; fi; done 2>/dev/nu...
running cd /home/chin39/Documents/play/Specula/runs && ls -la latest/ && grep -rln "AST-73" latest/ 2>/dev/null | head -5; readlink latest 2>/dev/null
`latest` is just the current run symlink. The brief's "cross-run catalog" reference (AST-73) isn't a file I can cite directly — let me check the dry-run predecessors and the #2407/#2408 archaeology for the catalog, then check the harness logs for the actual recorded Asterinas behavior.
running cd /home/chin39/Documents/play/Specula/runs && ls -d asterinas-memfd-analysis-20261003T094028Z-dryrun* 2>/dev/null; grep -rln "AST-73" asterinas-memfd-analys...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && ls *...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence/github...
Developer intent found. Let me see PR #2444 (which implemented the MAY_WRITE distinction per issue #2407) to complete the timeline.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence/github...
The review discussion confirms intent ("only shared may_write mappings are counted"). Let me find the origin of the "AST-73" cross-run catalog ID — checking prior Specula runs for a findings catalog.
running cd /home/chin39/Documents/play/Specula/runs && grep -rl "AST-7[0-9]" --include="*.json" --include="*.md" . 2>/dev/null | grep -v "20261003T094028Z/asterinas-...
running cd /home/chin39/Documents/play/Specula && grep -rn "AST-73\|AST-75" modeling* docs/ src/ specula/ scripts/ 2>/dev/null | grep -v runs/ | head; grep -rln "cro...
The catalog is referenced only by the brief itself. Now let me understand how to build/run the kernel for Phase 2 — reading the harness infrastructure.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat s...
The harness ran real kernels in Docker+KVM and recorded the divergence (Asterinas 426 assertions vs Linux 427). Now let me check what build artifacts exist for reuse, per the Phase-2 reuse policy, and verify Docker works.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls source 2>/dev/null | head...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && git log --oneline -1 &...
Same commit, same instrumentation. Let me check for reusable kernel build artifacts and the OSDK scheme.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && git diff OSDK.toml | h...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && find . -maxdepth 4 -pa...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls -la source/target/osdk/ast...
The harness completed a fresh run very recently (guest exit 0). Let me extract the recorded Asterinas behavior for the tv1a/tv1b admission scenarios from the guest log.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && grep...
The recorded trace shows the exact mechanism on the real kernel. Let me extract tv1b too.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && awk '...
Harness evidence recorded both manifestations on the real kernels. Now Phase 2: I'll write my own independent reproduction test. Let me first check the harness's init.c and the guest exit mechanism.
using TaskUpdate
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat s...
Now let me write the reproduction test. First, a quick look at build timings and the test framework header the harness used.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && grep...
Now I'll write the reproduction test — self-contained, public-API only (Level 0), dual-use (guest init and host binary).
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugMC-1_seal_readonly_admiss...
Test written. First, the Linux reference run on the host (kernel 7.2.8 — same as the harness reference), then the Asterinas guest run.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && which g...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && timeout...
Host lacks static libc (NixOS). Dynamic build for the host reference run; static build will happen in the container for the guest.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && timeout...
Linux reference run: zero deviations, exactly the expected Linux behavior. Now let me verify the instrumentation is inert without the prctl control op (my test doesn't use it), then build the guest run script.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && git diff kernel/core/s...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && sed -n '1,80p' kernel/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && sed -n '380,475p' kern...
Instrumentation is inert without the prctl control (gated by `b.enabled`). Now the guest run script:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugMC-1_asterinas_run.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && chmod +...
The repro dir wasn't found inside the container. Let me debug the mount/path.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls -d .specula-output/repro &...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && docker run --rm -v "$PWD:/wor...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && docker rm -f mc1-dbg >/dev/nu...
Found it — my path resolution went one level too high (`../../..` instead of `../..`), mounting the wrong directory. Fixing:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugMC-1_asterinas_run.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && timeout...
**REPRODUCED on the real Asterinas kernel** — both manifestations, Level 0, deterministic, via public APIs only. The Linux reference run of the same test shows zero deviations. Let me close the rigor loop: confirm the instrumentation didn't alter the accounting logic in the remaining two cited files (compare worktree vs pristine base).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Instrumentation is logic-neutral (same atomic updates, same errno mapping). Both files confirmed. Let me run final targeted tracker searches to solidify the novelty determination, then write the investigation record.
running cd /tmp && gh search issues --repo asterinas/asterinas --include-prs "read-only mmap EPERM" --limit 10 --json number,title,state 2>/dev/null | python3 -c "im...
No upstream tracker report exists. Now let me write the Phase 1 investigation record.
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-1/investigation.md
Now the persistent-findings record. First save the Linux reference output to a log, then get exact line numbers for dependency spans.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && timeout...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Writing the persistent-findings proposal (`issue.json`) per the skill's format:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-1/issue.json
Let me validate issue.json's boundary lines against the actual source tree (the pipeline's `source/` dir).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && python3 - <<'EOF' import json...
Two span entries need fixing. Let me check the actual instrumented `deny()` in the source tree:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source && sed -n '1193,1290p' ke...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-1/issue.json
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && python3 - <<'EOF' import json...
All spans validate. Let me verify the finding's cited line numbers against the pristine base commit for accurate reporting:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
All four cited line numbers are exact in the pristine commit. Final check of the captured guest log:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && grep -c...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugMC-1_asterinas_run.log
Everything is complete and verified. Finalizing.
using TaskUpdate
# MC-1 Confirmation — Post-seal read-only mappings retain writable accounting

- **Source**: MC (real counterexample: `spec/output/validation/MC_hunt_scenario1.out`, invariant `ReadOnlyAdmissionCompatibility` violated, config `MC_hunt_scenario1.cfg`)
- **Novelty**: KNOWN (cite: AST-73 — prior Specula cross-run dataset entry for the same mechanism at the same site, recorded as the brief's TV-1 lead "Post-seal READ shared admission retains writable tracking: WRITE causes EPERM; FUTURE_WRITE can cause false EBUSY. … already tracked as AST-73"; fix-status: unfixed — verified today that upstream `main` still contains the identical `is_writable_tracked` block; tracker search of asterinas/asterinas issues+PRs, open and closed, finds no public report of this mechanism — PR #3481 concerns write-path TOCTOU races, a different mechanism. The introducing PR is asterinas/asterinas#2408, merged 2025-11)
- **Location**: kernel/core/src/vm/vmar/vmar_impls/map.rs:337 (decision site; supporting sites: kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80, kernel/core/src/vm/vmar/vm_mapping.rs:944, kernel/core/src/vm/page_cache/vmo/mod.rs:1199)

## Description

`VmarMapOptions::build` decides whether a mapping takes writable-mapping ownership (`is_writable_tracked`) from the fd-derived `may_perms` — an O_RDWR memfd handle keeps `MAY_WRITE` — *before* `MemfdInode::check_writable` strips `MAY_WRITE` for sealed inodes (kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80, matching Linux v6.16.5 mm/memfd.c `check_write_seal`, which clears `VM_MAYWRITE`). Once the condition holds, the code sets `is_writable_tracked = true` unconditionally, and `MappedVmo::new` (kernel/core/src/vm/vmar/vm_mapping.rs:944) acquires writable ownership via `WritableMappingStatus::map()` (kernel/core/src/vm/page_cache/vmo/mod.rs:1199). Linux decides the writable count from the **post-seal-check** flags (`memfd_check_seals_mmap` runs in `do_mmap` before `mmap_region`'s `is_shared_maywrite` accounting); Asterinas decides it from the pre-check flags and never reconsiders. Two deterministic consequences: (A) after `F_SEAL_WRITE` (counter = −1), a read-only shared mmap through the writable handle fails with EPERM even though `check_writable` returned Ok and stripped MAY_WRITE; (B) after `F_SEAL_FUTURE_WRITE` (no `deny()` call), the same mmap succeeds but increments the counter, so a later `F_ADD_SEALS(F_SEAL_WRITE)` falsely fails with EBUSY although no mapping holds write eligibility. Both are Linux-compatibility violations of the man-page contract that PR #2408 itself quotes ("shared, *writable* memory-mappings … fail with EPERM"; EBUSY only "if any writable, shared mapping exists").

## Trigger scenario

Case A — exactly the MC counterexample steps (t1/t2 serialized): `memfd_create("…", MFD_ALLOW_SEALING)` → O_RDWR fd; `fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)` → OK (counter denies writable mappings); `mmap(NULL, len, PROT_READ, MAP_SHARED, fd)` → **EPERM** (Linux: returns a valid mapping). Control: the same mmap through an O_RDONLY handle (via `/proc/self/fd`) succeeds on both kernels, isolating the bug to the writable-handle accounting decision.

Case B — second manifestation, one cause: `fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE)` → OK; `mmap(PROT_READ, MAP_SHARED, fd)` → OK; `mprotect(PROT_READ|PROT_WRITE)` → EACCES on both (MAY_WRITE was stripped — the mapping is semantically read-only); `fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)` → **EBUSY** (Linux: OK — no writable mapping exists); `munmap` → `F_ADD_SEALS(F_SEAL_WRITE)` retry → OK on both, confirming the read-only mapping itself held the false writable count.

## Developer intent investigation

Commit history: `d1506171d` defined "writable mappings" as "shared mappings that **may include** the `PROT_WRITE` permission" — correct at a time when `may_perms` never changed after the fd check. `6ba1a84ae` (PR #2408) inserted `check_writable` inside the same condition but kept `is_writable_tracked = true` from the pre-check value. PR #2408's description and review state the counting must cover only "shared VMAs with the `VM_MAYWRITE` flag set" / "only shared may_write mappings are counted" — the implemented post-seal-read-only accounting contradicts the PR's own written semantics, since after `check_writable` strips MAY_WRITE the mapping can no longer include PROT_WRITE. `may_perms` itself was introduced by PR #2444 (fixing issue #2407). No comment/TODO acknowledges the divergence; no test in the repo covers post-seal read-only shared mmap through a writable handle (gVisor memfd cases enabled by `291c42c9f` don't cover this ordering; LTP memfd cases are blocklisted). Corroborating intent: Linux itself exhibited this exact wrong behavior (kernel.org bugzilla 217238, "Creating shared read-only map is denied after add write seal to a memfd") and fixed it; the Asterinas comments cite Linux v6.16.5, where the read-only mapping succeeds — so the Linux-compatible outcome is the established contract, not a gray area. Full record: `confirmation/MC-1/investigation.md`.

## Reproduction result

Test: `repro/test_bugMC-1_seal_readonly_admission.c` (self-contained, public APIs only); guest runner `repro/test_bugMC-1_asterinas_run.sh` (builds the test statically, boots the Asterinas kernel — QEMU/KVM, Docker `asterinas/dev:0.18.1-20260926`, kernel built at source commit 0c60537098f4c2949ad2d382aaf499de72263d76; trace instrumentation verified logic-identical to the pristine base in every cited file) — logs: `repro/test_bugMC-1_asterinas_run.log`, `repro/test_bugMC-1_linux_ref_run.log`.

Escalation ladder: **Level 0 alone triggered the live harm** — pure syscall sequence, single-threaded, deterministic, no failpoints, no state injection, no source patch (Levels 1–3 not needed). The trigger's pre-state is constructed by the test itself through the real API and matches the CE steps exactly.

Asterinas guest (captured serial output, exit status 2):

```
[kernel] running /init as the init process
Case A: F_SEAL_WRITE then read-only shared mmap via the O_RDWR memfd handle (the MC-1 trace)
  F_ADD_SEALS(F_SEAL_WRITE)          -> ret=0           errno=0    (ok)  expected: success
  mmap(PROT_READ, MAP_SHARED)        -> ret=-1          errno=1    (Operation not permitted)  expected: success
  ^^ MC-1 VIOLATION at "mmap(PROT_READ, MAP_SHARED)": Linux allows this operation, Asterinas deviates.
  mmap(PROT_READ, O_RDONLY fd) [control] -> ret=140737471549440 errno=0    (ok)  expected: success
Case B: F_SEAL_FUTURE_WRITE, read-only shared mmap, then F_ADD_SEALS(F_SEAL_WRITE)
  F_ADD_SEALS(F_SEAL_FUTURE_WRITE)   -> ret=0           errno=0    (ok)  expected: success
  mmap(PROT_READ, MAP_SHARED)        -> ret=140737471549440 errno=0    (ok)  expected: success
  mprotect(PROT_READ|PROT_WRITE)     -> ret=-1          errno=13   (Permission denied)  expected: failure
  F_ADD_SEALS(F_SEAL_WRITE)          -> ret=-1          errno=16   (Device or resource busy)  expected: success
  ^^ MC-1 VIOLATION at "F_ADD_SEALS(F_SEAL_WRITE)": Linux allows this operation, Asterinas deviates.
  F_GET_SEALS                        -> seals=0x10
  munmap                             -> ret=0           errno=0    (ok)  expected: success
  F_ADD_SEALS(F_SEAL_WRITE) retry    -> ret=0           errno=0    (ok)  expected: success
MC-1: REPRODUCED (2 Linux-compat deviation(s) observed)
```

Linux 7.2.8 reference (same test binary, exit status 0): `F_ADD_SEALS(F_SEAL_WRITE)` in Case B returns `ret=0 errno=0 (ok)`, and the Case A mmap returns a valid address — zero deviations ("MC-1: NOT REPRODUCED (all operations Linux-compatible)"). The run's independent harness evidence (guest.log/linux.log, scenarios `tv1a-write-read`/`tv1b-future-read`) records the same divergence on both kernels, and the recorded instrumentation trace matches the mechanism: `MemfdCheckWritable` strips `may: 7 → 5` and returns Ok, `tracked: true`, then `MappedVmoNew` fails EPERM with `counter: -1`.

## REPRODUCED checklist

1. **Level 0 or Level 1 alone?** Yes — Level 0 alone: real public syscalls (`memfd_create`, `fcntl(F_ADD_SEALS/F_GET_SEALS)`, `mmap`, `mprotect`, `munmap`, `open`), normal operations, no timing assistance. Deterministic admission-control logic, reproduced on every run.
2. **Level 2/3 pre-condition injection?** Not used. The pre-state (sealed memfd, empty writable-accounting) is built by the test through the public API and instantiates the exact CE steps: t1 `F_ADD_SEALS{F_SEAL_WRITE}` → OK (plan round 1), t2 `map perms={R}, fd=rw, shared=true` → the states `check_writable → mapped_new → vmar_unlock result=EPERM` of the 14-state counterexample.
3. **Real consumer/caller?** The unmodified userspace caller observes wrong errno values at the syscall boundary: the `mmap(2)` caller receives EPERM (produced at kernel/core/src/vm/vmar/vmar_impls/map.rs:341→355 via vm_mapping.rs:1125 → vmo/mod.rs:1202, base-commit lines 337/944/1199), and the `fcntl(F_ADD_SEALS, F_SEAL_WRITE)` caller receives false EBUSY (produced at memfd.rs:95 → vmo/mod.rs deny(), base memfd.rs:69). Consequence is observed, not argued.
4. **Permanent or masked?** Not masked. Case A's EPERM is the final delivered mmap result — no downstream mechanism repairs it (an O_RDONLY re-open exists as a caller-side workaround but the wrong outcome stands on the syscall as called). Case B's false EBUSY persists for the mapping's entire lifetime — every WRITE-seal attempt fails while the read-only mapping exists; the counter only clears when the caller destroys the mapping (`munmap` is a user action, not a kernel safeguard; my retry-after-munmap step succeeds, proving the false count was held by the read-only mapping). No sync/resend/guard corrects either errno.

## Recommendation

Decide `is_writable_tracked` from the post-seal-check `may_perms`, mirroring Linux's ordering: call `check_writable(perms, &mut may_perms)?` first (it returns EPERM when requested `perms` contain WRITE and strips MAY_WRITE when the inode is sealed), then set `is_writable_tracked = map_mode.is_shared() && may_perms.contains(VmPerms::MAY_WRITE)`. This admits post-seal read-only shared mappings through writable handles (Case A succeeds, MAY_WRITE still stripped so later `mprotect(PROT_WRITE)` fails EACCES) and stops counting them as writable owners (Case B's `F_ADD_SEALS(F_SEAL_WRITE)` then succeeds). The split/fork/unmap/merge increment/decrement paths keyed on `is_writable_tracked` keep their current shape; a regression test covering both orderings should accompany the fix (no existing gVisor/LTP case does).

Artifacts: `repro/test_bugMC-1_seal_readonly_admission.c`, `repro/test_bugMC-1_asterinas_run.sh`, `repro/test_bugMC-1_asterinas_run.log`, `repro/test_bugMC-1_linux_ref_run.log`, `confirmation/MC-1/investigation.md`, `confirmation/MC-1/issue.json`.

---

## Entry 2: Seal-rejected fixed replacement removes the existing mapping

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
running ls /home/chin39/Documents/play/Specula/skills/bug-confirmation/ /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/ 2>/dev/null
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running ls /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/ /home/chin39/Do...
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
I'll follow the bug-confirmation skill: Phase 1 (investigation → `investigation.md`), Phase 2 (reproduction → `repro/test_bugMC-2_*`, executed), then the verdict. First, let me set up context.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/ /home/chi...
The worktree is at the pinned commit with harness instrumentation applied. Let me read the counterexample for this finding and the shared harness infrastructure (not other findings).
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec/output/ &&...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/INSTRUMENTATION.md
The harness has a known-good build+run recipe. Let me study it and its reusable artifacts.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/run.sh
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/src/ /ho...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/src/run...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/src/ini...
running docker --version 2>&1; ls -la /dev/kvm 2>&1; docker image inspect asterinas/dev:0.18.1-20260926 --format '{{.Id}}' 2>&1 | head -3; echo ---; tail -5 /home/ch...
**Phase 1 — Investigation.** Let me start with the cited counterexample (my finding's evidence), then audit the four cited code locations.
running head -120 /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec/outp...
running grep -n "^State [0-9]*:" /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-o...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/spec/output/vali...
The counterexample trace is clear: t1 maps the memfd RW shared (non-fixed, success) → t2 adds F_SEAL_FUTURE_WRITE → t1 issues a **MAP_FIXED** RW shared map of the same fd → the removal loop (`remove_next → split → put_rest → unmap_pt → dispatch → sync → unmap_drop`) completes and **drops the old mapping** (states 20–27), *then* `check_writable` runs (state 29) and fails → EPERM return (state 31) with the old range absent. Now the Phase 1 code audit of the four cited sites.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
The instrumented `build()` confirms the order: `FixedReplace` → `alloc_free_region_exact_truncate` (removal) happens **before** the `memfd_inode.check_writable(perms, ...)?` seal check. Let me read the removal internals in `mod.rs` and the memfd check.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; ls $X | head; echo ===; cat $X/....
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
The mechanism is confirmed at all four cited sites. Now let me verify the syscall-level reachability: how `MAP_FIXED` maps to `FixedReplace`, and how `perms`/`may_perms` flow from `mmap(2)`.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Call chain fully confirmed: `mmap(MAP_SHARED|MAP_FIXED, PROT_WRITE)` with a writable memfd fd → `FixedReplace` → `alloc_free_region_exact_truncate` (completed unmap + TLB flush + owner drop) → then `check_writable` → EPERM, no rollback. Now let me check the shared harness state (what's reusable) and the Linux reference version.
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; cat $X/.specula-output/harness/l...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; python3 -c " import json d=json....
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; python3 -m json.tool $X/.specula...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; cat $X/source/target/osdk/asteri...
running which gcc qemu-system-x86_64 cpio nasm 2>&1; gcc --version 2>/dev/null | head -1
The prebuilt kernel ELF hash **matches** the harness-pinned SHA-256 (`f79d3d45…`), so I can reuse it with verified provenance. Host lacks qemu, but the dev container has it. Let me check what's known-good inside the guest (signal handling, memfd_create syscall).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
`memfd_create` + `F_SEAL_FUTURE_WRITE` + `MFD_ALLOW_SEALING` are all present in Asterinas. Now Phase 1 Step 2 (developer knowledge): git history on the affected sites, nearby comments, and tests.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
No existing test covers seal-rejected fixed replacement; no TODO/FIXME at the site. Now Phase 1 Step 3 (known-status): search the upstream tracker and git history. First check git remotes and upstream history.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
using web_search
The seal feature came from upstream PR #2408; related MM fixes exist but nothing yet matching this exact mechanism. Let me look for "AST-75" specifically (the finding calls this "known TV-2 / AST-75").
using web_search
No public Asterinas issue matches this mechanism (their issues are plain #NNNN; "AST-75" isn't an upstream label). Let me check the persistent-findings context the pipeline provides — that's where a prior dataset entry would be cited.
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; python3 -m json.tool $X/.specula...
No prior dataset entries. Let me check upstream commits after the pinned commit (2026-09-21) touching the affected files — a recently merged fix would make this KNOWN.
using fetch_content
using get_search_content
using fetch_content
using get_search_content
using codemode
using get_search_content
PR #3481 ("Fix inode append and memfd seal races") is memfd-adjacent — let me verify whether it covers this MAP_FIXED replacement mechanism or a different one (write/fallocate races).
using fetch_content
using codemode
using get_search_content
PR #3481 is a different mechanism (append/resize/fallocate TOCTOU, unmerged). No upstream report of THIS mechanism exists. The dataset's own trace-validation corpus recorded the same difference (my finding cites it as "existing full/partial differential traces"). Let me confirm what those TV-2 traces observed — that's shared harness infra cited by this finding.
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; grep -n "tv2\|TV2\|TV-2\|tv_two\...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; sed -n 120,230p $X/.specula-outp...
The harness's own TV-2 scenario (run on the real kernel) already asserts the differential: after the seal-rejected `MAP_FIXED` replacement, Asterinas `mprotect` → **ENOMEM** (range gone) vs Linux → success. Let me pin down the exact pristine line numbers for the record, then write `investigation.md`.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-...
Phase 1 evidence is complete. Let me check the guest-log format from the known-good run (what serial output looks like), then write `investigation.md` and the repro test.
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; grep -n "tv2\|SPECULA_TEST_EXIT\...
The trace-phase guest log already shows the live differential on the pinned kernel. Phase 1 is complete — writing `investigation.md` now.
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2/investigation.md
Now Phase 2. Let me first confirm how OSDK boots the ELF via qemu for `vmm-direct` (so my direct qemu invocation matches the known-good recipe).
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; grep -rn "vmm-direct\|VmmDirect"...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; ls $X/source/osdk; grep -rln "vm...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; sed -n 250,310p $X/source/osdk/s...
OSDK's `VmmDirect` boot is exactly `qemu … -kernel <elf> -initrd <cpio> -append <kcmdline>`. Now I'll write the reproduction test (Level 0, pure public API).
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugMC-2_seal_rejected_fixed_...
Now the guest init and the container-side runner script:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2/repro/init_mc2.c
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2/repro/run_mc2_repro.sh
Now execute the reproduction (Level 0): Linux reference run + Asterinas guest boot, inside the dev container with the pinned kernel ELF.
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission docker rm -f mc2repro-MC2 >/dev/n...
**Level 0 reproduction SUCCEEDED on the real Asterinas kernel** — after the EPERM-rejected `MAP_FIXED` mmap: `mprotect` → ENOMEM, guarded read → SIGSEGV, and the `F_SEAL_WRITE` add succeeds (old writable owner dropped), while Linux 7.2.8 keeps everything intact. One probe label is off: my `P3` child inherited the parent's SIGSEGV handler (fork inherits handlers), so the child `_exit(139)`'d via my handler instead of dying by signal. Let me fix that probe (reset dispositions in the child) and re-run for an airtight record.
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugMC-2_seal_rejected_fixed_...
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission timeout 900 docker exec mc2repro-...
Clean, decisive re-run: **Linux 7.2.8 = OLD_MAPPING_INTACT (exit 0); Asterinas @ 0c6053709 = OLD_MAPPING_DESTROYED (exit 1)** with all three destruction probes firing and the child consumer killed by SIGSEGV. Let me clean up the container and write the persistent-finding record per the skill.
running docker rm -f mc2repro-MC2 >/dev/null && echo container-removed
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
Now the persistent-finding record. First verify the dependency boundary literals exist verbatim in the build source (the applied tree):
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission; S=$X/source for f in "kernel/cor...
The one-liner's string splitting was unreliable — let me check each literal directly:
running S=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source echo -n "map build: "; gre...
All literals verified unique. Writing the persistent-finding record:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2/issue.json
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission command -v specula >/dev/null 2>&...
The proposal is written for the pipeline to register. Let me extract the verbatim final outputs for the report:
running X=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2...
All artifacts are in place and the reproduction is complete. Here is the confirmation record for MC-2.

---

- **Source**: MC (real counterexample: `spec/output/validation/MC_hunt_TV2.out`, 31 states, invariant `SealRejectedReplacement`, cfg `MC_hunt_TV2.cfg`)
- **Novelty**: KNOWN (cite: dataset `asterinas-memfd-analysis-20261003T094028Z` trace-validation record TV-2 / AST-75 — harness differential traces `tv2-full` & `tv2-partial` in `harness/logs/`, same mechanism at the same site; fix-status: unfixed — no upstream Asterinas issue/PR reports or fixes this mechanism; upstream `map.rs`/`memfd.rs` history has no fix after the pinned commit, and the bug reproduces live at `0c6053709`. Search covered open issues, merged/closed PRs, and commit history; nearest prior art PR #3481 is a write-path TOCTOU, a different mechanism.)
- **Location**: `kernel/core/src/vm/vmar/vmar_impls/map.rs:289` (removal committed in `build()`'s `FixedReplace` arm before the seal check), with `kernel/core/src/vm/vmar/vmar_impls/mod.rs:377` (`alloc_free_region_exact_truncate`), `kernel/core/src/vm/vmar/vm_mapping.rs:830` (`VmMapping::unmap` — completed unmap + TLB flush + owner drop), `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80` (`check_writable` → EPERM)

## Description

`VmarMapOptions::build()` handles `MAP_FIXED` by first committing the replacement of the target range — `alloc_free_region_exact_truncate` detaches intersecting mappings, splits and reinserts non-overlapping survivors, and fully unmaps the covered part (TLB dispatch+sync, `MappedVmo` owner dropped) — and only afterwards runs the memfd admission check `MemfdInode::check_writable`. When an `F_SEAL_FUTURE_WRITE` (or `F_SEAL_WRITE`) seal is active and the request asks `PROT_WRITE` on a shared mapping, that check returns EPERM, which propagates out of `build()` with no rollback. The syscall fails, but the pre-existing mapping is already gone. Linux performs the seal check before touching the address space, so a failed `mmap` leaves the old mapping and its data intact, per the POSIX/Linux contract that a failed `mmap` does not modify the address space. A secondary consequence: dropping the old mapping's writable-owner registration makes `F_ADD_SEALS(F_SEAL_WRITE)` succeed after the failed replacement on Asterinas, while Linux still rejects it with EBUSY.

## Trigger scenario

Exactly the counterexample sequence, via public syscalls in one unprivileged process (no concurrency needed — removal and check are ordered inside one `build()` call):

1. `fd = memfd_create("x", MFD_ALLOW_SEALING)`; `ftruncate(fd, len)` (CE states 2–11: initial RW shared map succeeds, seals empty).
2. `fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE)` → succeeds; `F_SEAL_FUTURE_WRITE` has no writable-mapping precondition (CE states 12–17, seals = {FUTURE}).
3. `mmap(base, len, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_FIXED, fd, 0)` → `MAP_FAILED`, `errno = EPERM` on both systems (CE states 18–29: removal loop `remove_next → split_left → split_right → put_rest → unmap_pt → dispatch → sync → unmap_drop` completes **before** `check_writable` rejects).
4. Divergence after the EPERM return: Linux keeps the mapping; Asterinas leaves a hole (CE state 31 violates `SealRejectedReplacement`).

## Developer intent

No developer commentary acknowledges the ordering. The removal predates memfd sealing (VMAR refactor `4ea3e4978`, mremap work `3f1bf99b2`); the seal check was wired into `build()` after region allocation by `64569ef8f` (2026-08-17) and adjusted by `ac9ce5f01` (2026-09-23). The only comment about removal effects is the rlimit re-check ("Overlapping mappings will be removed. Check again after considering this fact.") — the removal is intended, but nothing addresses failure atomicity. No TODO/FIXME at the sites; no regression test covers seal-rejected fixed replacement (`memfd_access_err.c` tests only `F_SEAL_SEAL` errors; the mmap regression suite has no seal tests). No upstream issue/PR reports it. Falling back to engineering principle: a syscall returning an error must not destroy unrelated user state — the Linux reference behavior and the POSIX mmap error contract both support that the consequence is real, so intent evidence does not neutralize the finding.

## Reproduction result

**Test**: `.specula-output/repro/test_bugMC-2_seal_rejected_fixed_replacement.c` (self-contained C, Level 0 black-box: only `memfd_create`, `ftruncate`, `fcntl`, `mmap`, `mprotect`, `fork`/`waitpid`). Executed twice (second run after fixing the P3 child probe to reset inherited signal dispositions). **Escalation level reached: 0** — pure public API, deterministic, no timing help, no state injection, no source patch. Runner: `.specula-output/confirmation/MC-2/repro/run_mc2_repro.sh` inside `asterinas/dev:0.18.1-20260926` (Docker, `/dev/kvm`), reusing the harness-pinned kernel ELF `source/target/osdk/asterinas/asterinas-osdk-bin.elf` (sha256 `f79d3d45…`, verified against `harness/raw/run.json`; instrumentation is trace-emission only and does not alter the map/seal logic — removal-before-check verified in both pristine and instrumented sources). Command: `docker exec mc2repro-MC2 bash /work/.specula-output/confirmation/MC-2/repro/run_mc2_repro.sh` (outer `timeout 900`). Full logs: `confirmation/MC-2/repro/out/linux.out`, `out/guest.log`, `rerun-full.log`.

**Linux 7.2.8 reference (same binary, exit 0):**
```
mc2[full]: step3 fixed RW SHARED mmap -> MAP_FAILED EPERM (admission rejected, as on Linux)
mc2[full]: P1 mprotect(range, PROT_READ) -> 0 (range still mapped)
mc2[full]: P2 read page 0 -> 0xa0 (no fault)
mc2[full]: P3 child consumer -> read-ok
mc2[full]: P4 F_ADD_SEALS(F_SEAL_WRITE) after rejected replacement -> -1 EBUSY
mc2[partial]: P1 mprotect(range, PROT_READ) -> 0 (range still mapped)
mc2[partial]: P2 read page 1 -> 0xa1 (no fault)
mc2[partial]: P3 child consumer -> read-ok
mc2[partial]: edge page 0 intact (0xa0)
mc2[partial]: edge page 2 intact (0xa2)
MC2-VERDICT: OLD_MAPPING_INTACT
```

**Asterinas @ 0c6053709 (QEMU/KVM guest, exit 1):**
```
mc2[full]: step3 fixed RW SHARED mmap -> MAP_FAILED EPERM (admission rejected, as on Linux)
mc2[full]: P1 mprotect(range, PROT_READ) -> -1 ENOMEM
mc2[full]: P2 read page 0 -> FAULT (SIGSEGV/SIGBUS caught)
mc2[full]: P3 child consumer -> killed-by-fault
mc2[full]: P4 F_ADD_SEALS(F_SEAL_WRITE) after rejected replacement -> success
mc2[partial]: P1 mprotect(range, PROT_READ) -> -1 ENOMEM
mc2[partial]: P2 read page 1 -> FAULT (SIGSEGV/SIGBUS caught)
mc2[partial]: P3 child consumer -> killed-by-fault
mc2[partial]: P4 F_ADD_SEALS(F_SEAL_WRITE) after rejected replacement -> -1 EBUSY
mc2[partial]: edge page 0 intact (0xa0)
mc2[partial]: edge page 2 intact (0xa2)
MC2-VERDICT: OLD_MAPPING_DESTROYED
MC2_INIT_EXIT 1
```

The lines demonstrating the bug are the P1–P3 lines after the EPERM-rejected fixed mmap: `mprotect → ENOMEM`, guarded read → `FAULT`, child consumer → `killed-by-fault`, plus P4 `F_SEAL_WRITE → success` (old owner dropped). Expected (Linux) behavior, shown by the reference run in the same container: mapping and data intact, `F_SEAL_WRITE → EBUSY`. The sequence matches the MC trace action-for-action (initial RW-shared map → FUTURE seal → fixed RW-shared map → removal → EPERM), the violated invariant is the same one MC found (`SealRejectedReplacement`), and the root cause is the cited removal-before-check path; the partial-replacement phase reproduces the counterexample's `split_left`/`split_right` shape exactly (edges survive, covered page destroyed).

## Recommendation

Perform the memfd admission check before committing the `MAP_FIXED` replacement: in `VmarMapOptions::build()`, hoist the `MemfdInode::check_writable(perms, &mut may_perms)` call (and any other fallible per-file admission, e.g. the `mappable()`/device rejection from `ac9ce5f01`) ahead of the `VmarMapOffset::FixedReplace` removal, or defer the actual removal until all fallible checks have passed. Add a regression test asserting that a seal-rejected `MAP_SHARED|MAP_FIXED` mmap leaves the pre-existing mapping readable and `mprotect`-able, for both full and partial overlap (the committed `repro/` test can serve as the template). Upstream, this should be reported to the Asterinas tracker; no upstream report exists yet.

**Artifacts**: `confirmation/MC-2/investigation.md` (Phase 1 evidence), `repro/test_bugMC-2_seal_rejected_fixed_replacement.c`, `confirmation/MC-2/repro/{run_mc2_repro.sh,init_mc2.c,out/linux.out,out/guest.log,rerun-full.log}`, `confirmation/MC-2/issue.json` (persistent-finding record; `specula` CLI not on PATH here, left for the pipeline to register). No repair request drafted (verdict is not `PENDING REPAIR`).

### Pre-REPRODUCED checklist

1. **Level 0 or Level 1 alone?** **Yes.** Level 0 alone triggered it — real public API (`memfd_create`, `ftruncate`, `fcntl`, `mmap`, `mprotect`, `fork`), ordinary operations, deterministic, no timing assistance of any kind.
2. **N/A** — no Level 2 state injection or Level 3 source patch was used; the pre-condition (existing writable shared mapping + active `F_SEAL_FUTURE_WRITE`) is produced entirely by the real-API sequence above, which instantiates the counterexample steps (CE states 2–11 → 12–17 → 18–31).
3. **Real consumer observing a wrong outcome:** the calling process and its forked child. Concretely: a child consumer with default signal dispositions is **killed by SIGSEGV** touching `base` after the parent's mmap returned only an error (`P3 killed-by-fault`, guest.log); the caller's own `mprotect(base, len, PROT_READ)` returns **ENOMEM** for a range it still believes mapped (`P1`); and `fcntl(F_ADD_SEALS, F_SEAL_WRITE)` **succeeds** where Linux returns EBUSY because the kernel dropped the old mapping's writable-owner registration as a side effect of a rejected syscall (`P4`). These are observed syscall outcomes, not argued-only.
4. **Permanent.** No downstream mechanism re-adds or repairs the mapping — the probes all fire after the syscall has returned, and the hole persists until the process re-maps or exits. No masking mechanism exists (verified by code audit: no rollback path in `build()`; and empirically: every destruction probe fired, none was later resolved).

---

## Entry 3: Overlapping FUTURE_WRITE publication may misclassify mapping write eligibility

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
I've read the skill. Now let me explore the work directory and the worktree structure.
using ls
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/ 2>/dev/nu...
Phase 1 begins. Let me audit the cited code first.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
Now the VMO writable-mapping counter (the RMW arbitration surface):
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
Now the mmap admission path in `map.rs`:
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
Now let me find `MappedVmo::new` where the counter `map()` is called:
searching for fn new\(vmo.*is_writable_tracked|is_writable_tracked|fn new\(
Now the mprotect path in `protect.rs`:
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
Let me examine the syscall layer — fcntl, mmap, mprotect — and the perms module to understand how `MAY_WRITE` is granted and preserved:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
Let me trace all callers of `check_writable` and `writable_mapping_status` to map the full arbitration surface:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
The finding's Linux-contract grounding matters. Let me check what the evidence directory has on the Linux v6.16 memfd contract (without touching forbidden findings files):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && ls l...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && sed...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && sed...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mmapping-admission/.specula-output/evidence 2>/dev...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && sed...
The core arbitration surfaces are now mapped. Let me check existing repro artifacts and the harness infrastructure to understand how to run tests on Asterinas:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output && ls harness/ &...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output && sed -n '40,20...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat r...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat s...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running docker images | grep -i "0.18.1-20260926\|dev:0.18" | head -5; echo ===; cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028...
Environment is ready (Docker + dev image present, worktree instrumented). Continuing Phase 1 — the fcntl entry and VmMapping::protect internals:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
Interesting — `protect()` clears the W page flag for non-device mappings. Let me check how write page faults are served for shared VMO mappings (does the fault path consult seals?):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
The structural audit is nearly complete. Now Phase 1 Step 2 — developer knowledge: git history around the seal implementation:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && cat...
PR #3481 "Fix inode append and memfd seal races" is highly relevant to the novelty determination. Let me see the audit's disposition:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence/github...
PR #3481 covers `O_APPEND`/size TOCTOU in write paths — a different mechanism from CR-1's mmap-admission overlap. Let me check the history of the seal-admission code after it landed, and do a live upstream search:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
using web_search
The seal feature came from upstream PR #2408 (issue #2214). Let me check the evidence cache for its discussion, and search the tracker for any existing report of THIS overlap mechanism:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence/github...
using fetch_content: Extract: (1) any discussion of races between F_ADD_SEALS and mmap admission or mprotect, overlap ordering, or "existing eligibility vs new access"; (2) any stated intent about t...
Strong developer-intent evidence. Now a final targeted tracker search (issues + merged/closed PRs) for this exact mechanism:
using mcp
using web_search
Let me do a proper API-based issue search on the upstream repo (issues + PRs, closed included):
running curl -s "https://api.github.com/search/issues?q=repo:asterinas/asterinas+FUTURE_WRITE+in:title,body&per_page=20" | python3 -c " import json,sys d=json.load(s...
using ctx_execute
No prior report of this mechanism exists — Novelty will be NEW if the defect is real. Let me verify the last pieces of the audit: merge/split perm handling and the merge condition:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
The audit is complete. Let me record Phase 1 in `investigation.md`, then prepare reproduction:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output && ls source/ker...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output && ls source/ 2>...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && tail...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/investigation.md
Now Phase 2. First, quick environment reconnaissance from the previous harness run:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && tail...
The environment is validated. Now writing the reproduction test (Phase 2, Level 0 black-box):
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
Let me fix two defects in the file (a stray placeholder call and the platform banner):
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
Compiles cleanly. Running the Linux baseline first (validates the test's own correctness on the reference contract):
running cd /tmp && timeout 300 ./cr1-host-check 2>&1 | tail -45; echo "EXIT=$?"
Linux baseline: invariants hold, no false triggers. Before the guest run, I must check the trace instrumentation's activation — my test does millions of syscalls and the instrumented kernel emits a trace line per syscall:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
The trace buffer is opt-in via a magic prctl (`enabled: false` by default), so my non-tracing test won't flood the serial console. Now I'll build the guest run infrastructure:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/repro-build/init.c
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/repro-build/run-cr1.sh
Now tune iteration volumes for the guest (debug-profile instrumented kernel is slow):
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
Linux baseline is clean. Now launch the guest build+run in the container:
running ls -l /dev/kvm 2>&1; nproc; free -g | head -2; docker ps -a --format '{{.Names}}' | grep -i cr1 || echo "no cr1 containers"
running W=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1...
Mount paths need canonicalization. Let me redo:
running docker rm -f specula-cr1-confirm >/dev/null 2>&1 RUN=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-...
running date -u +%H:%M:%S; docker exec specula-cr1-confirm bash /work/cr1/run-cr1.sh; echo "run-cr1 rc=$?"; date -u +%H:%M:%S
Both runs completed in ~5.5 minutes with exit 0. Extracting the guest log:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
Level 0: no trigger on either kernel, and the racing arms demonstrably crossed the window (both legal outcome buckets populated). Checking guest SMP status, then escalating to Level 1:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
Guest Level 0: clean, window crossed. Now **Level 1 escalation** — timing assistance: burst admission density around publication, continuous re-publication, and split/merge churn via partial mprotect:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
Linux Level-1: clean. Re-running the guest with the Level-1 test:
running date -u +%H:%M:%S; docker exec specula-cr1-confirm bash /work/cr1/run-cr1.sh; echo "run-cr1 rc=$?"; date -u +%H:%M:%S
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
Level 1 needs one design fix: the sealer's `stop` cuts the mapper burst short. Removing it lets post-publication admissions accumulate:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && grep -n...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && sed -n...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-1_future_write_overlap.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
Post-publication buckets now have real volume (14,777 admissions, all correctly refused). Running on the guest:
running date -u +%H:%M:%S; docker exec specula-cr1-confirm bash /work/cr1/run-cr1.sh; echo "run-cr1 rc=$?"; date -u +%H:%M:%S
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
Level 0+1 are exhausted with strong volume: 14,816 post-publication admissions all correctly striped, 52 genuine window crossings, eligibility never lost. Now **Level 3** — a timing-only kernel patch that widens the publication window deterministically:
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
running date -u +%H:%M:%S; docker exec specula-cr1-confirm bash /work/cr1/run-cr1.sh; echo "run-cr1 rc=$?"; date -u +%H:%M:%S
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
Level 3 (kernel-timing patch): still no violation at any harm class. Preserving evidence, then reverting the patch for a final clean Level-0/1 run:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-1/worktree/kernel/core/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running date -u +%H:%M:%S; docker exec specula-cr1-confirm bash /work/cr1/run-cr1.sh; echo "run-cr1 rc=$?"; date -u +%H:%M:%S
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
Final clean run confirms the result. Cleaning up the container and recording Phase 2 in the investigation file:
running docker rm -f specula-cr1-confirm >/dev/null && echo container-removed; cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output && ls -la repro/...
All evidence is preserved and the worktree is restored to its instrumentation baseline. The confirmation is complete — here is the verdict.

---

- **Source**: Code Review (MC hunt `MC_hunt_scenario2.cfg` / `MC_hunt_scenario2_default_seal.cfg` returned no violation; no counterexample exists for this finding)
- **Novelty**: NEW (searched the upstream tracker — issues and PRs, open and closed, via GitHub API `FUTURE_WRITE`, `memfd seal race`, `seal/sealing/memfd in:title` plus the analysis-run 105-open-PR audit; the nearest items are PR #3481 (write-path O_APPEND/size TOCTOU — different mechanism and site), Linux LWN "permit write-sealed memfd read-only shared mappings" (the MC-1 surface), and Linux stable "deny writeable mappings when implying SEAL_EXEC" (intra-syscall ordering inside `memfd_add_seals`). Nothing reports or fixes the FUTURE_WRITE-publication × mmap-admission/mprotect overlap mechanism at this site.)
- **Location**: kernel/core/src/fs/fs_impls/ramfs/memfd.rs:46-89 (publication) × kernel/core/src/vm/vmar/vmar_impls/map.rs:341-355 (admission check)

## Description

CR-1 hypothesized that a `F_ADD_SEALS(F_SEAL_FUTURE_WRITE)` publication overlapping mmap admission or an old mapping's mprotect could (a) let a new mapping acquire forbidden write access, or (b) wrongly strip a pre-existing mapping's retained eligibility. Both harms are structurally excluded by the implementation: the eligibility check (`MemfdInode::check_writable`, memfd.rs:149-180) and the publication (`*seals |= new_seals`, memfd.rs:99-102) execute under the same `seals` mutex, so every admission lands wholly before or wholly after publication — and the finding itself concedes that a mapping whose eligibility was checked before publication legally keeps it ("return order alone is not a violation"). Post-publication admissions get `MAY_WRITE` stripped at admission (memfd.rs:163-165), and mprotect gates only on the mapping's frozen may-bits (`protect.rs:56`, `VmPerms::check` perms.rs:35-44), which no seal-side path ever mutates; `F_SEAL_FUTURE_WRITE` publication touches neither the writable-mapping counter nor any live mapping record, so it can neither grant nor strip capability. The Linux reference has the same overlap by design (lockless `*seals_ptr` read in `memfd_check_seals_mmap`, mm/memfd.c:361-370, vs publication under `inode_lock`) — Asterinas's check side is strictly stronger (under the publication mutex).

## Trigger scenario

Threads racing on one memfd: mapper(s) hammering `mmap(PROT_READ, MAP_SHARED, rw_fd)` + upgrade attempts while sealer(s) publish `F_SEAL_FUTURE_WRITE` (S2/S3/S6a), an old mapping's `mprotect` upgrade/downgrade churn and partial-mprotect split/merge cycles concurrent with the publication (S5/S6b), and combined `WRITE|FUTURE_WRITE` publications against in-flight admissions (S4). Admissions are classified provably pre/post publication via `F_GET_SEALS` observed in the same thread immediately before each mmap (both syscalls take the same seals mutex). A violation would be: a provably post-publication admission upgrading to `PROT_WRITE` (harm a), or a provably pre-publication mapping losing upgrade eligibility (harm b).

## Developer intent

PR #2408 "Support sealing memfd files" (merged 2025-11-04, commits `Add MemfdInode`, `Count writable mappings of each MemfdInode's VMO`, `Support sealing memfd files`) states the design deliberately: *"Since the 'shared maywrite' property of a mapping does not change during its lifetime, it is sufficient to check it only once at the time of mmap. There is no need to recheck it during unmap, split, merge or other operations."* Reviewer lrh2000 forced the mmap check to match Linux F_SEAL_FUTURE_WRITE semantics (*"Please search 'mm: Add an F_SEAL_FUTURE_WRITE seal to memfd' and understand the Linux's behavior first"*), and the counter design mirrors Linux `include/linux/fs.h` writable-mapping counting. No discussion anywhere anticipates or acknowledges an overlap misclassification; no tracker report exists for this mechanism.

## Reproduction result

Test executed at every escalation level, on the Asterinas guest (built from the CR-1 worktree, `cargo osdk build/run --scheme specula_memfd`, KVM) and natively on Linux as the reference baseline. Level 0: no trigger. Level 1 (pinning, swept delays, burst admissions with continuous re-publication, split/merge churn): no trigger — 14,860 post-publication read-only admissions all refused upgrade, 14,903 PROT_WRITE mmaps all EPERM, 48 genuine window crossings all correctly classified. Level 2: no meaningful injection exists (every eligibility state is produced by the real-API sequences the arms already exercise). Level 3 (timing-only kernel patch: 30k-spin delay before `*seals |= new_seals` + 10k-spin delay in `check_writable`; documented, then reverted and the worktree verified restored): no trigger — 14,855/14,937 with widened windows.

Actual guest output (final clean Level-0/1 run, `repro-build/guest-l0l1-final.log`):

```
[S1] pre-publication mapping retains eligibility; post-publication admissions never gain it
  fcntl(F_ADD_SEALS, F_SEAL_FUTURE_WRITE) with live mapping -> ret=0      errno=0(0)
  ok: 200 upgrade/store/downgrade cycles on the pre-seal mapping
  mmap(PROT_READ, MAP_SHARED, rw_fd) post-seal observer    -> ret=0      errno=0(0)
  observer mapping read back: 0x58 (want 0x58)
  ok: post-seal read-only admission refuses upgrade (errno=13)
  mmap(PROT_READ|PROT_WRITE, MAP_SHARED) post-seal         -> ret=-1     errno=Operation not permitted(1)
  write(rw_fd) post-seal                                   -> ret=-1     errno=Operation not permitted(1)
[S2] racing mmap admission vs FUTURE_WRITE publication (2 threads)
  racing window: admitted=140 failed=0 upgraded_ok=133 upgraded_fail=7 (mid-window, both legal)
  post-publication: read-admit-ok=14860 upgrade-eacces=14860 wmmap-eperm=14903
[S3] 4-thread extension: 2 mappers + 2 concurrent sealers (beyond MC bounds)
  racing window: admitted=257 failed=0 upgraded_ok=243 upgraded_fail=14
[S4] combined F_SEAL_WRITE|F_SEAL_FUTURE_WRITE publication
  F_ADD_SEALS(WRITE|FUTURE_WRITE) with upgradable mapping  -> ret=-1     errno=Device or resource busy(16)
  combined-seal rounds: ok=12 ebusy=1 ro-admit-EPERM(MC-1 surface)=4800
[S5] concurrent mprotect churn on pre-seal mappings during publication
  ok: both pre-seal mappings still upgrade after publication+churn (16000 churn iterations)
[S6a] Level-1: burst admissions around publication
  burst window: admitted=559 failed=0 upgraded_ok=532 upgraded_fail=27
[S6b] split/merge churn via partial mprotect vs publication
  ok: pre-seal mapping upgrades after 20000 churn iterations
================ CR-1 summary ================
harm(a) forbidden new write access : none
harm(b) stripped eligibility       : none
torn write state                   : none
control mismatches                 : none
CR1_REPRO: NOTHING (invariants held)
CR1_GUEST_EXIT 0
```

The Linux baselines (host 7.2.8 and container) produce identical invariant outcomes, so the test triggers nothing on the reference kernel either. The only behavioral divergence observed (S4 `ro-admit-EPERM=4800`: read-only shared mmap through the O_RDWR fd rejected after a WRITE seal publishes) is the MC-1 tracking-retention surface — over-rejection of an admission, not a capability misclassification, and explicitly outside this finding's overlap-ordering hypothesis.

## Recommendation

Close CR-1 as not a defect. The check-vs-publication overlap is fully serialized by the `MemfdInode` seals mutex, and eligibility is frozen per-mapping at admission, matching the Linux contract (which itself accepts the same overlap with a weaker, lockless check). No code change is warranted for this mechanism. If the team wants defense-in-depth documentation, a comment at `map.rs:341-355` stating that `check_writable` and `add_seals` deliberately share the seals mutex (so admission eligibility is totally ordered against publication) would prevent future refactors from breaking the invariant — but this is optional hardening, not a fix.

---

## Entry 4: Mapping ownership may not survive split, merge, protection and unmap transitions

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
I've read the skill. Now let me start Phase 1 (Investigation). First, let me look at the worktree structure and the cited code.
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Now let me look at the VMO's `writable_mapping_status` to understand the write-eligibility tracking mechanism.
searching for writable_mapping_status|WritableMappingStatus
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Now let me read the VMAR-level code cited in the finding: `vmar_impls/mod.rs:292-324` and `391-411`, and `page_fault.rs:9-17`.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Let me look at the VMAR-level protect/unmap handlers and the page_fault handler.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
searching for fn protect|fn unmap|fn handle_page_fault
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Let me examine how mappings are created with `is_writable_tracked` and the MAY perms logic.
searching for is_writable_tracked
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Now let me trace the munmap path at the VMAR level.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Let me now read the `VmMapping::handle_page_fault` (vm_mapping.rs:387) to see how write faults are admitted at fault time.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
The auto-mode classifier transiently failed (fails closed) on that read. Let me retry it.
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/worktree/kernel/core/...
I now have a good picture of the core mechanisms. Let me record initial investigation notes, then continue with the remaining files (`remap.rs`, `fork.rs`, `access_alien.rs`) and the struct definition.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
The `clear()` drop-before-revoke ordering is exit/exec-only (out of scope). Now let me do the developer-knowledge search: git history of the tracking mechanism.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
The mechanism was introduced by commit d1506171d and 6ba1a84ae (memfd sealing, Oct-Nov 2025). Now let me search the upstream tracker for known reports on this exact mechanism — including the cited #2917/#2209/#682.
using web_search
Key tracker findings: #2917 (protect unwrap panic on merge) is open upstream but already fixed in this tree via let-else. Now I need the exact Linux semantics for the seal/mmap interaction — the Asterinas code cites Linux v6.16.5. Let me fetch the exact reference code.
using fetch_content: Show the full source code of these functions verbatim: (1) shmem_mmap, (2) shmem_maybe_stamp_hiwater, if present. Also quote verbatim any code involving F_SEAL_WRITE, F_SEAL_FUT...
using fetch_content: Show the full source code of shmem_mmap verbatim, plus any function it calls related to seals (e.g., checks for F_SEAL_WRITE, F_SEAL_FUTURE_WRITE, VM_MAYWRITE). Quote the exact...
I need to see where `memfd_check_seals_mmap` is called and where `i_mmap_writable` is incremented in Linux v6.16.5. Let me fetch `mm/mmap.c` and `mm/memfd.c` more precisely.
using fetch_content: Quote verbatim, if present in this file: (1) the function __vma_link_file in full, especially the part that increments i_mmap_writable (what condition on VM_SHARED / VM_MAYWRITE...
using fetch_content
I have the `do_mmap` part confirming `memfd_check_seals_mmap` strips `VM_MAYWRITE` for read-only shared mappings of write-sealed memfds. Now I need the `i_mmap_writable` increment site (`__vma_link_file`). Let me get the rest of the file.
using get_search_content
The fork path confirms Linux gates the counter on `vma_is_shared_maywrite` (VM_SHARED|VM_MAYWRITE). Let me find the mmap link path and the counter definition.
using get_search_content
Let me verify the Linux header helpers (`vma_is_shared_maywrite`, `mapping_deny_writable`, `mapping_writably_mapped`) to nail the exact Linux counting semantics.
using fetch_content: Quote verbatim all code related to: mapping_writably_mapped, mapping_deny_writable, mapping_allow_writable, i_mmap_writable in this file.
using fetch_content: Quote verbatim the function vma_is_shared_maywrite (or any static inline that tests VM_SHARED and VM_MAYWRITE together) in this file.
running cd /tmp && curl -sL https://raw.githubusercontent.com/torvalds/linux/v6.16/include/linux/fs.h -o fs.h && grep -n -A 12 "mapping_writably_mapped\|mapping_deny...
Let me check where Linux calls `mapping_map_writable` (whether mprotect-upgrade re-checks the counter) — this settles the upgrade semantics comparison.
running cd /tmp && for f in mm/mprotect.c mm/mmap.c mm/mremap.c; do echo "== $f =="; curl -sL "https://raw.githubusercontent.com/torvalds/linux/v6.16/$f" | grep -n -...
running mkdir -p /tmp/linux-refs && cd /tmp/linux-refs && for f in mm/mprotect.c mm/mmap.c mm/mremap.c mm/memfd.c; do curl -sL -o "$(basename $f)" "https://raw.githu...
running cd /tmp/linux-refs && ls -la && grep -n -A6 "mapping_map_writable\|mapping_unmap_writable\|mapping_allow_writable\|vma_is_shared_maywrite\|mapping_deny_writa...
running cd /tmp/linux-refs && grep -n "unsigned long mmap_region" mmap.c; grep -rn "vma_link_file\|__vma_link_file" mmap.c | head; echo ===; curl -sL -o mm.h "https:...
running cd /tmp/linux-refs && grep -n "mmap_region" mmap.c | head -5; echo "=== where is mmap_region defined? Try mm/mmap.c grep or internal.h"; curl -sL -o internal...
Linux semantics fully confirmed: increment iff `VM_SHARED && VM_MAYWRITE` at link, decrement at removal; `check_write_seal` strips `VM_MAYWRITE` for new read-only shared mappings of write-sealed memfds (so those don't count). Now let me check the other two cited issues (#2209, #682).
using web_search
running cd /tmp && curl -sL "https://api.github.com/repos/asterinas/asterinas/issues/2209" -o i2209.json && python3 -c " import json for n in ['i2209']: d = json.loa...
All three cited issues confirmed closed/fixed and none match this finding's mechanism. Now let me look at the worktree's existing memfd tests and build infrastructure to prepare reproduction.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/ 2>/...
running H=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat $H...
The harness directory contains a known-good build/run recipe (Docker + /dev/kvm + the dev image) and already-established Asterinas-vs-Linux behavioral differences (TV-1a, TV-1b, TV-2). Let me examine the run script and the scenarios to reuse this recipe.
running H=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat $H...
running H=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && wc -l...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/src/scenarios.c
This harness corpus already validated some behaviors and preserved known TV-1a/TV-1b/TV-2 divergences. Let me check the build scheme and the environment (Docker, /dev/kvm) to reuse the known-good recipe.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running H=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && cat $H...
Now let me write the Phase-1 investigation record, then proceed to Phase 2 (reproduction).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/investigation.md
Phase 1 recorded. Now Phase 2. First let me understand the run layout (where the harness's source tree lives, what the instrumentation patch touches in OSDK.toml) so I can reuse build artifacts.
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls $R/ && ls $R/source 2>/dev/...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && cd $R/source && git log --onel...
The harness source tree at `$R/source` is identical to my worktree (same commit + same instrumentation), with cached build artifacts. Let me check the built artifacts and verify the instrumentation is observation-only for the counting code.
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && find $R/source/kernel/target -...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls $R/source/kernel/target/ &&...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && ls -la $R/source/ | head -20 &...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && du -sh $R/source/target 2>/dev...
All environment pieces are ready. Now let me write the reproduction test (Phase 2). The test is a deterministic syscall battery over split/merge/protect/unmap transitions with a seal-probe oracle, plus a Level-1 concurrent stress phase — designed to run identically on host Linux (reference) and in the Asterinas guest.
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
The first draft had leftover scratch code. Let me rewrite it cleanly and correctly.
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
Now compile and run the host-Linux reference (Level 0 on the reference system first).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && grep -n...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && gcc -O2...
The host is NixOS without static glibc — the harness compiled the Linux reference inside the dev container. Let me fix the unused warning and compile in the container.
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && REPRO=$R/.specula-output/repro...
Compiled against kernel 7.2.8 (same as the harness's Linux reference). Now run the Linux reference:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && timeout...
The test runs but is unexpectedly slow (stuck in stress rounds). Let me diagnose with strace:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && which s...
Found it: my `pthread_barrier` count is 2 but three threads wait on it (writer, sealer, main) — main deadlocks on the barrier's next generation. Fix:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-2_seal_ownership_lifec...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && R=/home...
Linux 7.2.8 reference: **627/627 checks pass, 0 failures** — my oracle encoding is validated on the reference system. Now for the Asterinas guest run. Let me check the harness build logs for osdk timing first:
running H=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness && head -...
Minor portability hardening for the guest (avoid `usleep`/`gettimeofday`, use `clock_gettime` spin like the harness):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && python3...
Linux reference still 627/627 after the portability patch. Now the Asterinas guest run — script modeled on the harness's proven recipe:
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2/guest-run.sh
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && chmod +x $R/.specula-output/co...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && docker run --rm --device /dev/...
The Asterinas guest run completed with exit 0 and **627/627 checks passed**. Let me do a rigorous line-by-line comparison of the guest log vs the Linux reference:
running CR2=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
The diff comparison got mangled by my shell function. Let me redo the normalization comparison carefully:
running REPRO=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro && CR2=...
The content looks identical — likely CRLF from the serial console. Let me check and strip carriage returns:
running head -c 200 /tmp/ng.txt | od -c | head -5; sed -i 's/\r$//' /tmp/ng.txt && wc -l /tmp/nl.txt /tmp/ng.txt && if diff -u /tmp/nl.txt /tmp/ng.txt > /tmp/cr2_dif...
After stripping CR, the **only** diff is the guest-init marker `SPECULA_TEST_EXIT 0` — the Asterinas guest and Linux reference outputs are line-for-line identical across all 627 checks. Let me capture the L1 outcome distribution and do a second guest run for race-phase stability:
running CR2=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
All 48 L1 rounds ended with a legal seal success (post-unmap), with real concurrent write traffic in 46/48 rounds. Now the second guest run for stability:
running R=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission && docker run --rm --device /dev/...
Both guest runs identical, matching the Linux reference exactly. Phase 2 is complete. Let me record the Phase-2 results in the investigation record:
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation...
Let me get exact line numbers for the final citations and verify key evidence lines:
running W=/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-2...
running rm -f /tmp/norm_linux.txt /tmp/norm_guest.txt /tmp/cr2_strace.txt /tmp/i2209.json /tmp/i682.json /tmp/i2917.json /tmp/cr2_diff.txt /tmp/linux-refs -r 2>/dev/...
All evidence is complete. The final report:

---

# CR-2 Confirmation Report

- **Source**: Code Review (the model-checking run `MC_hunt_scenario3.cfg` returned **no violation** — 32,382 states exhausted to depth 157 — so this is a code-review-sourced hypothesis, not an MC counterexample)
- **Novelty**: NEW (tracker search covered upstream issues *and* recently merged/closed PRs: #2917 protect-merge unwrap panic, #2209 try_merge underflow, #682 stale `Arc<VmMapping>`, PR #2926 mprotect permission validation, PR #2408 memfd sealing — all different defects at nearby code, none reports the transition-lifetime/counter mechanism; searches recorded in `investigation.md`)
- **Location**: kernel/core/src/vm/vmar/vm_mapping.rs:931 (`VmMapping::unmap` — the final-owner release/revocation ordering; audited sites: vm_mapping.rs:754 `split`, 1246 `try_merge`, 966 `protect`, 1208 `MappedVmo::dup_at_offset`, 1222 `Drop for MappedVmo`; vmar_impls/mod.rs:288 `insert_try_merge`, 399 `alloc_free_region_exact_truncate`; page_cache/vmo/mod.rs:1193 `WritableMappingStatus`; vmar_impls/map.rs:341 admission)

## Description

The finding hypothesized that split, merge, protect, and unmap could incorrectly retain or release the `MappedVmo`-counted write eligibility that blocks `F_SEAL_WRITE` — e.g. dropping the final eligible owner before PTE/TLB revocation completes, or leaving a detached owner counted so a later WRITE seal falsely fails with EBUSY. A line-by-line audit shows the counting protocol is conserved exactly by every in-scope transition: `split` moves the original owner to the left piece and dups exactly one owner for the right piece; `try_merge` dups once for the merged mapping and drops both inputs; `protect` only moves the owner (may-bits preserved, matching Linux's `VM_MAYWRITE` persistence); `VmMapping::unmap` drops the owner **strictly after** `cursor.flusher().sync_tlb_flush()`, so a `deny()` that observes count 0 cannot race stale write PTEs; `deny()`/`map()` are atomic RMWs that serialize admission vs. sealing without lock coupling. Eligible and non-eligible mappings can never merge (`try_merge` requires full perms equality including MAY bits, which coincide with tracked-ness). The one drop-before-revoke site (`Vmar::clear`) is reachable only on process exit/exec, which the target brief excludes. The hypothesized defect does not exist.

## Trigger scenario

Attempted via plain user-space syscalls on one 4-page memfd (writable FD, `MAP_SHARED`): partial `munmap` splits, partial `mprotect` splits with re-split and merge-back, two-separately-mmapped-pieces merge, `MAP_FIXED` interior replacement (`alloc_free_region_exact_truncate` + re-admission), protect-across-hole rejection, mixed eligibility (O_RDWR vs O_RDONLY FDs), 24 rounds of deterministic LCG-driven op mixes with an `F_ADD_SEALS(F_SEAL_WRITE)` oracle probed after **every** operation (EBUSY iff ≥1 write-eligible page live; success exactly at the zero crossing), and 48 rounds of a 3-thread race (writer store-loop with SIGSEGV recovery vs. retrying sealer vs. final `munmap`). No scenario produced a false EBUSY (leak), a premature seal success (undercount; the harm probe — upgrade + write through remaining mappings + `pread` the sealed file — never fired), or any divergence from Linux.

## Developer intent

The counter was introduced by commit d1506171d "Count writable mappings of each MemfdInode's VMO" (2025-11-01) together with memfd sealing (6ba1a84ae / PR #2408). Linux v6.16 reference verified from source: `__vma_link_file`/`__remove_shared_vm_struct` increment/decrement iff `VM_SHARED && VM_MAYWRITE`; `memfd_check_seals_mmap`→`check_write_seal` strips `VM_MAYWRITE` for new read-only shared mappings of write-sealed memfds; `mapping_deny_writable` = `atomic_dec_unless_positive`. Asterinas's rule matches Linux's for all in-scope transitions. The known admission-side divergences in this area (TV-1a: post-`F_SEAL_WRITE` read-only mmap EPERM; TV-1b: post-`F_SEAL_FUTURE_WRITE` PROT_READ mapping still counted → false EBUSY on a later WRITE seal; TV-2: rejected `MAP_FIXED` truncation) are admission-time classifications at `vmar_impls/map.rs:341`/`memfd.rs` — different mechanism and site, outside this finding's transition hypothesis, and deliberately excluded from the test by construction. The `Vmar::clear` drop-before-flush ordering (exit/exec-only, `vmar_impls/mod.rs:113-121`) is recorded as an out-of-scope observation for the brief's exclusions.

## Reproduction result

Test: `.specula-output/repro/test_bugCR-2_seal_ownership_lifecycle.c` (executed; Linux reference binary `test_bugCR-2_linux_ref`, guest script `confirmation/CR-2/guest-run.sh`, logs in `confirmation/CR-2/logs/`).

Linux 7.2.8 reference (container `asterinas/dev:0.18.1-20260926`, host kernel):
```
[7.2.8] ok   S1.p3 EBUSY last survivor [3,4): expect EBUSY, got r=-1 errno=16 (Device or resource busy)
[7.2.8] ok   S1.p4 seal succeeds after last piece unmapped: expect seal success, got r=0 errno=0 (0)
[7.2.8] ok   S4.p3 seal must SUCCEED while ineligible [2,4) stays live: expect seal success, got r=0 errno=0 (0)
[7.2.8] ok   L1 round 47: munmap r=0 (17 us), writer issued=423603 landed=423602, seal errno=0 late_retry_ok=-1
[7.2.8] CR2_TOTAL_CHECKS=627 CR2_FAILURES=0
CR2_RESULT: all expectations met on both protocol directions
```

Asterinas guest (QEMU/KVM, 2 vCPU, boot via `cargo osdk run --scheme specula_memfd`, two full runs, both guest-exit 0):
```
[5.13.0] ok   S1.p4 seal succeeds after last piece unmapped: expect seal success, got r=0 errno=0 (0)
[5.13.0] ok   S4.p3 seal must SUCCEED while ineligible [2,4) stays live: expect seal success, got r=0 errno=0 (0)
[5.13.0] ok   L1 round 47: munmap r=0 (166 us), writer issued=1435136 landed=1435135, seal errno=0 late_retry_ok=-1
[5.13.0] CR2_TOTAL_CHECKS=627 CR2_FAILURES=0
CR2_RESULT: all expectations met on both protocol directions
SPECULA_TEST_EXIT 0
```
Normalized serial output of the Asterinas runs is line-for-line identical to the Linux reference across all 627 checks (only diff: the guest init marker). Escalation ladder: Level 0 PASS (deterministic battery + stress, both systems, twice on Asterinas); Level 1 PASS (96 race rounds total across both systems; every round ended legally WRITE-sealed; 46/48 guest rounds carried >1000 concurrent writes racing the unmap — the fine-grained store-vs-deny ordering is instead proven structurally by the code order, since `sync_tlb_flush` precedes the drop in `VmMapping::unmap`); Levels 2/3 not escalated to — nothing failed that timing or injection could widen, the mechanism is a fixed code order rather than a race, and injecting an unreachable counter state would fabricate rather than reproduce a violation.

## Recommendation

Close CR-2 as not a defect for scenario 3: ownership of write eligibility is conserved across all in-scope representation changes, and the final owner is released only after ordinary revocation completes; no code change is warranted in `vm_mapping.rs`/`vmar_impls`. Two follow-ups worth handling elsewhere: (1) the admission-side `F_SEAL_FUTURE_WRITE` classification (TV-1b, `vmar_impls/map.rs:341-355`: `is_writable_tracked` is decided before `check_writable` strips `MAY_WRITE`, so a never-writable mapping still blocks a later `F_SEAL_WRITE` with EBUSY where Linux v6.16 succeeds), and (2) the exit-path `Vmar::clear` dropping owners before the TLB flush (out of scope per the brief, but worth an upstream look for multi-threaded exit racing a sealer in another process).

---

## Entry 5: Failed mprotect prefix and busy seal addition may leave inconsistent observable effects

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-3/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
I've read the skill. Now Phase 1: Investigation. Let me look at the worktree and the cited code.
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/ && ls /home/chi...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-3/investigation.md
running cat "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/C...
A previous attempt crashed mid-run (adapter exited 1). There's partial work: an investigation record and a guest/ directory with reproduction scaffolding. Let me inspect what exists so I can reuse or rebuild on it.
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
The previous attempt built a test named `test_bugCR-3_rejected_op_effects.c` and ran a Linux reference. Let me see what artifacts exist and their outputs.
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro" && ls -la
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
The Linux reference run passed all 22 checks. Let me check the Asterinas guest log and the harness setup to understand the run environment.
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
running ls "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/" && ca...
The previous turn crashed after starting the Asterinas run. The `cr3-asterinas.log` (41KB, written just before the crash) may already contain the guest run. Let me examine it and the harness runner.
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
running cat "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/harness/run.sh"
The previous run actually completed both the Linux reference and the Asterinas guest run — all 22 checks passed on both, with `CR3_TEST_EXIT 0`. But the test source `test_bugCR-3_rejected_op_effects.c` is missing from `repro/`. Let me search for it.
running find "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission" -name "*CR-3*" -o -name "*cr...
running grep -rn "test_bugCR-3" "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-o...
The test source is missing but the binary and full run logs exist. I need to recreate the source and re-execute to have a genuine, self-contained record. Let me check my cwd (the previous agent's workspace) and the container state.
running ls -la "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmatio...
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
The container `specula-memfd-harness-20261003` is still up, and the worktree is built. The prior run executed fully (logs show 22/22 PASS on both Linux and Asterinas) but the test source file vanished. I'll reconstruct the test source faithfully from the executed checks, then re-execute. First, let me extract details from the compiled binary and verify the cited kernel code myself.
running strings "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmati...
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-3/worktree/kernel/core/...
The worktree carries the harness instrumentation on top of upstream logic — the `deny()?` before `*seals |= new_seals` ordering is intact. Now let me verify `protect.rs`:
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-3/worktree/kernel/core/...
Now let me verify the remaining Phase-1 code claims myself (perms.rs `check()`, mmap.rs MAY-bit admission, vmo `deny()`) rather than trusting the record blindly:
reading /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR-3/worktree/kernel/core/...
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
The code audit is verified. Now let me do the prior-report search myself (upstream issues + recently merged/closed PRs) for the Novelty determination:
using web_search
Search confirms no prior report of these mechanisms. Let me also check recent git history on both cited files (recently merged PRs angle):
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
running docker inspect specula-memfd-harness-20261003 --format '{{json .Mounts}}' && docker exec specula-memfd-harness-20261003 ls /work/source/target/osdk/asterinas...
Container is live with `/work` bound to the run dir and the prebuilt kernel ELF present. Let me verify the CR-3 worktree matches `/work/source` (the tree step2 runs), then recreate the test source:
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission" && diff -r --exclude=target --...
The worktree is bit-identical to `/work/source`. I verified all Phase-1 code claims directly; the investigation record is accurate. Now Phase 2. Let me back up the prior-turn log, recreate the missing test source faithfully (from the previous run's binary strings + logged checks + investigation scenarios), and re-execute both steps.
running cp "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
editing /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/repro/test_bugCR-3_rejected_op_effects.c
Now execute step 1 (compile + Linux reference run + repack initramfs) in the container:
running docker exec specula-memfd-harness-20261003 bash /work/.specula-output/confirmation/CR-3/guest/step1_build_and_linux_ref.sh 2>&1 | tail -35
Linux reference: 22/22 PASS, exit 0 — identical to the prior run's log. Now step 2, the Asterinas guest run:
running docker exec specula-memfd-harness-20261003 bash /work/.specula-output/confirmation/CR-3/guest/step2_asterinas_run.sh 2>&1 | tail -40
The Asterinas run completed: 22/22 PASS, `CR3_TEST_EXIT 0`. Let me confirm the run status line and the full clean log, then append the Phase-2 record to the investigation file:
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
The log records 22 PASS lines and no FAIL lines. Let me verify the guest terminated cleanly (power-off after test, not a timeout kill):
running cd "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/CR...
Clean power-off after `CR3_TEST_EXIT 0`. Both executions complete. Let me record the Phase-2 evidence in the investigation file:
running cat >> "/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmatio...
Phase 1 and Phase 2 are complete. The finding's hypothesized mechanisms were exercised at Level 0 on both the Linux reference kernel and the Asterinas guest — all 22 checks pass on both; the code behaves exactly per the Linux contract.

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: kernel/core/src/fs/fs_impls/ramfs/memfd.rs:49-68 (seal publication ordering); kernel/core/src/vm/vmar/vmar_impls/protect.rs:21-77 (per-segment protect loop). CR-3 worktree at commit 0c6053709 + harness instrumentation (bit-identical to the built `/work/source`).

## Description

The finding hypothesizes two deviations in the observable effects of rejected operations: (1) a multi-segment `mprotect` that succeeds on early segments and then fails with EACCES or ENOMEM could "wrongly discard the successful prefix" or "grant permissions beyond a segment's MAY bits"; (2) a busy combined `F_ADD_SEALS(WRITE|FUTURE_WRITE|SEAL)` could publish seal bits despite failing with EBUSY. Neither mechanism exists in the code:

- `MemfdInode::add_seals` (memfd.rs) holds the seals lock, runs all checks first — the `WritableMappingStatus::deny()?` EBUSY path is a conditional atomic update (vmo/mod.rs:1193-1258) that changes **no state** when writable mappings exist (counter > 0) — and publishes via `*seals |= new_seals` strictly after the deny check. A busy combined addition publishes nothing and leaves the deny counter untouched: all-or-nothing, same as Linux `memfd_add_seals`.
- `Vmar::protect` (protect.rs) walks segments in address order and applies each immediately (remove → split → protect → reinsert) before evaluating the next; `new_perms.check()` (perms.rs:39-52) enforces requested-perms ⊆ MAY-bits before every apply. So a later-segment EACCES keeps the applied prefix alive, and no segment can gain more than its MAY bits — precisely the documented Linux contract ("pages before the unmapped hole are still protected", stated verbatim in Asterinas's own doc comment at protect.rs:28).

Bounded model checking found no violation for these arms (MC_hunt_scenario4.cfg: 223 states, depth 68, ProtectionPrefixEffects and RevocationBeforeOwnerRelease passed; SealPublicationAndFreeze passed everywhere), so this is code-review-sourced (the MC run returned no violation). Reproduction contradicts the hypothesis on the live system.

## Trigger scenario

All Level 0, plain public syscalls, single sequential process — deterministic, no timing assistance, no state injection, no source modification:

- **Arm A (EACCES mid-range)**: memfd (4 pages) → A = 2 pages RW `MAP_SHARED` via the writable fd, B = 1 page adjacent mapped read-only via an O_RDONLY handle of the same memfd (`/proc/self/fd`, so B has no MAY_WRITE) → `mprotect(A, 2p, PROT_READ)` OK → `mprotect(A..B, 3p, PROT_READ|PROT_WRITE)` fails EACCES on B. Observables: write A[0] must succeed (prefix not discarded), write B[0] must fault (no over-grant), A alone re-protects to RW while B alone still gets EACCES (MAY admission unchanged).
- **Arm B (ENOMEM prefix)**: C = 3 pages RW → unmap middle page → `mprotect(C, 3p, PROT_READ)` fails ENOMEM. Observables: write C[0] must fault (prefix applied and retained), write C[2] must still succeed (suffix untouched).
- **Arm C (busy combined seal)**: writable shared mapping active → `F_ADD_SEALS(WRITE|FUTURE_WRITE|SEAL)` fails EBUSY. Observables: F_GET_SEALS must be 0 (no partial publication), a second writable shared mmap must be admitted (deny flag not leaked), `write(fd)` must still succeed; after unmapping, the retry must succeed, publish all three bits (0x19), and enforce: new writable mmap → EPERM, `write(fd)` → EPERM.

## Developer intent

- PR #2408 ("Support sealing memfd files", for issue #2214) explicitly discusses the F_SEAL_WRITE EBUSY contract — the all-or-nothing failure contract is deliberate.
- PR #2926 ("Fix permission validation in mprotect and mmap") deliberately added the MAY-bit `VmPerms::check()` enforcement, with the regression test `mprotect_shared_writable_mapping_on_read_only_file` (single-segment case) asserting EACCES.
- protect.rs's own doc comment states the partial-effect contract as intended behavior.
- No TODO/FIXME/known-issue at either site about partial effects or seal publication. Closest prior report, issue #2917, is a different mechanism (unwrap panic on merging, fixed in-tree by c7b633e9b).
- Prior-report search re-run this turn (upstream issues and recently merged/closed PRs): nothing reports this mechanism at this site → Novelty: NEW.

## Reproduction result

Test: `.specula-output/repro/test_bugCR-3_rejected_op_effects.c` (level reached: **Level 0**, which fully triggered every hypothesized failure boundary; Levels 1–3 not needed — nothing racey to widen, no injectable bad pre-state because check-before-publish ordering makes the hypothesized state unreachable, and a source patch would only create the symptom).

Commands (executed this turn in the live harness container `specula-memfd-harness-20261003`):
```
docker exec specula-memfd-harness-20261003 bash /work/.specula-output/confirmation/CR-3/guest/step1_build_and_linux_ref.sh
docker exec specula-memfd-harness-20261003 bash /work/.specula-output/confirmation/CR-3/guest/step2_asterinas_run.sh
```

Linux reference (host kernel 7.2.8 in container) — `linux_ref_exit=0`:
```
CR-3 rejected-operation effects: memfd ready (fd=3, 4 pages)
PASS A0: O_RDONLY memfd handle opened via /proc/self/fd
PASS A1: A (2 pages RW via writable fd) + B (1 page RO via O_RDONLY fd) mapped adjacently
PASS A2: mprotect(A, 2 pages, PROT_READ) succeeded
PASS A3: mprotect(A+B, PROT_READ|PROT_WRITE) failed with Permission denied as expected
PASS A4: prefix preserved: write to A[0] succeeded after the failed mprotect
PASS A5: no over-grant: write to B[0] still faults (PROT_WRITE beyond MAY_WRITE refused)
PASS A6: mprotect(A alone, PROT_READ|PROT_WRITE) succeeded
PASS A7: mprotect(B alone, PROT_READ|PROT_WRITE) failed with Permission denied as expected
PASS B1: C (3 pages RW) mapped
PASS B2: munmap middle page succeeded
PASS B3: mprotect(C with hole, PROT_READ) failed with Cannot allocate memory as expected
PASS B4: prefix protected: write to C[0] faults after the failed mprotect
PASS B5: suffix untouched: write to C[2] still succeeds
PASS C1: writable shared mapping active
PASS C2: F_ADD_SEALS(WRITE|FUTURE_WRITE|SEAL) while writable-mapped failed with Device or resource busy as expected
PASS C3: no partial publication: F_GET_SEALS == 0 after the EBUSY failure
PASS C4: deny flag not leaked: second writable shared mmap admitted
PASS C5: write(fd) still succeeds after the EBUSY failure
PASS C6: F_ADD_SEALS(WRITE|FUTURE_WRITE|SEAL) after munmap succeeded
PASS C7: all bits published after success: F_GET_SEALS == 0x19
PASS C8: new writable shared mmap after sealing failed with Operation not permitted as expected
PASS C9: write(fd) after F_SEAL_WRITE failed with Operation not permitted as expected
CR-3 summary: 22 checks passed, 0 checks failed
```

Asterinas guest (instrumented worktree, scheme `specula_memfd`, vmm-direct; log: `guest/logs/cr3-asterinas.log`) — identical output, `CR-3 summary: 22 checks passed, 0 checks failed` followed by `CR3_TEST_EXIT 0` and a clean guest power-off. (The crashed prior turn's identical log is preserved at `guest/logs/cr3-asterinas.turn01-crash-fragment.log`.)

Every segment the finding worried about shows the Linux-contract behavior on both kernels: A4/B4/B3 prove the rejected mprotect leaves exactly the permitted prefix, A5/A7 prove no over-grant, C3/C4/C5 prove the busy seal addition is fully rolled back, and C6-C9 prove the retry path publishes and enforces correctly. The hypothesized inconsistency is not producible, so no consumer can observe a wrong outcome.

## Recommendation

Close as a false positive; no code change needed. Optionally, lift this test (or the multi-segment prefix assertions A3-A7, which the existing suite lacks — `mprotect_shared_writable_mapping_on_read_only_file` covers only the single-segment case) into `test/initramfs` as regression coverage for the prefix-retention contract, since it is currently only implicit in the doc comment.

---
