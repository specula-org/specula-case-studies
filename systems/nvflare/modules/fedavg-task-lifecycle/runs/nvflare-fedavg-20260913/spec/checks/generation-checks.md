# Spec-generation checks and evidence limits

Pinned source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Final source checkout check: clean; no implementation files modified. Methodology: experiment-local `skills/spec_generation/SKILL.md`, full guide and all five methodology references; single agent, sequential base → MC → brief audit → Trace → instrumentation outputs.

- All eight requested files exist, plus 11 scenario hunt cfgs and modeling notes.
- SANY parsed, semantically processed and linted final `base.tla`, `MC.tla` and `Trace.tla` successfully. Logs: `base-sany.log`, `mc-sany.log`, `trace-sany.log`.
- TLC's actual `ModelConfig` parser accepted all 14 main/configuration files (base, MC, 11 hunts, Trace). `config-parse.log` records the enabled invariants/properties.
- Static cross-check: 80 base actions, 80 full-base-action Trace wrappers, 80 mandatory ValidatePostState calls and 80 instrumentation mappings. No silent actions or optional post-state fields. Default sibling trace path and IOEnv.JSON override are present; TraceMatched is enabled.
- Brief audit reads actual cfgs: all 5 scenarios, all 4 brief Safety invariants, and both section 6.1 mechanism questions have explicit targeting artifacts. See `enabled-invariants.json`, `config-manifest.json` and `../brief-coverage.md`.

## Limited execution checks

| Check | Result | Durable task ID |
|---|---|---|
| Final MC.cfg simulation smoke | No enabled core/structural invariant failure; **49,429 states checked**, **50 finite traces**, maximum requested depth 300; seed 4573700352766985477. This is not a distinct-state or exhaustive coverage count. | `ea1da36529bc49469747bbe8508fbe9f` |
| Synthetic 3-event trace positive | Exit 0; 5 generated / 4 distinct states, entire event stream consumed and TraceMatched checked. | `c50fdfc550704a91ae3a5540b3d09cf3` |
| Synthetic changed post-state negative | Expected exit 13, TraceMatched violated after matching only the first 2 events. Changing scheduled task broadcastVersion was rejected. | `475d06ca115b4a00bce58322a214ff07` |
| Synthetic unknown-event negative | Expected exit 13, TraceMatched violated after matching only the first 2 events. Unknown trace-tagged events are not skipped. | `7b5395ed8e0d41918926cfd0f2a909b6` |

Full logs/receipts are copied under `runtime/<task-id>/`; `receipts.json` indexes them. Synthetic fixtures are explicitly `origin="synthetic-test"`, stored under checks rather than the implementation traces directory. These replay controls exercise bootstrap and three lifecycle wrappers, not all 80 wrappers against real traces. `TraceControl.tla` and the control cfgs retain Trace.cfg's full post-state and temporal-completion checks.

MC smoke options: `-m 2G -M 1G -w 2 -t 1 -S -n 25 -p 300`; wrapper/TLC produced 50 traces across its two workers. Trace controls used `-m 1G -M 256M -w 1 -t 1`. These fit the run ceilings. Tools used the configured scratch directories (`JAVA_TOOL_OPTIONS` selected `/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/tmp`; TLC state under the configured TLC_STATE_DIR). All tasks finished and were waited through the task tool.

The simulation validates MCInit/MCNext and enabled MC.cfg invariants. The optional MCLiveSpec separately records the explicit terminating-callback premise; no liveness exploration was executed. Hunt cfgs were parsed/audited but **not hunted before implementation-trace convergence**. There is no exhaustive state-space result, actual NVFlare trace-conformance result, local functional regression confirmation, proof, or confirmed NVFlare bug from this generation phase.

An earlier generation smoke (`f603013da3864171be4f5a9c2b4aefc0`) exposed a TLA action-layout/quantifier-scope error that could leave s unspecified. The generator indentation and quantified guards were repaired, followed by successful smoke/replay checks. Its logs and generated debug artifacts are retained as **a repaired specification-generation error**, not an implementation counterexample. Auto-generated counterexample modules for synthetic negative tests are also debug artifacts; per-task logs are the canonical evidence because concurrent control runs can share TLC-generated filenames.

The final files are source-grounded finite abstractions. Actual configuration has not been exported; selected clients/keys/round bounds and optional failure interfaces remain explicit assumptions and coverage limits described in modeling-notes.md, brief-coverage.md and instrumentation-spec.md. MC-1 ordinary failure reachability and MC-2 intended partial-completion policy still require independent functional validation.
