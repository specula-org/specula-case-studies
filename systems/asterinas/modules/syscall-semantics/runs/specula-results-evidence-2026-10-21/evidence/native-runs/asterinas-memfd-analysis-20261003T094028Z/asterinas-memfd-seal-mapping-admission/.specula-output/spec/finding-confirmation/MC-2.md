# MC-2

Status: REPRODUCED
Run: asterinas-memfd-analysis-20261003T094028Z

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
