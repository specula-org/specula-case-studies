# Phase 2.5: Harness Generation

You are instrumenting a system's source code to collect execution traces
for TLA+ trace validation.

## Target System

- **Name**: libspdm-secured-message
- **Language**: C
- **Source Code**: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/artifact/libspdm

## Input from Previous Phases

- Instrumentation spec: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/spec/instrumentation-spec.md
- Trace spec: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/spec/Trace.tla
- Base spec: /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/spec/base.tla

Read the instrumentation spec to understand which code locations to instrument
and what trace events to emit.

## Instructions

Follow the **harness-generation** skill methodology. Read the skill guide at:
  /home/ubuntu/Specula/.claude/skills/harness-generation/guide.md

## Tasks

1. **Instrument the source code** — Add NDJSON trace event emissions at the
   code locations specified in instrumentation-spec.md. Patch the real source
   code, do NOT write a standalone simulation.
2. **Write test scenarios** — Create tests that exercise the protocol code paths
   relevant to each bug family.
3. **Collect traces** — Run the instrumented tests and save NDJSON traces to:
   /home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/traces/

## Output

- `/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/harness/` — Instrumented code, patches, test scenarios
- `/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-secured-message/traces/*.ndjson` — Collected execution traces

Ensure traces contain enough events (aim for 20+ events per trace) to
meaningfully exercise the spec's state transitions.
