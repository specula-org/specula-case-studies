# Adoption evidence — Phase 2 complete

The supplied artifacts and raw conversations were checked against the handoff hashes. See `inventory.json`. All copied model, harness and evidence files are historical working copies; no semantic model changes have been made during adoption. Existing PASS claims are not fresh validation.

The active source is the pinned checkout under `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/source`. Old `/home/experiment` and transient `/tmp` command paths must not be executed unchanged. The harness phase must adapt paths and rerun its suite, generating fresh traces in the workspace `traces/`. Old traces are quarantined in `adoption/supplied-traces/`.

Original analysis and deep-analysis reports retain their old language, including claims of confirmation. The [takeover review](../takeover-review.md) supersedes those status claims. The [findings reconciliation](findings-reconciliation.md) preserves all main/deep/lower leads and queues eligible candidates for configured confirmation.

The current [modeling brief](../modeling-brief.md) and [coverage audit](../spec/brief-coverage.md) are the Phase 2 handoff. Read [model-audit.md](model-audit.md) and [harness-audit.md](harness-audit.md) before continuing: supplied semantics were preserved, and specific model/projection/atomicity repairs remain for their assigned phases. The next launcher invocation must adapt the copied harness and generate fresh traces. Phase 2 completion does not mark harness, validation, confirmation or final reporting complete.

Fresh static evidence is in syntax-checks.json, vav-check.json, vav-diagnostic-result.json and static-checks.json. check_assets.py reproduces source/patch/Python/shell/config usability checks without running scenarios. The isolated vav-diagnostic/base.tla is an equivalent-form diagnostic, not the adopted reference spec. integrity-checks.json records final preservation and output checks.

The original Claude run was interrupted by credit exhaustion before Phase 4. Original Claude spend including preflight: $180.5573146. The continuation uses Codex subscription usage, accounted separately by the launcher. API-equivalent estimates are not new Claude-account charges.
