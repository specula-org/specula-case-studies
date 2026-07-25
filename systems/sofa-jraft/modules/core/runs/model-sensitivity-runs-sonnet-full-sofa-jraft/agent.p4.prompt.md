# Phase 3A: Trace Validation

You are validating a TLA+ specification against execution traces collected
from the real system implementation.

## Target System

- **Name**: sofa-jraft

## Input from Previous Phases

- Spec files: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/sofa-jraft/spec/ (base.tla, Trace.tla, Trace.cfg)
- Traces: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/sofa-jraft/traces/*.ndjson
- Source code: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/sofa-jraft/artifact/sofa-jraft

## Instructions

Follow the **tla-trace-workflow** skill methodology. Read the skill guide at:
  /home/ubuntu/Specula/.claude/skills/tla-trace-workflow/guide.md

Then read the reference files:
  /home/ubuntu/Specula/.claude/skills/tla-trace-workflow/references/validation.md
  /home/ubuntu/Specula/.claude/skills/tla-trace-workflow/references/debugging.md
  /home/ubuntu/Specula/.claude/skills/tla-trace-workflow/references/fix.md

## Tasks

1. **Validate each trace** — Run `run_trace_validation` on EVERY collected trace
   in /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/sofa-jraft/traces/. Do not skip any trace.
2. **Debug mismatches** — When validation fails, use `run_trace_debugging` to
   identify the root cause (spec bug, trace format issue, or missing action).
3. **Fix the spec** — Edit base.tla and/or Trace.tla to fix mismatches.
   Never weaken validation by removing checks — fix the underlying issue.
4. **Re-validate** — After each fix, re-run validation on ALL traces to ensure
   no regressions. Use `run_trace_validation_parallel` for efficiency.
5. **Iterate** — Repeat steps 2-4 until all traces pass validation.

## Completion Criteria

This phase is complete ONLY when ALL traces in /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/sofa-jraft/traces/
pass validation without errors. Do not proceed until this is achieved.

## Output

- Updated spec files (base.tla, Trace.tla) with fixes applied
- All traces validated successfully
