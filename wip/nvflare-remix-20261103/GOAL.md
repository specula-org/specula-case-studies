# Goal (set 2026-11-03 17:30 UTC, user returns ~01:30 UTC)

Restructure the integrated NVFlare slice model so that coarse and fine variants of **action groups** can be freely mixed, and use the mixes to model-check deep cross-component interactions identified in Phase 1.

Inputs (read-only copies under `inputs/`): Codex's vertical-slice composition (`inputs/vertical-slice`), the three Stage-C seed suites (`inputs/seeds/{job,fedavg,payload}`), Phase 1 v1/v2 outputs (`inputs/phase1`), Phase 1.5 design. Pin `c411a201ead0ec2d4bd0df27fc8b88955c086cfd`. Original Codex workspace `~/nvflare-integrated-model-20261103` is never modified.

## Deliverables

1. `DESIGN.md`: group cut (process x component, refined by Phase 1 hazards: cut where interactions are benign, keep bug-prone mechanisms inside one group), port contract, variant contract, composition rule, interaction-preservation obligation, mix enumeration, trace-validation-per-mix, CE triage (zoom-in) workflow.
2. `spec/`: ports module(s), one module per (group, variant), a mix root whose configuration selects a variant per group, cross-component properties derived from Phase 1.
3. `scripts/`: generator for mix configurations, runners for SANY over all mixes, per-group refinement checks, MC campaign, trace replay.
4. `checks/` + `logs/`: evidence that every mix parses, each fine variant refines its coarse variant on its ports, the real POC trace replays on several mixes, and MC campaign results per Phase-1 scenario.
5. `RESULTS.md`: what works, mix count, campaign results, counterexamples with triage (model artifact vs. candidate bug), limitations, next steps.

## Constraints

- Disk: `/` (and `/tmp`) is full. All TLC metadirs, `TMPDIR`, `java.io.tmpdir` must live under this workspace.
- No external publication. No edits to Codex workspace, Specula repo, or old case studies.
- Evidence levels stay distinct: SANY pass, bounded TLC, trace replay, refinement check, reproduced bug.
