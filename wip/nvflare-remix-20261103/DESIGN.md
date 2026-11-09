# Multi-grained NVFlare slice: design

Purpose: let model checking explore deep cross-component interactions by mixing coarse and fine variants of **action groups** freely, in the spirit of Remix (multi-grained specs with interaction-preserving coarsening). This file is the contract every group variant follows.

## 1. Structure

| Layer | Files | Owner rule |
|---|---|---|
| Ports | `spec/Ports.tla` | vocabulary, message helpers, all port variables and their initial values |
| Group variants | `spec/<Group>_<V>.tla` | one module per (group, variant); EXTENDS `Ports`; declares only its private variables |
| Mix root | `spec/Mix.tla` (generated) | `CONSTANT Grain : Group -> Variant`; composes the selected variants |
| Properties | `spec/Props.tla` | cross-component properties over port state only |
| Registry | `spec/registry.json` | groups, port variable, owned message kinds, variants and their private vars |
| Tools | `scripts/gen_mix.py`, `mkmc.py`, `run_mc.py`, `ce.py`, `tlc.sh` | generation, static checks, mix configs, runs, CE summaries |

### State partition

- `net`: append-only message log `key -> [msg, lost]`. A message is sent by exactly one group: the registry assigns every kind to one owner group. Consumption is private: each receiver keeps its own handled-key set, so receiving never changes shared state.
- One port variable per group (`pJobSP`, `pJobCP`, `pRunCJ`, `pTaskCJ`, `pPaySrc`, `pPayRcv`, `pCommSJ`, `pWfSJ`). Only that group writes it; any group in the **same process** may read it. Cross-process reads are allowed only for OS-level facts (a parent observing its child's exit, the server observing SJ exit), and are listed in §3.
- Private variables per variant (`jobSP_c`, `paySrc_f`, ...). No other module can name them; `gen_mix.py` rejects any variant that mentions another variant's private variable.

### Composition rule

`Mix!Next == \/_{g,v} (Grain[g] = v /\ g_v!Next /\ UNCHANGED <<everything g_v does not own>>)`. The private variables of variants that are not selected are initialized deterministically and never change, so they add no states. One TLA+ root therefore covers every mix; a mix is just a `Grain` value in an MC module (`scripts/mkmc.py`).

Static checks run on every generation and fail closed. Each variant may prime only its own privates, its group's port and `net`. It may only construct messages of kinds its group owns. It must declare exactly the registry's private variables, and it must not mention foreign private variables.

Every registered variant is mixable by default. A variant marked `"wip": true` in the registry has bounded-only refinement evidence (no exhaustive receipt); `gen_mix.py` lists such variants on every run, and `MIX_EXCLUDE_WIP=all` (or a group list) leaves them out.

## 2. Variant contract (interaction preservation)

For a group `G` with variants `F` (finer) and `C` (coarser):

1. **Same ports, same encoding.** Both variants write the same port variable with the same value encoding, and send the same message keys and bodies for the same protocol event. Port shapes and initial values live in `Ports.tla`, never in a variant.
2. **Coarsening merges only port-invisible steps.** Each fine step that changes `Proj_G` (G's port variable plus the messages of G's kinds) must correspond to exactly one coarse step that makes the same change. Fine steps that change only private state map to stuttering. A coarse step may not combine two port-visible fine effects (e.g., send message A and set port field B atomically when fine does them in two steps).
3. **Coarse over-approximates.** Every behavior of `F`, projected on `Proj_G`, must be a behavior of `C` in every environment. Coarse may allow more, including failures, reorderings and nondeterministic outcomes. The extra behavior can only produce spurious counterexamples; it never hides a real one.
4. **Receptive.** A variant never blocks another group's step, and its guards read only port state and its own privates.

Check: `checks/refinement/Ref_<G>.tla` instantiates `C` with its private variable replaced by an abstraction function of `F`'s private state, `AbsC`, written by the author of `F`. TLC then checks `CRef!Init` and `[][CRef!Next \/ UNCHANGED <<AbsC, Proj_G>>]_allVars` in the mix where `G = F` and every other group is coarse.

Soundness argument (safety, one finite instance). For a state s of the all-fine system and a set S of groups, let s|S replace the private state of every group g in S by AbsC_g(s); ports are unchanged.

**Claim.** For every reachable state s of all-fine and every S, s|S is reachable in the mix where S is coarse and the rest is fine.

**Proof** by induction on the length of the behavior.
- **Base.** Initial states map to initial states, by the RefInit checks.
- **Step.** Let s -> t be a step of group G. A variant's guards and effects mention only its own privates and the ports (enforced statically).
  - If G is not in S, the same fine step is enabled from s|S, because G's privates and the ports are identical there. It leads to t|S.
  - If G is in S, take S' = all groups except G. By the induction hypothesis, s|S' is reachable in the refinement-check mix (G fine, everything else coarse), and it has the same G-private state and ports as s. The exhaustive refinement check therefore covered this exact G step and showed that it is a C_G step, or a stutter, on <<AbsC_G, Proj_G>>. C_G's guards also read only its private state (= AbsC_G) and the ports, so the same C_G step is enabled from s|S and leads to t|S.

**Consequence.** A safety property over ports plus the private state of the groups kept fine, that holds in a mix, also holds in all-fine.

The argument needs the following conditions, C1–C8 from `notes/design-review.md`, each with how it is enforced:
- **C1 Same instance.** For every group that is finer in all-fine than in the mix, there is an exhaustive receipt with the mix's exact constants: sites, faults, Net variant, launch and attempt bounds. Faults are not monotone. Receipts are in `checks/receipts/`, keyed by that signature (`gen_ref.py`), and campaign results are labeled "transfers to all-fine" only when every needed receipt exists.
- **C2 Single environment.** Each receipt is produced with every other group at its coarsest variant.
- **C3 Net discipline.** Existing messages are immutable; new keys carry only kinds owned by the stepping group; only Net flips loss flags. Every generated step carries `Assert(NetOK(g))` / `Assert(NetLossOK)`. Statically, no variant may mention `.lost` unless it is Net, and imports must come from an allowlist.
- **C4 Write isolation.** Generated frames, plus the static prime check.
- **C5 Read isolation and stable abstraction.** Guards, effects and AbsC mention only own privates and ports (static). AbsC must not change on other groups' steps; this is checked by `RefEnv == [][UNCHANGED <<privs, Proj_G>> => UNCHANGED AbsC]`.
- **C6 Same encoding.** Port shapes live in `Ports<Comp>.tla`; refinement rejects values that coarse cannot produce.
- **C7 Chains.** With more than two variants, transfer only along checked refinement edges: F ⊑ M and M ⊑ C, not F ⊑ C and M ⊑ C.
- **C8 Init.** Deterministic Init and RefInit.

Coarse steps match the whole port change, because CRef!Next fixes net' and the port'.

Liveness does not transfer, because coarse fairness differs.

### 2.1 Assume-guarantee receipts (the standard path)

Refinement checks run inside the full mix do not scale: the all-coarse 1-site mix already has millions of states, and every full-mix receipt so far stopped at its time budget. The standard receipt is therefore a **harness receipt** with an explicit environment assumption:

1. **The group's environment module `Env_<G>.tla`** describes how the rest of the system may change the ports that G reads. It has two forms of the same transitions:
   - `EnvNext`, the generator form: concrete port updates, written in `EnvVars`;
   - `EnvAllowed`, the checker form: a predicate on `(Reads, Reads')`.

   The generator emits single-field moves; simultaneous changes in a real step are a sequentialization the harness also explores, which is sound because G only reads them.
2. **`scripts/gen_harness.py G F C --env Env_G`** builds a harness that contains only G's fine variant plus `EnvNext`. It checks exhaustively, and cheaply:
   - `RefInit`, `RefStep` and `RefEnv`, the refinement of F to C;
   - `EnvSound`, which says generated environment steps satisfy `EnvAllowed`.

   `--negative` checks the non-vacuity control. The receipt goes to `checks/receipts/<G>_F_C__harness_*.json`.
3. **Discharge**: `AG_<G> == [][EnvAllowed]_portVars` (`spec/AG.tla`) must hold in every mix whose conclusions use G's receipt. Campaigns add it with `"prop": ["AG_<G>"]`. A violation means the assumption is too narrow: widen `Env_<G>` and re-run the harness, rather than restricting the neighbor.
   - Exhaustive discharge is done per neighbor H, in H's own harness: H_C satisfies the part of A_G over H's ports, so H_F does too, by H_F ⊑ H_C.
   - A discharge checked only by simulation in mixes is bounded evidence.
4. For per-site groups, a 1-site harness covers each (group, site) instance under C9.

Worked example: Trainer.
- `Env_Trainer` encodes the in-process executor contract (in_process_backend.py:152-260): task k is delivered after k-1 results are published; topics fire; readiness; launch; death.
- Harness receipts are exhaustive: 1 site with 1 launch (467 states), and 1 site with 2 launches (65k states, 2 s). The negative control fails as required, and S02 is still found in 12 steps.
- The first discharge runs violated `AG_Trainer` twice, and both times this exposed assumptions narrower than the real neighbors: (1) the signal port changes abort -> stop and stop -> abort; (2) coarse TaskCJ publishes input after ABORT. Env_Trainer was widened twice. The discharge now holds in all-coarse, TaskCJ-fine and all-fine mixes (simulation, 120–150 s each).

Worked example: RunCJ.
- `Env_RunCJ` covers every read of both RunCJ variants: CP launch and kill requests, the END_RUN inbox (sent by a live SJ, lost only under `netLoss`), T1 inputs (`pWfSJ.dsShutdown`, SJ gone), and the PaySrc transaction view. It also states the guarantee assumed from PaySrc: a transaction is registered only while its CJ is alive, and shut only after RunCJ declared `dsDown`. No CJ-side `fatal` flag may appear, so a future writer shows up as a discharge violation.
- The first harness run refuted `RefStep` in 2 s, on a bug in the coarse side: coarse `Exit` required `PaySrcShutDone` at exit time, but a transaction registered after the shutdown call returned does not hold up the fine exit (no latch in `_register_source_download`). The coarse guard is now "STOPPED sent or shutdown done". The mix-level refinement check (2.9M states, budget-stopped) had not reached this interleaving.
- Harness receipts are exhaustive: 1 site with 2 launches (10,911 states), the same with cjCrash, netLoss and slowSJTeardown (86,973), and 2 sites with 1 launch and cjCrash, netLoss (867,245, 4 min). The negative control fails as required.
- Discharge `AG_RunCJ` (with `AG_Trainer`) holds by simulation in five mixes: all-coarse, all-fine, job-fine, payload+fed-fine, and a mixed Net L mix, each with 2 sites, 2 launches and 12 faults/timers (240 s each, 3k-57k traces). This is bounded evidence.

## 3. Groups (v1, process x component)

| Group | Process | Mechanisms | Port var | Owned kinds |
|---|---|---|---|---|
| JobSP | SP | scheduler resource check, start, SJ spawn, abort command, outcome receipt, terminal status | pJobSP | CHECK_RESOURCES, START_JOB, ABORT_JOB |
| JobCP | CP | reserve/allocate/free, CJ spawn/kill/relaunch, child wait, outcome report | pJobCP | RESOURCES_OK, OUTCOME |
| RunCJ | CJ | runner init, local ready, READY, END_RUN, stop, exit/crash | pRunCJ | READY |
| TaskCJ | CJ | GET_TASK, assignment, in-process trainer, submission, envelope, receipt, receipt timeout | pTaskCJ | GET_TASK, RESULT_ENVELOPE |
| PaySrc | CJ | DownloadService source: register, serve DATA/EOF, confirm/cancel, timeout, retire, release, outcome, settle | pPaySrc | PAYLOAD_REPLY |
| PayRcv | SJ | lazy-ref materialization: pulls, DATA/EOF, materialize, confirm, pull timeout/cancel | pPayRcv | PAYLOAD_PULL, RECEIVER_CONFIRM, RECEIVER_CANCEL |
| CommSJ | SJ | server runner task handling, WFComm authority, envelope, claim, callback finish, receipt, task timeout | pCommSJ | TASK_ASSIGNMENT, RESULT_RECEIPT |
| WfSJ | SJ | workflow admission, FedAvg round, accept/reject, close, aggregate, save, END_RUN, SJ exit/crash | pWfSJ | END_RUN |
| Trainer | CJ | in-process user training thread + Client API object: GLOBAL_RESULT callback, receive, send/publish, clear_cache tail, abort/stop | pTrainer | (none; DataBus via ports) |
| Net | - | reliable (R) or lossy (L) delivery | (net loss marks) | - |

Process facts are deliberately weak so that no variant gets an oracle:
- `pJobCP[c].killed` is a kill **request**. The child dies only when RunCJ takes `DieOfKill`, and that step has no fairness, so a kill may never land.
- Remote peers react to `PeerFailureCJ`/`PeerFailureSJ`: real death, or a false suspicion under `transportFail` (connection drop, slow peer). A perfect failure detector would hide H29-type hazards.

Process death: any group can kill its process (e.g. `os._exit`) by setting a boolean `fatal` field in its own port record. `CJAlive`/`SJAlive` and the parent-visible exit codes (`CJExitCode`, `SJExitCode`) include those flags, so a process stays a single fate-sharing unit without any group writing another group's state. `CJGone`/`SJGone` let peers observe a dead process as a transport failure.

Allowed cross-process reads (OS facts): `JobCP` reads `pRunCJ[c][l].exit` (child wait); `RunCJ` reads `pJobCP[c].launch/killed` (it exists only as a launched child); `JobSP` reads `pWfSJ.sj` (server-side process handle); SJ groups read `pJobSP.sjLaunched`. All other cross-process information travels in messages.

Identities are parameterized even when the slice uses one value: launch generation `l in 1..MaxLaunch`, task attempt `a in 1..MaxAttempt`, `Tx/Ref(c, l, a)`. Message keys embed them, so a stale message from an old launch or attempt is a different key.

## 4. Mixes and campaigns

**Per-site grain.** Groups listed in `registry.json` `per_site_groups` (JobCP, RunCJ, TaskCJ, Trainer, PaySrc, PayRcv) may choose their variant per site through the `SiteGrain` constant. For example, `--grain Trainer=F@s1` makes site s1's trainer fine and s2's coarse; the generator restricts each action's site binder to `SitesFor(g, v)`.
- The mix space for 2 sites becomes 2^3 (process-level groups) x 2^12 ((group, site) instances) x 2 (Net) = 65,536.
- `sweep.py --per-site --strategy cover:2|3` builds t-way covering arrays over the (group, site) factors: 9 mixes for pairwise coverage, 19 for 3-way.
- Soundness is the same induction over (group, site) instances. It needs one more condition, **C9**: an action for site c of a per-site group touches only the c-slice of its private and port variables.
- A receipt for G at s1 (everything else coarse) covers s2 by site symmetry; symmetry reduction is turned off in per-site mixes.
- **Process-level actions block splitting** (fixed 03:00 after an external review). An action of a per-site group that has no site binder, for example PayRcv's SJ-wide source-download shutdown, cannot run in a site-mixed configuration: it would have to execute both variants at once.
  - The generator therefore computes `SiteSplittable`, the per-site groups that have no such action (currently JobCP, RunCJ, TaskCJ, Trainer, PaySrc; not PayRcv), and asserts `DOMAIN SiteGrain \subseteq SiteSplittable`. Sweeps only split those groups.
  - Before this fix, PayRcv site-mixed configurations silently dropped the shutdown action. That is an under-approximation: violations found in them are still real behaviors of the mix, but their "no violation" results are not valid.

- A mix is a `Grain` value. `mkmc.py NAME --grain G=V,... --faults ... --sites N` writes `checks/mixes/MC_NAME.{tla,cfg}`, and `run_mc.py` runs it and writes `checks/results/NAME.json`.
- Faults are explicit toggles (`Faults` constant) owned by the group whose process exhibits them: `cjCrash` (RunCJ), `sjCrash` (WfSJ), `netLoss` (Net L), `taskTimeout` (CommSJ, TaskCJ), `pullTimeout` (PayRcv), `txTimeout` (PaySrc), `abort` (JobSP), `outcomeReportFail` (JobCP).
- Scenario campaigns (§5) make fine exactly the groups a Phase 1 hazard involves, keep the rest coarse, and enable the hazard's faults. Sweeps run every mix with a common property set under a time budget.
- Counterexample triage (zoom-in): for a violation in mix `M`, list the groups that are coarse in `M` and whose steps occur in the CE. Rerun with those groups fine (or replay the CE's port projection against the fine variant). A CE that disappears when its coarse groups are refined is a coarsening artifact. One that survives the all-fine replay is a model-level candidate, which then needs source and implementation confirmation.

## 5. Scenarios (from Phase 1, `notes/phase1-hazards.md`)

Cut criterion applied: each Phase 1 hazard should involve as few groups as possible. Bug-prone mechanisms stay inside one group:
- PaySrc keeps SERVE+SETTLE together, because both use the progress lock where the payload MC-2 lives.
- WfSJ keeps the result-callback body with CloseRound (shared round guard).
- JobSP absorbs the SJ engine (a weak cut).
- The in-process trainer thread is its own group, because the Trainer/executor boundary is exactly where H02 lives.

Benign boundaries are the cut lines: SP<->CP admin messages, the CJ<->SJ task/result protocol, and the receiver<->source pull protocol.

| Scenario | Hazard | Groups that must be fine | Faults | Property (Props.tla) |
|---|---|---|---|---|
| S10 | H29/H30: source loss during SJ decode of streamed SUBMIT_UPDATE -> `os._exit(1)`; a straggler at END_RUN turns a completed workflow into a failed job | PayRcv, PaySrc, RunCJ, WfSJ (+TaskCJ) | cjCrash (H29); none for H30 (needs straggler policy or taskTimeout) | OutcomeReflectsWorkflow, NoSJDeathAfterWorkflowDone (diagnostic) |
| S02 | H02 (v2 MC-2/TP-C): in-process send() tail clears the successor input | Trainer, TaskCJ (rounds >= 2) | none | SuccessorInputPreserved |
| S12 | submission timeout/retry vs in-progress claim; tx per attempt | CommSJ, TaskCJ, PaySrc, PayRcv | taskTimeout, pullTimeout | ApplicationReceiptAtMostOnce, AbandonedTxSettles (fedavg/payload notes) |
| S22 | lifecycle: lost START/OUTCOME, TTL expiry, stale READY/STOPPED, abort during restart | JobSP, JobCP, RunCJ | netLoss, cjCrash, abort | OutcomePrecedence, StaleNotificationFenced, AbortBlocksRestart (job notes) |
| S23 | late results, mark-only cancel, completion before task_done | CommSJ, WfSJ | taskTimeout | FencedReceiptAtMostOnce |
| S06 | resend duplicates ClientTask after lost assignment | CommSJ | netLoss | OneAssignmentRecordPerIdentity |
| S11 | delayed CANCEL fails a new tx that reused the ref id | PaySrc | netLoss / delay | CancellationGenerationAssociation |
| S19 | payload canaries: EOF-after-cancel progress (known MC-2), settlement once | PaySrc, PayRcv | pullTimeout, txTimeout | ProgressAgreesWithOutcome |

Out of slice and left as placeholders: Attach/external trainer modes (S04, S09, S18), SAG (S03), Swarm/CCWF (S05, S07), multi-job GPU environment (S01), K8s workspace transfer (S08), task workers.

Campaign definitions live in `checks/scenarios.json` and are run with `scripts/campaign.py`. Systematic coverage of mixes comes from `scripts/sweep.py --strategy cover:2|cover:3`, a greedy t-way covering array over `(group -> variant)`. Every pair or triple of variant choices appears in some mix. For example, 10 groups with 2–3 variants each have 1,536 mixes, and 10 or 21 of them suffice for 2- or 3-way coverage.

## 6. Trace validation per mix

All variants of a group must produce identical port effects for the same protocol event (§2), so a real execution can be checked at port level against any mix. Port behaviors satisfy Beh(finer) ⊆ Beh(coarser). Therefore:

- **Acceptance transfers upward only.** The positive trace is replayed on the finest mix available. If all-fine accepts it, every coarser mix accepts it. Acceptance by a coarse mix alone is reported as "coarse replay".
- **Rejection transfers downward.** Negative controls (corrupted identity, payload, order, missing or unknown event) run on all-coarse; if all-coarse rejects one, every finer mix rejects it too.

Mechanics (`scripts/gen_trace.py`):
- The observation stream is the POC run's causal step sequence (`connected-1793718642318637337`, 120 steps), mapped to port events: messages added (kind/from/to) and port field transitions. 75 of the 120 steps have port effects; the rest are group-private.
- `TraceMix_<name>` copies the Mix and adds a cursor `tpos`. Every step either produces exactly the next observed port event, or no observable event at all (silent internal step). Acceptance means `tpos` passes the end.
- If the trace is rejected, the tool reports the furthest position reached and the expected event there, which localizes the mismatch to the group that owns that port or kind.
- Implementation note: TLC evaluates a conjunct that follows an INSTANCE'd action in the instance's scope. The cursor is therefore bound before the step (`\E p \in {tpos}`), and the trace module inlines the Mix.

## 7. Rare-event budget (MixR)

Faults are switches (§4): once enabled, a fault may happen any number of times at any point, so counterexamples tend to stack many unlikely events. The budget bounds that instead.

- **Weights.** `spec/rarity.json` gives each fault a weight, roughly −log10 of the chance of one occurrence. Timing-assumption escapes (`slowSJTeardown`, `slowAdminStop`) are priced highest because real measurements show large margins. A path's total weight approximates −log(probability).
- **Step cost** (`scripts/rarity.py`):
  - *static*: the action is gated by priced faults (a top-level conjunct `"f" \in Faults` or `Faults \cap {...} /= {}`);
  - *dynamic*: the action mentions faults only inside a disjunction, IF or helper operator, i.e. a fault widens what it may do (coarse actions, `"slowSJTeardown" \in Faults \/ TimingOK`). The step costs `w` only if the same transition is not allowed with the priced faults removed (`IF G_V__N!A(args) THEN 0 ELSE w`, with `G_V__N == INSTANCE G_V WITH Faults <- NormalFaults`);
  - overrides in `rarity.json` `actions` handle multi-step fault mechanics (for example, a clock tick is free and the timeout decision is charged).
- **Generated root.** `MixR.tla` extends Mix with `VARIABLE rare` and `CONSTANT RareBudget`. Each `RStep_X` is `Step_X` plus `rare' = rare + cost /\ rare' <= RareBudget`. `OverBudget` marks states where only over-budget steps are enabled; deadlock checks treat those as bounded, not as hangs.
- **Use.** Run `mkmc.py --rarity K` with all faults enabled, then raise K = 0, 1, 2, ...; `rarce.py NAME` lists the rare events a counterexample relies on.
  - A result is "no violation with at most K rare-event weight", never "no bug".
  - Budgets pay off mainly in simulation: random walks stop drowning in faults and reach the end of the job.
- **Coarse groups under a budget.** Coarse actions over-approximate: they can make an outcome cheap that the fine group only reaches through a priced event. A cheap counterexample whose cost-free steps include coarse-group decisions is zoomed in (§4) before it is reported.

## 8. Hunting configuration (v4)

The v4 changes came out of a three-way review (model gaps, search efficiency, recall on known bugs; `.tmp/discuss/{gap,eff,rec}.md`). It found that blind sweeps barely searched past job start: one-shot faults fired in the first few dozen steps of almost every trace. The changes below target that.

- **Profile switches.** `CONSTANT Profile` (`Consts.ProfileSwitches`) selects non-default NVFlare policies that were hard-coded in the modules. Profile switches are configuration, not events, and are never priced.
  - `wfTolerant`: workflow `min_clients = |Sites|-1`, no required sites.
  - `lossBudget3`: Net_L may lose up to 3 messages.
  - Set them with `mkmc.py --profile` or `gen_ref.py --profile`.
- **Fault throttle.** `mkmc.py --throttle T` adds `ACTION_CONSTRAINT Throttle`. In simulation it accepts a priced step with probability 1/T, unless no free step is enabled. It only prunes, so every trace is still a model behavior.
- **Known-finding filters** (GenericProps "K" section):
  - `GStatusStableK` and `GTerminalStableK` allow #5301 and CANT_SCHEDULE-over-ABORTED.
  - `KnownPrune` (a CONSTRAINT) drops states after S02 or H30.
  - Everything else of the same kind is still reported.
- **New generic invariant.** `GDoneSavedCompleted`: a workflow that returned, finished END_RUN and saved its model ends as a completed job unless an admin aborted it.
- **Campaign driver.** `scripts/hunt.py TAG PLAN` runs a heterogeneous plan (throttled deep simulation, rarity-bounded BFS, unthrottled controls, AG properties, re-runs) under a global worker budget. It caps concurrent BFS runs (their queues live on disk) and appends each finished run to `checks/sweeps/TAG.jsonl`.
- **Outcome acknowledgement.** The port field `pJobSP.outcomeSeen` lists sites whose OUTCOME the server has handled. The CP's report request (`send_request_before_shutdown`) returns, and the job leaves the heartbeat listing, only after that, or on `rpcTimeout`. Before this, both JobCP variants could return at once, so the server could see the job missing from a heartbeat and fail a completed job.
- **TLC.** `lib/tla2tools.jar` is now the 2026.09 nightly (rev 4260e47); the old build is kept as `lib/tla2tools-2.20-old.jar`.
  - The old build's simulation worker crashes while rebuilding a violating trace, and the run then hangs, so the violation is lost.
  - `run_mc.py` records any `Exception in thread` as `worker_exception`, never as `budget_stopped`.
- **Fault list and bounds.**
  - `trainerStall`, which no action read, is replaced by `trainerError`: the user training code raises and the thread ends without `send()`.
  - `TaskCJ!AtBound` also marks TASK_CHECK retry exhaustion. The real client retries without bound, so such states are bounded, not hangs.
- **Known-finding filters are invariant-level.**
  - K forms: `GNoFreeWhileAliveK`, `GDoneSavedCompletedK`, `GFinishedNoAbnormalExitK`, `GStatusStableK`, `GTerminalStableK`.
  - `mkmc.py --known` adds `KnownStuck` to the deadlock check's bounded states.
  - A CONSTRAINT is not used: it does not stop the invariant check of the state it prunes, and "the only way forward is a known state" becomes a spurious deadlock.
  - Known set: K1 #5301, K2 CANT_SCHEDULE over ABORTED, K3 S02, K4 H30, K5 H21, K6 H19 on the restart path, K7 H33 missing outcome, K8 hunt4 candidate C1.
- **Net discipline and re-sends.** `Consts!Send` / `SendAll` treat re-sending the identical message under an existing key as a no-op, so under Net_L a lost message stays lost. A different message under an existing key still overwrites, and the sender's `NetOK` assertion flags it (this caught the coarse CommSJ double receipt).
- **Multi-round port invariants.** `spec/PropsMR.tla` holds the per-round forms of the Props port invariants plus the fedavg port checks; at MaxAttempt = 1 they are identical to Props. WfSJ resets its per-round port fields (`accepted`, `aggregate`) in the same step that advances `scheduled`.

## 9. Model gaps filled in v5

From the gap list of the round-4 review (`.tmp/discuss/gap.md` §5). Each item below changed both variants of the group where the coarse one had to follow, and was re-checked by refinement (budget-stopped, negative controls fail).

- **New profile switches** (`Consts.ProfileSwitches`):
  - `nonStrictStart`: NVFlare's default START reply check (`STRICT_START_JOB_REPLY_CHECK = False`). A timed-out START reply drops the site from the active sites, and then, in a separate step, from the pending outcomes. An OUTCOME arriving between the two steps is still handled as pending. The port field `pJobSP.startDropped` lists the dropped sites. Coarse JobSP has the two matching steps `StartEval` and `FilterPending`.
  - `otherJob`: a second job runs on every CP with its own GPU allocation. Only its START handler's write of the CP-global `CUDA_VISIBLE_DEVICES` is modeled (`JobCP_F!OtherJobConsume`). It may run again whenever the env is not already B's, before our START arrives or after our reply; inside our START handler only under `rpcTimeout` (the server's 20 s START wait ended first), a priced timing escape. The fine-local property `PropsLocal!LEnvMatchesAllocation` checks the GPU env of a live CJ (H08).
  - `errResilient`: FedAvg `ignore_result_error=True`. FedAvg's default (dynamic) passes no `min_responses`, so it needs every target and behaves as strict; the slice keeps strict as the default.
  - `cseTasks`: each round's work is scheduled as one task per site, with that site as the only target, in a fixed site order (the client-controlled CSE server controller). A resend for a site that is not last in the order appends the same ClientTask again. A retirement that finds the duplicate kills the task monitor (H11). Symmetry reduction is off under this profile.
- **Thread death is modeled, not a block.**
  - The completion thread dies on the unguarded `del self.running_jobs[job_id]` when the start-failure path removed the job first (`pJobSP.completionCrashed`, C1-B).
  - The WFComm task monitor dies on the second `_client_task_map.pop` (`pCommSJ.monitorCrashed`, H11).
  - Generic properties: `GCompletionThreadAlive` and `GTaskMonitorAlive`.
- **Model errors found by the v5 smoke runs.**
  - JobCP_F: a restart claim by the waiter thread overwrote the START handler's pc before its reply, so the reply was never sent and the server waited forever. The reply is now owed through `replyDue`, independent of the restart pipeline.
  - JobSP_C: the no-kill branch of `Terminate` also applied to a registered live SJ. `RemoveAfterTerminate` could then unregister a live SJ, and the job went terminal with it running. The branch now needs the SJ unregistered or dead, as in fine `TerminateAfterExit`.
- **Known-finding filters added.** K9 H11, K10 C1-B (both in `KnownStuck`), K11 N1 / H32 class. K11's per-site K forms (`GFinishedAllOutcomesK`, `GFinishedNoLiveChildK`, `GFinishedNoAbnormalExitK2`) skip the sites in `startDropped`.
- **Not filled, with the reason:**
  - SJ→CJ payload direction: a failed task-data download on the CJ ends in another GET_TASK; only the SJ cell exits on a failed decode.
  - A new tx per try: the server dedupes by receipt, and H31 is a contract baseline; the change would re-key the 1654-line PaySrc_F.
  - Explicit ref reuse (H09): API-specific; default UUID refs exclude it.
  - SAG (H04): the partial accumulator is SJ-internal, and the helper documents that it does not roll back; a direct code check is cheaper.
  - Attach / external trainer, client sampling, SP/CP process restart, full multi-job: not done in v5.

## 10. v6: thread deaths, admin delete, process restart, trace validation

- **Thread-death audit.** Every long-running SP, SJ, CP and CJ thread was checked for calls outside an exception handler (RESULTS §11). Thread deaths that matter across components are modeled as death, with a port flag and a generic property:
  - completion thread (`completionCrashed`, C1-B);
  - task monitor (`monitorCrashed`, H11);
  - scheduling loop (`schedulerCrashed`, T1).

  The client cleanup thread (T2) is not modeled, because client registration is not in the slice.
- **Admin delete** (fault `deleteJob`). `delete_job` refuses only DISPATCHED/RUNNING jobs, so a queued job, or one still being deployed, can be deleted.
  - Fine JobSP: `AdminDeleteJob`; `JobRunnerScanDeleted` (the delete lands inside the scheduling scan); `CheckSubmitted` on a deleted job; `JobRunnerDeletedInTry` (store access inside the try raises); `JobRunnerFailureStatusDeleted` (the except branch's own status check raises and the loop dies).
  - Coarse JobSP: `Delete`, `DeletedCrash`, plus deleted as a `Fail` reason and in `FailStatus`.
  - A deleted job counts as done for the deadlock check (`DoneStutter`).
- **Process restart** (faults `spCrash`, `cpCrash`; Ports `SPRestarted` / `CPRestarted`). The child process dies with its parent (`monitor_parent_process`).
  - The restarted SP keeps only the job store. It runs no startup recovery (R1), and its scheduler idles forever, so R1 shows as the invariant `GNoStaleStatusAfterRestart`, not as a deadlock.
  - The restarted CP keeps nothing but handled keys. Its heartbeat drops the job (phase 3), and the SJ is never told (R2), so R2 shows as a hang.
  - Rule: `cpCrash` and `spCrash` come with `rpcTimeout`. A dead peer makes the real admin request time out or fail; without the timeout fault the model's waiter would wait forever.
- **Trace validation** (§6): silent bound 120, up to 3 observed events per step; acceptance by simulation; the real POC trace is accepted on all-fine, all-coarse and two alternating mixes, and a reordered trace is rejected exhaustively on all-coarse.
- **Not done in v6:** Attach / external-process trainer (about 3000 lines across the external process, cell and attach backends plus the client cell API; it needs a new trainer group).

## 11. v7: search that reaches the running and teardown phases

The round-6 coverage probe (RESULTS §12; `.build/x7/`) found that hunt6 rarely searched past job start. With throttle T=20, faults that are enabled at almost every step (admin abort, delete, CHECK timeout, message loss) ended the job before RUNNING in most traces: in the fine-JobSP families, 0–15 of 64 traces reached RUNNING. The BFS runs stopped at depth 30–60, and a fault-free job needs 69 steps (all-coarse, 1 site) to more than 129 steps (all-fine) to reach a terminal status. v7 changes the search, not the model's behaviors.

- **Phase-gated fault throttle** (`mkmc --fuse`, simulation). `spec/JobPhase.tla` defines job progress on the ports only, so it means the same in every mix:
  - 0 submitted, 1 dispatched, 2 RUNNING, 3 first client result accepted, 4 round 2 scheduled, 5 end-run, 6 terminal or deleted.
  - Each trace draws `fuse ∈ FusePhases` at its initial state. Priced steps are refused until `JobPhase >= fuse`, unless no free step is enabled, and are accepted with probability 1/T after that. This only prunes, so every trace is still a behavior.
  - The throttle's and the over-budget test's ENABLED also fix `fuse' = fuse`, so each ENABLED search determines the whole successor state.
- **Checkpoint BFS** (`scripts/ckpt.py`, `mkmc init_states`).
  - A checkpoint is the first state of a trace at which `JobPhase` reaches a level. It is found by simulating the same mix, faults and profile with budget 0, so the prefix is a cost-0 behavior of the BFS's own spec.
  - Free steps that only drive a fault mechanism (`rarity.json` actions priced 0, e.g. the CommSJ clock tick) are pruned from the prefix. Taken early, they lead to a state whose only way on is a priced step, such as a forced task timeout.
  - The BFS starts from the disjunction of the checkpoints, with `rare = 0` and no symmetry. A counterexample is the stored prefix (`checks/ckpt/<key>/p<phase>_<i>.trace`) followed by the BFS trace.
- **No idle scheduler passes** (JobSP_F `DefaultJobSchedulerBeginPass`). A pass needs a SUBMITTED job. A pass with no candidate only cycles the scheduler pc back to `idle`, so dropping it loses only private steps. Before v7 that cycle was 58–93% of the simulation steps in fine-JobSP families.
- **TLC stack.** With no step enabled, evaluating `(R)Next` (a 532-way binary `\/` chain) or ENABLED over it recurses to the end of the chain. Before v7 the idle scheduler cycle was always enabled and hid this. `scripts/tlc.sh` now passes `-Xss64m` (override with `TLC_XSS`).
- **L13 (v7, after hunt7).** New fault `statusLost` (weight 2). After a system panic the SJ exits with 0, and only its one fire_and_forget UPDATE_RUN_STATUS carries the error. If that message is handled more than 2 s after the exit, the job is classified as COMPLETED.
  - Fine JobSP: `ServerEngineObserveExitStatusLost`. Coarse JobSP: `ObserveSJExitStatusLost`. Both apply only when `SJExitCode = "error"` and the SJ was not killed.
  - New generic property `GFinishedNoPanic == Finished => ~SJPanicked`.

## 12. v8: client registry and cleanup thread (group Reg)

The dead-client report to the SJ used to be abstract: CommSJ's `WFCommReportDeadClient` fired on `PeerFailureCJ` under fault `deadClient`. Group Reg now models the real chain (`notes/reg-impl.md`), so T2, T3 and R2 are behaviors of the model.
- **Port `pReg`:**
  - `tok[c]`: token generation; a re-login adds 1, and the job's participants hold generation 1.
  - `reg[c]`, `stale[c]`.
  - `notified`: the <<site, generation>> pairs for which HANDLE_DEAD_JOB reached this job's SJ.
  - `cleanupCrashed`: "no", "relogin" (T2) or "jobExit" (T3).
- **Paths to `notified`:**
  - the cleanup thread's `notify_dead_client`, for a stale token that it logs out;
  - the heartbeat job sync, when the participant token is alive but no longer lists the job (its CJ is gone).

  A restarted CP's new token matches neither path, which is R2.
- **Timing.** Re-login pops the old token silently, and a CP restart alone never makes a token stale: the restart takes seconds, against a heart_beat_timeout of 60–600 s. In Reg_F the cleanup pass lists the stale tokens and logs out the first in one step, and each notification is followed at once by the next removal. A re-login therefore lands only while a logout is being processed (seconds each), and T2 needs two stale tokens. An earlier version let a re-login land in the microsecond gaps; the first R2 check exposed that as a 1-site T2.
- **T3.** New fault `jobExitRace` (weight 3; measured window about 0.3 ms) with profile `otherJob`: another job's SJ exits while `notify_dead_client` iterates.
- **Consumers.**
  - CommSJ_F's dead report requires `<<c, 1>> \in pReg.notified` and no longer needs `deadClient`.
  - The CommSJ_F clock tick also runs while a dead report is pending.
  - In CommSJ_C, `RetireFaults` and `PolicyPanic` also allow `pReg.notified /= {}`.
- **Properties.**
  - `GCleanupThreadAlive`.
  - `GCleanupThreadAliveK`, which excludes T2.
  - Known-stuck signature `KT23`.
  - `GFinishedNoPanicK8`, which excludes the L13 escape.

## 13. v8: external trainer (Trainer_X) and a second SP-only job (multiJob)

- **Trainer_X** (`spec/Trainer_X.tla`, a third variant of group Trainer, same port `pTrainer`). It models an external trainer process with `launch_once` and the CJ's ExternalProcessBackend acceptance and accepted-result-source monitor.
  - **Process and loop.** The process is launched once and serves the CJ's tasks. The trainer script loop is Trainer_F's. RESULT_READY accepted makes the result the session's live source for its task generation and starts a monitor thread. RESULT_SOURCE_SETTLED clears the source.
  - **Fault `tpSilent`** (w=1): heartbeats stop and may resume.
  - **Monitor iteration.** By default one iteration is atomic. Fault `monitorStale` (w=3) splits the identity check from the decision; that is the H03 window, measured as microseconds.
  - **Stop.** `_fail_accepted_result_source` notifies only if the source still is the monitored task, and `_stop_trainer` is unconditional.
  - **Fine-local property** `PropsLocal!LTrainerStopOwner`: a trainer is stopped only for a live source whose failure was notified.
  - **Coarse.** Trainer_C gains `ExtStop` (stopped under tpSilent). Refinement X→C passed with a 3.0M-state budget stop, and the negative check fails.
- **Profile `multiJob`** (JobSP).
  - **J2 in fine JobSP.** A second job J2 exists only in the fine JobSP: `Jobs = {JobId, "J2"}`, scan order J2 first, `MaxJobs = 2`. J2's check/deploy/start is one step, `J2Launch`, from `sendCheck`; our job's RPC chain requires `CurrentJob = JobId`. `J2Exit` is J2's SJ exiting. `J2Complete` runs only while the single completion thread is alive (`CompletionThreadAlive`) and not busy with our job.
  - **Delete paths.** Admin delete and the scan-time delete crash (T1) apply to both jobs. A deleted J2 is gone from the store listing.
  - **SP restart.** J2 keeps its store status and deletion; a running J2 becomes "stale".
  - **Port summary** `pJobSP.other` ∈ none | queued | running | exited | done | deleted | stale. Coarse JobSP drives it with `OtherLaunch`, `OtherExit`, `OtherComplete` and `OtherDelete`. `OtherDelete`'s crash branch sets `schedulerCrashed` and stage "crashed" from any stage.
  - **`DoneStutter`** does not count a terminal job as done while J2 is queued, running or exited, so a J2 that can never be finalized shows as a hang.
- **Timing T4 (after hunt8).** After `control_flow` returns, `stop_controller` + `finalize_run` end the task monitor within seconds (`server_runner.py:153-172`), so no 30 s tick and no 60 s dead-client grace elapses in between.
  - CommSJ_F's `ClockAdvance` requires `pWfSJ.returned = "none"` unless `slowFinalize` is enabled (w=2).
  - CommSJ_C has a private flag `deadEarly` (a report matured through the grace), maintained by `Mature`/`Unmature`. `PolicyPanic` requires it. After the return, `Mature` only fires with `slowFinalize`.
  - The abstraction is CommSJ_F's `AbsC.deadEarly == Matured`. Without T4, v8's relaxed coarse guard let a dead-client report that came after the workflow returned turn a completed job into FAILED.

## 14. Timing module

`spec/Timing.tla` (extended by `Ports`) holds the model's timing assumptions. Each one is a predicate with its source row in `notes/timing-inventory.md`.
- **Guards.** Each guard site reads `TimingOK(Faults, "<escape>", T?Holds(...))`. TimingOK means: the escape fault is enabled, or the assumption holds.
  - T1 is used in RunCJ_C/F, T2 in JobSP_C/F, T3 in PayRcv_C/F, T4 in CommSJ_C/F.
  - The fault set is a parameter, so MixR's pricing instances substitute it. A zero-arity shared constant would keep the root value (DESIGN §11).
  - `scripts/rarity.py` reads the escape name from the call (`TIMINGOK`), for dynamic pricing only.
- **Escape events.** `statusLost`, `monitorStale` and `jobExitRace` stay as top-level `"x" \in Faults` gates, so they are still statically priced. `Timing` lists them.
- **Equivalence of the refactor.**
  - All 576 step costs are identical before and after.
  - The hunt8b C runs that completed exhaustively were rerun unchanged and give the same distinct-state counts (RESULTS §14).
  - Trace validation still accepts the POC trace.


## 15. v10: task worker (group Worker, profile taskMode)

Profile `taskMode` means the client app uses `execution_lifetime: "task"` on the Kubernetes task backend. `TaskWorkerExecutor` then runs every assignment in a fresh worker Pod. Without the profile, every taskMode branch is disabled and the port `pWorker` is the constant 0, so non-taskMode mixes behave as before.

- **Port `pWorker[c]`** (`spec/PortsWrk.tla`):
  - `out[l]`: the executor's return for task number `gen` of launch `l` (result fresh/saved/recovered, error, aborted, interrupted).
  - Worker Pod states, PVC records per physical attempt `w = <<l, a>>` (attempt ID = sha256(launch ID, server attempt)), the committed checkpoint manifest `ckpt` with its history `committed`, and the CP task owner per launch.
  - `att[w]`: the CP view of attempt `w`.
- **Worker_F**:
  - CJ side: the `execute()` order (ending/abort, `_completed_attempts`, `recover_checkpoint_result`, then `supervisor.run`: identity fence, staging, launch, wait, settlement, read result / failure / `TaskExecutionInterrupted`, checkpoint commit under the commit guard) and receipt-gated payload release.
  - CP side: the per-launch `_Job` owner. It admits at most one unsettled attempt; launch is idempotent; cancel of an unknown identity leaves a fence; it supports close and release, and its thread exits once every attempt has settled.
  - The worker Pod.
  - The CJ↔CP control channel is private (request/reply sets). Its loss is the fault `ctrlLoss`.
- **Worker_C** has no private state. Every outcome is constrained only by port-visible evidence.
- **Wiring**:
  - `TaskCJ_F/C` take the result from `pWorker.out` instead of the Trainer.
  - END_RUN latches `pTaskCJ.abort`; the final receipt is published as `pTaskCJ.receipt`; `TaskExecutionInterrupted` sets `pTaskCJ.fatal` (the CJ dies, and CP may replace it).
  - `JobCP_F`'s restart check needs the old launch's task owner to be done (`can_restart`).
  - `WfSJ` records `errored` (a live non-OK result reached the callback).
  - The Trainer is off in taskMode.
- **Faults**: workerCrash, workerFail, taskStageFail, ctrlLoss, settleTimeout, taskDeadline (`rarity.json`).
- **Assumptions**:
  - The app writes a checkpoint on every assignment, so every fresh OK result commits the manifest.
  - CP restart adoption is unsupported (design), so CP steps stop after `cpCrash`.
  - `system_panic` after an unconfirmed settlement is not modeled. The fenced supervisor answers later assignments with errors.
  - L5 (deadlines from the worker's monotonic clock) is a value bug and is not modeled.
- **Trace validation** is group-level (`checks/trace/worker/`):
  - `tv_worker_test.py` runs the real executor, supervisor, store and worker process through upstream's process harness, and logs port events.
  - The stand-in for the Kubernetes backend is the test `ProcessTaskLauncher`, with K8s retryable-exit semantics mirrored. CP and Pod steps are silent.
  - `gen_tv_worker.py` replays each trace against Worker_F with a trace-driven environment.

## 16. v11: breadth plan (coarse groups for the rest of the control plane)

Goal: bring the remaining high-level control-plane content into the model as **coarse** behavior, block by block (A–G), each with a smoke check and a happy-path group-level trace validation. Hunts, fine variants of the new content, large-scale TV and reproductions are out of scope for v11. The rollback point is commit `5b6f008d`.

### 16.1 Rules for v11 content

- **Profile-gated.** Every new behavior sits behind a profile switch (`Consts.ProfileSwitches`) or a priced fault (`rarity.json`). With all new switches off, every new branch is disabled and every new port is a constant, so earlier mixes keep their state spaces (checked in 16.10).
- **Coarse-only.** New behavior inside an existing group is added to its coarse variant only. `mkmc.py` refuses a mix that selects a fine variant of a group whose new profile branch exists only in the coarse module (`COARSE_ONLY`). New groups have a single variant `C`. Trainer gains an alternative implementation variant `A` (Attach), selected by grain like `X`, with no refinement receipt yet.
- **Failure outcomes are kept.** Coarse steps may merge internal steps, but every failure outcome in the block's event table has a step, or the table says why it is left out.
- **No value modeling.** Model weights, accumulator contents, timestamps and deadlines stay tokens; only their outcome classes are modeled (clean, poisoned, corrupt, missing).
- **Windows that need fine steps later** go into the list in `notes/v11-audit.md`; v11 does not split them.

### 16.2 New profile switches and faults

| Switch | Block | Meaning | Coarse-only groups |
|---|---|---|---|
| `sjModel` | A | the SJ aggregator / persistor is the separate group Model; WfSJ calls it for accept, aggregate and save | WfSJ |
| `sag` | B | ScatterAndGather workflow | WfSJ |
| `cyclic` | B | Cyclic relay workflow | WfSJ, CommSJ |
| `cseServer` | B | server-controlled cross-site model evaluation (standing validation broadcasts) | WfSJ, CommSJ |
| `swarm` | D | client-controlled Swarm (CCWF): server-side controller in WfSJ, client side in the new group Swarm | WfSJ, CommSJ, TaskCJ |
| `k8sJob` / `dockerJob` | E | CJ launched as a Kubernetes Pod / Docker container (default: process launcher) | JobCP |
| `multiJobCP` | F | a second job J2 with its own allocation and CJ lifecycle on every CP | JobCP |
| `sampling` | G | FedAvg client sampling: each round targets a nonempty subset of the sites | WfSJ, CommSJ |

The workflow switches `sag`, `cyclic`, `cseServer`, `swarm` and the existing `cseTasks` are mutually exclusive (`ASSUME`). `k8sJob` and `dockerJob` are mutually exclusive.

New faults (all priced in `rarity.json`):

| Fault | Block | Event |
|---|---|---|
| `acceptRaise` | A | `aggregator.accept` raises after mutating part of the accumulator (arithmetic or materialization error; also a lazy reference whose disk-offload backing is gone) |
| `saveFail` | A | the persistor's `save` raises (before replace, after replace, or after a partial direct write) |
| `tpAttachLate` | C | the attach trainer never opens a session before the attach timeout |
| `tpCrash` | C | the attached trainer process dies |
| `tpReplyLost` | C | a CJ→trainer control reply (TASK_ACCEPTED, RESULT_ACCEPTED/REJECTED) is lost; the trainer probes status |
| `swarmMsgFail` | D | a peer-to-peer learn / submit / status aux message fails or times out |
| `learnFail` | D | the local learn executor returns an error |
| `busyReplace` | D | a new learn task arrives while the client is still busy (abort of the current task) |
| `gatherTimeout` | D | the aggregator's gather window expires before all replies |
| `podDeleteFail` | E | the Kubernetes API fails a Pod delete (H20) |
| `slowPublish` | E | a CJ's `publish_results` handler on CP runs past its requester (H07) |
| `sjSyncFail` | G | the new SJ cannot get the participant list from SP within 30 s (#15) |
| `taskDataFail` | G | a CJ fails to download a task's input payload and asks for the task again |

### 16.3 Ports

- **New `pModel`** (`spec/PortsModel.tla`, group Model, process SJ). Constant 0 unless `sjModel`.
  - `call` / `ret`: the WfSJ→Model call-return handshake, `[op, round, site]` with `op ∈ {accept, aggregate, save, reset}` and outcome in `ret`.
  - `acc[r][c] ∈ {none, accepted, rejected, partial}`: accept outcome per round and site.
  - `poisoned[r]`: some accept of round `r` raised after a partial mutation.
  - `agg[r] ∈ {none, clean, poisoned, empty}`: the aggregate the workflow got for round `r`.
  - `artifact ∈ {initial, [round, kind]}` with `kind ∈ {clean, poisoned, corrupt}`: what the persisted model file holds.
- **New `pSwarm[c][l]`** (`spec/PortsSwarm.tla`, group Swarm, process CJ, per site). Constant 0 unless `swarm`.
  - `cfg`, `started`, `round`, `role` (trainer / aggregator of the round), `learn` (idle / busy / done / failed / aborted), `stopped` (`asked_to_stop`), `gathered[r]` (sites whose submission entered accept), `replied[r]` (sites recorded as replied), `aggregated[r]`, `report` (last status report: `[round, allDone, error]`), `final` (final result distributed).
- **Extensions of existing ports** (fields exist only under their switch, like `pTaskCJ.abort` under `taskMode`):
  - `pWfSJ`: `mcall` (call to Model), `policy` state `wfDone` (Cyclic `_is_done`), `targets` (sampling), `cw` (CCWF: `configured`, `started`, `ended`).
  - `pCommSJ`: `targets` (sampling / relay order), `relayPos` (Cyclic).
  - `pTaskCJ[c][l]`: `ccwf` (the client-controller executor's reply for config / start tasks).
  - `pJobCP[c]`: `backend` facts `podLive[l]` (K8s/Docker: the CJ container exists regardless of the CJ process view), `released[l]` (handle released transfer, secret, task owner), `wsRecord` (workspace transfer record: `[l, token]`), `j2` (J2 lifecycle on this CP: `none | starting | running | restarting | exited | freed`, its launch generation and its allocation).
- **Liveness under `k8sJob`/`dockerJob`.** `Ports.CJAlive` drops the `~CPRestarted(c)` conjunct: the CJ Pod or container does not die with the CP (no `monitor_parent_process` across containers). The restarted CP keeps no record of it (adoption is unsupported upstream, `docs/design/client_job_recovery.md`), so the CJ becomes an orphan that keeps working with the SJ.

### 16.4 New message kinds

| Kind | Owner | From → to | Body |
|---|---|---|---|
| `SWARM_LEARN` | Swarm | CJ(aggregator) → CJ(trainer) | `[round, aggregator]` |
| `SWARM_SUBMIT` | Swarm | CJ(trainer) → CJ(aggregator) | `[round, rc]` |
| `SWARM_STATUS` | Swarm | CJ → SJ | `[round, allDone, error]` (status reports ride on the client's task requests; one message per change) |
| `SWARM_END_WF` | WfSJ | SJ → CJ | `None` (end-workflow aux request) |
| `SWARM_END_REPLY` | Swarm | CJ → SJ | `rc` |
| `PUBLISH_RESULTS` | RunCJ | CJ → CP | `[l, token]` (K8s workspace transfer) |

Attach trainer↔CJ control messages stay private to `Trainer_A` (like Trainer_X's session), because no other group reads them.

### 16.5 Block A: SJ.Model (group Model)

Anchors: `dxo_aggregator.py:75-208`, `weighted_aggregation_helper.py:192-285`, `fedavg.py:221-260,300-400`, `base_model_controller.py:452-462`, `pt/file_model_persistor.py:308-360`, `np/np_model_persistor.py:103-114`, `wf_comm_server.py:655-672`.

| Event | Phase | Model step | Outcome |
|---|---|---|---|
| accept OK | result callback of round r | `Accept` | `acc[r][c] = accepted` |
| safe reject (wrong round, duplicate, shape, kind) | callback | `Reject` | `rejected`; accumulator unchanged |
| accept raises after a partial mutation (`acceptRaise`) | callback | `AcceptRaise` | `partial`, `poisoned[r]`; the callback raises: WFComm marks the task ERROR, no abort |
| aggregate | after the round's task ends | `Aggregate` | `agg[r] ∈ {clean, poisoned, empty}` from the round's state |
| save OK | after aggregate | `Save` | `artifact = [r, clean or poisoned]` |
| save raises (`saveFail`) | save | `SaveFail` | before replace: artifact unchanged; after replace: new artifact; direct write: `corrupt`; the workflow sees an exception |
| reset | round start | `Reset` | round state cleared |
| SJ crash | any | (WfSJ `Crash`) | Model stops; artifact stays |

Not modeled: numeric content, LazyAggregator's queue (H47, intentional policy), the PT in-memory update before save (H39 partly: covered by "after replace").

### 16.6 Block B: workflows (WfSJ_C policies)

Anchors: `scatter_and_gather.py:240-460`, `cyclic_ctl.py` (`control_flow`, `_process_result`), `cross_site_model_eval.py` (`control_flow`), `wf_comm_server.py:1048-1170` (relay).

| Event | SAG | Cyclic | Server CSE |
|---|---|---|---|
| round start | broadcast to all, `min_responses`, wait after min | relay in site order, one client at a time | submit-model broadcast, then one validation broadcast per model, standing together |
| OK result | Model accept | replaces the relayed model | recorded |
| non-OK result | `ignore_result_error` policy: panic or ignore | `_stop_workflow`: the workflow ends normally (no panic) | logged |
| callback raises (`cbFail`, `acceptRaise`) | task ERROR; SAG does not check the status and aggregates | stop workflow | task ERROR |
| task timeout / assignment timeout | task ends with what it has | client skipped | task ends |
| abort signal | checked before aggregate and before save | checked per round | checked in the wait loop |
| aggregate / convert raises | panic | — | — |
| save raises | panic | panic | — |
| resend after a lost reply (cseTasks-style duplicate ClientTask) | — | — | monitor may die (H11, same coarse step as `cseTasks`) |

### 16.7 Block C: Attach trainer (Trainer variant A)

Anchors: `attach_backend.py:351-640,746-832`, `cell_backend.py:195-290`, `client/cell/attach_session.py:260-537`, `client/cell/api.py` (send, RESULT_SOURCE_SETTLED).

| Event | Phase | Outcome at the Trainer port |
|---|---|---|
| trainer attaches | before or after the first task | session open |
| no session before the attach timeout (`tpAttachLate`) | first task | executor error (`stopped`) |
| task delivered; TASK_ACCEPTED lost (`tpReplyLost`) | delivery | status probe resolves; RESULT_READY also counts as delivery |
| training, RESULT_READY (attempt 1, retry attempt 2) | result | `published` once the CJ accepts |
| task closed before acceptance | result | RESULT_REJECTED; if both replies are lost the trainer infers success (H01, private outcome) |
| abort / result wait timeout | waiting | TASK_ABORTED / error; abort sent to the trainer |
| trainer crash (`tpCrash`) or silence (`tpSilent`) | any | session lost: error for the current task |
| RESULT_SOURCE_SETTLED | after receivers finish | source released |
| CJ finalize | run end | shutdown request, listener close, wait for source release (H24 window recorded, not split) |
| CJ crash | any | session gone |

### 16.8 Block D: Swarm (WfSJ_C `swarm` policy, group Swarm, TaskCJ_C routing)

Anchors: `ccwf/server_ctl.py:231-540`, `ccwf/client_ctl.py:344-600`, `ccwf/swarm_client_ctl.py:116-290,555-1030`, `ccwf/client_controller_executor.py`.

| Event | Phase | Outcome |
|---|---|---|
| config broadcast; fewer than `min_clients` replies within the configure timeout | config | SJ panic |
| start task to the starting client fails | start | SJ panic |
| learn task scatter to a trainer fails (`swarmMsgFail`) | round r | that trainer misses the round |
| local learn error (`learnFail`) | round r | error result submitted, or error status report → SJ panic |
| busy replacement (`busyReplace`) | round r | ABORT_TASK fired; the client's own controller treats it as a stop (H06) |
| submit to the aggregator fails (`swarmMsgFail`) | round r | aggregator misses the contribution |
| gather closes on all-replied before the last reply entered accept | gather | `replied` ⊋ `gathered` (H05 window, coarse nondeterminism) |
| gather timeout (`gatherTimeout`) | gather | aggregate what was gathered, or fail below the minimum |
| aggregator / any CJ crash | any | the swarm stalls; SJ progress / report timeout panics |
| status report silent for `max_status_report_interval` | monitor | panic (min_clients = 0) or prune |
| ALL_DONE / final result distribution | end | SJ ends the workflow: END_WF to all; too few replies → panic |

### 16.9 Blocks E, F, G (JobCP_C, CommSJ_C, WfSJ_C, JobSP_C patches)

E (anchors `job_launcher/k8s_launcher.py:308-745`, `docker_launcher.py:280-410`, `workspace_cell_transfer.py:333-475`):

| Event | K8s | Docker |
|---|---|---|
| CP crash | CJ Pod survives; new CP has no record (orphan) | container survives; same |
| terminate | Pod delete; API failure (`podDeleteFail`) still marks TERMINATED and releases transfer record, secret and task owner (H20) | stop+remove; API failure keeps the handle (no release) |
| exit observation | Pod phase; restartable rc classes | container wait; NotFound → ABORTED |
| `can_restart` | Pod UID unchanged, shutdown confirmed, task owner thread done, workspace download complete | exit confirmed and not terminating |
| workspace publish (K8s) | `publish_results` handler; a slow handler of the old launch (`slowPublish`) removes the replacement's record (H07) | — |
| GPU environment | from the allocation (no CP-global env) | from the allocation (`DeviceIDs`) |

Slurm is deferred: its batch scheduler semantics (queueing, `scancel`, accounting states) need cluster behavior to be written accurately; recorded in `notes/v11-audit.md`.

F (`multiJobCP`): J2's START (allocate + env consume, the existing `otherJob` write), spawn, exit, restart (snapshot of the CP-global env, H08 in both directions), outcome, free, abort; the CP restart kills both jobs' CJs (process launcher); the heartbeat lists both. J2 is CP-local: the SP side keeps the existing `multiJob` summary.

G:
- `sjSyncFail` (#15): the new SJ exits with an error before opening the workflow.
- `taskDataFail`: SJ→CJ input download failure. Eager path (the payload is downloaded while the GET_TASK reply is decoded): `pull_task` gets a non-OK return code, the CJ asks again, and the server's resend path runs (H11's trigger). Lazy path (`resolve_task_data` fails in `_process_task`): the CJ submits BAD_TASK_DATA as the task's result.
- `sampling`: per round, a nonempty target subset; only targets get assignments; the round completes when the targets finished.
- CP restart adoption: covered by E (orphan CJ under `k8sJob`/`dockerJob`); under the process launcher the CJ dies with the CP (unchanged).
- H31 (a new transaction per submission try) is deferred: the payload ports are keyed by attempt (`pPaySrc[c][l].tx[a]`), so a per-try transaction changes the port shape of PaySrc and PayRcv in both variants (PaySrc_F is 1,654 lines). The server deduplicates by receipt, and H31 is a contract baseline.

### 16.10 Checks per block

1. `gen_mix` static checks and SANY.
2. Smoke (simulation): with the block's switch on, the job reaches a terminal status (reachability witness), and each fault in the block's table reaches its outcome (one witness each). For groups with an environment module, `AG_<G>` holds in a mix by simulation.
3. Existing groups whose coarse module changed: their fine→coarse refinement with all new switches off, to a budget, plus the negative control (BadStep).
4. Non-interference with all new switches off: two or three previously exhaustive BFS configurations give the same distinct-state counts; the real POC trace is still accepted on all-fine and all-coarse; the D-track known bugs are still found.
5. Happy-path TV: at least one real trace accepted and one mutated trace rejected per block, replayed group-level against the coarse variant (acceptance on a coarse variant is weak evidence, stated as such).
