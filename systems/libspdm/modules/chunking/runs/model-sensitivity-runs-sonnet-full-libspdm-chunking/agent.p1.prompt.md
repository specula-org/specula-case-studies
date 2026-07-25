# Phase 1: Code Analysis

You are performing code analysis for formal verification of a system implementation.

## Target System

- **Name**: libspdm-chunking
- **GitHub**: DMTF/libspdm
- **Language**: C
- **Reference Algorithm**: SPDM large-message chunking / reassembly
- **Source Code**: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-chunking/artifact/libspdm

## Instructions

Follow the **code-analysis** skill methodology. Read the skill guide at:
  /home/ubuntu/Specula/.claude/skills/code_analysis/guide.md

Then read the reference files as needed:
  /home/ubuntu/Specula/.claude/skills/code_analysis/references/bug-archaeology.md
  /home/ubuntu/Specula/.claude/skills/code_analysis/references/deep-analysis.md
  /home/ubuntu/Specula/.claude/skills/code_analysis/references/modeling-brief-format.md

Example: /home/ubuntu/Specula/.claude/skills/code_analysis/examples/hashicorp-raft-modeling-brief.md

## Phases

Execute all 4 sub-phases in order:

1. **Reconnaissance** — Map codebase structure, core modules, concurrency model
2. **Bug Archaeology** — Mine git history and GitHub issues/PRs for historical bugs
3. **Deep Analysis** — Systematic code reading for inconsistencies and deviations
4. **Modeling Brief** — Synthesize findings into bug families

## Output

Write your modeling brief to: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-chunking/modeling-brief.md`

This file will be used by the next phase (spec generation) as the primary input.
Focus on identifying **bug families** — groups of potential bugs that share
a common mechanism and can be targeted by the same TLA+ invariants.
