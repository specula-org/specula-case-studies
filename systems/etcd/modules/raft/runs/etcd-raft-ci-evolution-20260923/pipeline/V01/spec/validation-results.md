# Specification-generation validation results

Status: requested generation artifacts are present and pass the checks below. **The broader initialization is not yet an accepted verification baseline.** Source correspondence, all scenario hunts, broader bounded exploration, full progress checking and remaining model extensions are pending. No real implementation bug is claimed confirmed.

| Check | Actual result | Evidence / limits |
|---|---|---|
| Required artifact and brief wiring audit | Passed: eight required files; ten hunt cfgs; all 22 brief safety properties defined/inherited/enabled in at least one hunt; 36 trace actions mapped | `output/artifact-audit.json`, `audit-artifacts.py`; definition/enabling is not reachability |
| TLA parsing, semantic and level analysis | Passed for base, MC, Trace | `output/syntax-base.log`, `output/syntax-MC.log`, `output/syntax-Trace.log`; includes the actual pinned JSON/IO modules |
| Exhaustive singleton developer check | Passed: 5,820 generated states, 1,176 distinct states, zero queued, depth 25 | `MC_smoke.cfg`; successful repeat after Case B sequence-index fix; final timestamped `output/smoke-*.log` |
| Valid synthetic adapter fixture | Passed; complete two-event fixture consumed, two distinct states | `output/adapter-valid-synthetic.ndjson`; final `output/trace-20260912-173028-598316.log`; **model-derived Init+Tick**, not an etcd trace |
| Invalid synthetic adapter fixture | Expected rejection, exit 13, cursor remains 2; temporal completion fails | `output/adapter-invalid-post-synthetic.ndjson`; final `output/trace-20260912-173209-601600.log`; structural preflight passes, changed elapsed post-state cannot match Tick. Rejection is transition/post-state correspondence, not a general safety-invariant violation. |
| Current source integrity | No tracked changes; HEAD is supplied build-only commit `98047a97b87252c328c9c6eee3fe72671d23a785` | `git diff --stat` empty; only preexisting untracked `.codex/` remains. No source tests were rerun in this phase. |
| Real positive implementation traces | **Not performed** | Harness generation remains the next workflow responsibility |
| Controlled-invalid general-contract implementation-trace tests | **Not performed** | Synthetic timer-post test is only an adapter plumbing check, not a substitute |
| Standard MC convergence / scenario hunting | **Not performed** | MC.cfg and ten hunt inputs are generated and audited; no hunt is reported as passing |
| Liveness | **Not checked** | Definitions and explicit premises exist; complete service/timing/retry drivers remain required |
| Initialization quality acceptance / CI state | **Not advanced** | No verdict edits, `current` changes, push, issue or publication |

The singleton configuration enables one campaign, has no injected client request, crash, message fault, membership change or snapshot workload, and uses the atomic strict caller. Therefore read, remote replication, restart and most membership invariants are vacuous in this developer check. It checks reference execution and lifecycle indexing; it does not validate those unexercised contracts or establish source correspondence. The first failing developer run is retained in `output/smoke-01.log` with its model-error classification in `changelog.md`; the property was preserved.

TLC checks ran serially with explicit **4 GiB heap + 1 GiB maximum direct memory and two workers** per instance, after checking for another active TLC. SANY used explicit allocations. No aggregate allocation approached the run's 200 GiB/60-worker ceiling. Every process was observed to completion. States and Java temporary extraction files are under this run's `tlc-states/spec-generation/` and `tmp/spec-generation/`; checker output is under `spec/output/`. Each runtime invocation has a 30-minute outer limit; no timeout is reported as a pass.

Reproducible commands from this directory:

```bash
./run-checks.sh syntax
PYTHONDONTWRITEBYTECODE=1 python3 audit-artifacts.py
./run-checks.sh smoke
JSON="$PWD/output/adapter-valid-synthetic.ndjson" ./run-checks.sh trace
# Expected exit 13: complete schema but wrong Tick post-state.
JSON="$PWD/output/adapter-invalid-post-synthetic.ndjson" ./run-checks.sh trace
```

Later real traces belong at `../traces/` and may be selected with JSON. The synthetic developer fixtures are retained under the requested spec output directory and explicitly named as synthetic. `run-checks.sh check MC.cfg` and scenario cfgs are available for the subsequent verification workflow; do not treat their existence as execution evidence.

Material remaining coverage: independently interleaved Storage reads/compaction inside core calls; asynchronous commit-only MustSync=false durability; additional legal Advance/send ordering; batched public proposal injection; full stopped-method/wrapper concurrency; validated read/configuration/ReadState-ownership oracles; real trace/harness coverage and nonvacuity; complete conditional progress. See `model-notes.md` and `brief-coverage.md` for precise impact and caller interpretations. These limitations require refinement before the broader initialization can be accepted.
