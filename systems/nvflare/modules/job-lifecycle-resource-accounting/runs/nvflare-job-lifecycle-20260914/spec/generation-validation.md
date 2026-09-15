# Generation check receipt

Date: 2026-09-14. Source HEAD freshly verified as
`53ba7ee567468ea7971dad4faccef13c6cb35dc2`; source checkout remains clean.
Generation used the user-selected spec-generation skill and its full guide and
five methodology references. The experiment-local copy has the same guide.
Category A; single agent, sequential phase outputs with final consistency repairs.

All eight requested files exist, plus eight scenario hunt configurations.
`artifact-hashes.json` pins those 16 final artifacts. Reproducible generation
scripts and raw #5191 read-only API evidence are retained in this directory.

| Check | Result | Evidence scope |
|---|---|---|
| SANY base.tla, MC.tla, Trace.tla | 3/3 passed | Parsing and semantic processing; `sany-*.log` |
| cfg parsing/resolution, Init and one-step expressions | 11/11 cfgs passed | Direct TLA evaluator calls: initial state plus immediate successors only; `output/initial-*.log` |
| Synthetic Trace schema positive control | One matching successor | One `DefaultJobSchedulerBeginPass` fixture using JSON override and complete scheduler post-state |
| Synthetic Trace schema negative control | Zero matching successors | Same fixture with duplicate/wrong scheduled membership; post-state decoder rejects it |
| Base action / Trace wrapper / instrumentation mapping | 116/116 identities matched | Actual generated action inventory and hook table |
| Source anchors | All referenced files and line ranges exist at pin | Range validation, additional to the targeted source reading |
| Brief coverage | 5 scenarios, 6 safety properties, 4 MC findings mapped | Active INVARIANTS/PROPERTIES read from all 8 hunt cfgs |

`output/SpecGenerationCheck.java` uses the experiment-local TLA evaluator to
resolve configs and evaluate initial/immediate successor expressions. These are
finite generation checks, with a 1 GiB Java heap, one foreground process at a
time and no TLC worker pool/fingerprint search. Host availability was checked
(approximately 266 GiB available), well above the required 32 GiB reserve. Java
temporary files stayed in the configured experiment scratch directory. No TLC
state-space job or externally visible action was started.

The synthetic NDJSON files under `output/` are decoder fixtures, not NVFlare
traces. No real implementation trace was collected/replayed. No bounded or
exhaustive TLC search, hunt, trace convergence, controlled process fault test or
production confirmation was performed. No new defect is claimed. All source
candidates still require downstream validation; in particular TV-2/TV-3 service
failure paths and the listed CR boundaries are explicit in brief-coverage.md.

The post-state tests exercise only the decoder and first scheduling action;
they are not coverage of the 116 action bodies. Every action assigns its state
variables through whole-record updates plus generated UNCHANGED clauses, and
SANY checks their syntax/levels, but enabled-path/behavioral validation remains
the next verification phase. TraceMatched is actively configured; its temporal
property was not run on implementation evidence in this phase.

After the completed checks, one generation-only refinement scratch script was
removed; its changes are incorporated in generate.py. No input/source file was
changed. `check-generated.py` reruns the recorded structural and expression
checks and refreshes final artifact hashes; it does not launch a model hunt.
