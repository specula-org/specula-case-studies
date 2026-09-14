# Generation checks

Generated the eight requested artifacts, four targeted hunt configurations, and the reproducible generator/action inventory for source `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The source checkout remains clean.

- SANY semantic parsing passed for `base.tla`, `MC.tla` and `Trace.tla`.
- `base.cfg`, `MC.cfg` and all four hunt cfgs configured successfully. Their single initial state and immediate successors satisfy their enabled invariants. This is one-layer artifact evaluation, not a state-space search.
- `Trace.cfg` parses with `TraceMatched` enabled. A synthetic one-event input matches; changing its post-state or omitting a required post field yields zero matching successors. The first schema test exposed an invalid generic scalar-type probe in the JSON decoder; the final decoder uses the explicit state-field schema, with no dropped post-state check.
- All 94 base actions have exactly one trace wrapper and instrumentation row. Every brief §5 safety invariant is enabled in at least one hunt cfg. S2/S5 mergers and all five user priorities are documented in `brief-coverage.md`.

No exhaustive or budgeted TLC search, liveness verification, implementation trace conformance, NVFlare regression, or bug confirmation was performed. The synthetic fixtures under `checks/` are clearly separated from the future implementation traces under the sibling `traces/` directory. Hunt cfgs are prepared for use after trace/model convergence.

Evidence and artifact hashes: `checks/artifact-checks.json`; individual parsing/initialization/schema logs are in `checks/`. Reproduce the artifact checks from this directory with `python3 checks/check_artifacts.py`. Java checks used an explicit 1 GiB heap each, sequentially; their temporary files follow the configured run Java temp directory. No background task remains.
