# Phase 2: TLA+ Spec Generation

You are generating TLA+ specifications based on a completed code analysis.

## Target System

- **Name**: libspdm-version-cap-algo
- **Language**: C
- **Reference Algorithm**: SPDM VERSION / CAPABILITIES / NEGOTIATE_ALGORITHMS
- **Source Code**: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-version-cap-algo/artifact/libspdm

## Input from Phase 1

Read the modeling brief produced by the previous phase:
  /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-version-cap-algo/modeling-brief.md

This brief contains bug families, system architecture, and modeling scope.

## Instructions

Follow the **spec-generation** skill methodology. Read the skill guide at:
  /home/ubuntu/Specula/.claude/skills/spec_generation/guide.md

Then read the reference files:
  /home/ubuntu/Specula/.claude/skills/spec_generation/references/base-spec-methodology.md
  /home/ubuntu/Specula/.claude/skills/spec_generation/references/mc-spec-pattern.md
  /home/ubuntu/Specula/.claude/skills/spec_generation/references/trace-spec-pattern.md
  /home/ubuntu/Specula/.claude/skills/spec_generation/references/instrumentation-spec-format.md

## Output

Write all files to: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-version-cap-algo/spec/

1. `base.tla` + `base.cfg` — Core spec with bug-family driven extensions
2. `MC.tla` + `MC.cfg` — Model checking wrapper with counter-bounded fault injection
3. `Trace.tla` + `Trace.cfg` — Trace validation wrapper
4. `instrumentation-spec.md` — Action-to-code mapping for harness generation

Also generate bug-family-specific hunting configs: `MC_hunt_*.cfg`
