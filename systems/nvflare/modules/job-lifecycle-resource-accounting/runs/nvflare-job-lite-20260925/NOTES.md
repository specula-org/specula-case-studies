# Progress notes (specula-lite, single agent)

- Target: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/lite/source
- Revision: 53ba7ee567468ea7971dad4faccef13c6cb35dc2 (clean worktree at start; branch HEAD detached)
- Python: /home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/nvflare-venv/bin/python3 (3.12.3)
- Java: /usr/lib/jvm/java-21-openjdk-amd64/bin/java; tla2tools 1.8.0; CommunityModules 202505152026
- Guides: /home/experiment/.cache/specula-lite/shared-1f3239446e3863655afde798b4a8ebc269c8f02cc8863dc637e80bc5b17eaf57/skills
- SKILL_DIR: /home/experiment/.claude-specula-lite-20260925/skills/specula-lite
- Resource ceilings: TLC heap+direct <= 64 GiB aggregate, <= 16 TLC workers total; 80 GiB/16 CPU service

## Phase log
- [x] Prepare (prepare.py OK)
- [ ] Code analysis -> modeling-brief.md
- [ ] Spec generation
- [ ] TLC checking
- [ ] Reproduction
- [ ] Report
- [x] Code analysis -> modeling-brief.md (2026-09-25). Key candidates: MC-1 lost abort (runner overwrites FINISHED_ABORTED),
      MC-2 runner thread crash on job deletion during scheduling/deploy, MC-3 reservation leaks, MC-4 completion/start overlap.
- History: only commit messages + trees available (old blobs missing via alternates). No GitHub lookups (pilot rules).
- Modeling plan: two focused models: models/lifecycle (server lifecycle, S1/S2/S4) and models/resources (client resources, S3/S5).
- Repro plan: POC via `python3 -m nvflare.cli poc ...` (nvflare CLI script not installed; PYTHONPATH points to this source).
- [x] Lifecycle model: MC-1 (hunt_abort*), MC-2 (hunt_delete*), MC-4a (mc_2), MC-4b (hunt_overlap_3) counterexamples;
      clean runs under explicit timing assumptions (see models/lifecycle/changelog.md).
- [x] Resource model: mc_1 clean (12.5M states); leftover-reservation diagnostics (by design, expiry-bounded).
- [x] POC repro env: repro/env.sh (HOME, NVFLARE_POC_WORKSPACE, port 28402, job store in poc_ws).
- [x] MC-1 REPRODUCED Level 0: logs/bug1_deploy_L0_run1.* (3/3), logs/bug1_dispatched_L0_run1.* (5/5).
- [x] MC-2 REPRODUCED Level 0: logs/bug2_delete_L0_run1.* (+ logs/server_poc_console_after_bug2.log); POC restarted.
- [ ] Next: MC-4a Level 3 (sleep before job_runner.py:711 in a source COPY), T-1 GPU leftover reservation repro,
      CR-3 GPU expiration validation, CR-4, MC-4b analysis, report.
- [x] MC-4a REPRODUCED (Level 3 timing), zombie RUNNING persists across restart and breaks `poc stop` (exit 5).
- [x] T-1 REPRODUCED Level 0 (bug4 run2); run1 = config env-limit (GPUResourceConsumer on GPU-less host).
- [x] Q2 partial START cleanup verified clean (q2_partial_start_L0_run1.json).
- [x] MC-2(a) scan race REPRODUCED Level 0 (bug2b_scanrace_L0_run1.json).
- [x] MC-4b REPRODUCED Level 3; CR-4 REPRODUCED Level 3 (benign status/message); CR-3/CR-2 unit checks.
- [x] POC stopped; product source unchanged (git status: only .specula-lite untracked).
- [x] report.md written (report.md); investigation complete.
