# Design review: multi-grained composition framework (NVFlare slice)

Reviewer: skeptical framework review, 2026-11-03 ~18:40 UTC. Scope: framework (Consts/Ports/Props, generated Mix, gen_mix/gen_ref/mkmc/run_mc/tlc.sh, DESIGN.md, contract), plus the coarse variants. Files were moving during the review, so I worked on two copies: `.tmp/review/snap/` (17:55 UTC, with WfSJ_M, before the agents rewrote the coarse variants) and `.tmp/review/snap2/` (18:19 UTC: new DESIGN proof, `fatal`/`CJGone` in Ports, rewritten `*_C`, Trainer group). Line numbers refer to the 18:19 files unless marked "snapshot".

Evidence levels: every TLC number below is a bounded check of one finite instance (1 or 2 sites, MaxLaunch = MaxAttempt = 1) run in scratch copies under `.tmp/review/exp_*/`, with 16 workers. Results are in `exp_*/checks/results/*.json` and `exp_*/logs/*.log`. Nothing here is a proof.

## Ranked issues

| # | Severity | Issue |
|---|---|---|
| 1 | Critical | Net writes are unconstrained. A fine variant can rewrite or resurrect other groups' messages, and the refinement check accepts this as a stutter. Demonstrated: the transfer claim fails. |
| 2 | Critical | Refinement receipts are not tied to the campaign instance (Net=R by default, the agent's own fault subset, 1 site, MaxAttempt fixed at 1). DESIGN condition 1 is violated by the contract itself. |
| 3 | High | Other proof gaps: AbsC can move on other groups' steps, port reads are unchecked, and the proof covers only two variants per group. |
| 4 | High | Liveness oracles in Ports. `killed` counts as dead the moment it is issued (NoFreeWhileChildAlive is vacuous on the kill path; TLC witness below). `CJGone` is a perfect failure detector. |
| 5 | High | Live generator bug: a group with no message kinds gets no `UNCHANGED net`. The live all-coarse happy path stops with "not completely specified ... net". |
| 6 | High | DESIGN §6 (trace validation per mix) has the transfer direction wrong. |
| 7 | High | Key scheme vs retries and duplicates. `Send` silently overwrites, deduplication by key hides duplicate processing, and one mailbox serves every incarnation. |
| 8 | Medium | Static-check gaps beyond net: helper EXTENDS, writes silently disabled by the frame, the kinds regex, Init determinism. |
| 9 | Medium | Coarse modeling mistakes. A panicked SJ exits clean, making FINISHED reachable (f1_all CE); stuck paths make terminal properties vacuous; some properties restate coarse guards; the "coarse" variants are not coarse. |
| 10 | Medium | Checkability: a quadratic Inbox pattern (6.9x time) and private-only steps. 194,428 → 34,725 states with four small edits; loss at send cuts states 7.3x. |
| 11 | Medium | Operational: `tlc.sh` leaks the metadir on every violation (`.tlc` is 3.0 GB), and `run_mc.py --timeout` leaves orphan JVMs. |
| 12 | Low | Naming and documentation drift. |

---

### 1. [Critical] Net writes are unconstrained, so "holds in mix ⇒ holds in all-fine" is false as implemented

Evidence:
- `gen_mix.py:64` and `:230` treat `net` as owned by every group. The static check only knows "net is primed" (`:65-70`) and literal `Msg("KIND"` patterns (`:71`). `net' = [net EXCEPT ![k].msg.body = ...]`, lost-flag flips, key deletion and `net' = [k \in ... |-> ...]` all pass.
- `Consts.tla:29-31`: `Send` replaces an existing key's body and resets `lost |-> FALSE`. `Fresh` (`:37`) exists, but `Send` does not use it.
- The refinement check accepts all of these as stutters. `RefStep == [][CRef!Next \/ UNCHANGED <<AbsC, Proj_G>>]_allVars` (`gen_ref.py:50`), and `Proj_G = <<pG, SentKinds(G's kinds)>>` excludes lost flags and other groups' messages. DESIGN.md:53 lists "Proj_G covers everything G writes that others can read" as a condition, but nothing enforces it.

Demonstration (`exp_rogue/`): I built `TaskCJ_X` as a copy of TaskCJ_C plus one step `Tamper(c,l,k)`, which flips a CommSJ-owned `RESULT_RECEIPT` body from `"REJECTED"` to `"RECEIVED"` with `UNCHANGED <<taskCJ_x, pTaskCJ>>`. Faults `{pullTimeout}`, 1 site.
- `gen_mix.py`: "static checks passed for 12 variants".
- `gen_ref.py TaskCJ X C`: `pass_exhaustive`, 2,035 states.
- Mix with TaskCJ=C: all PORT_INVS pass (1,747 states).
- Mix with TaskCJ=X: `ReceivedReceiptMeansFinished` is violated after 156 states.

So a property that holds in the coarse mix fails in the "finer" mix, although every check passed.

This is not hypothetical in the live code. With the assertion below, the live all-coarse mix (Net=L, faults abort, netLoss, cjCrash, taskTimeout, sjCrash; `exp_live/logs/live1_strict.log`) fails at depth 22 on `Step_JobSP_C_HeartbeatStop`. `JobSP_C.tla:285-290` re-sends an existing key when `net[key].lost` is TRUE: the sender reads the loss flag (an oracle) and resurrects the message by overwriting it.

Fix (prototype tested in `exp_rogue/scripts/gen_mix.py`): emit a fail-loud net-discipline assertion in every generated step.
```python
# gen_mix.py, before the INSTANCE lines
L.append("NetKeep == DOMAIN net \\subseteq DOMAIN net' /\\ \\A k \\in DOMAIN net : net'[k] = net[k]")
L.append("NetOK(g) == NetKeep /\\ \\A k \\in DOMAIN net' \\ DOMAIN net : KindOwner(net'[k].msg.kind) = g /\\ ~net'[k].lost")
L.append("NetLossOK == DOMAIN net' = DOMAIN net /\\ \\A k \\in DOMAIN net : net'[k].msg = net[k].msg /\\ (net[k].lost => net'[k].lost)")
# per step
chk = "NetLossOK" if gd.get("writes_net_loss") else f'NetOK("{g}")'
body = f'/\\ Grain["{g}"] = "{v}" /\\ {call} /\\ {frame_s} /\\ Assert({chk}, "net discipline: {name}")'
```
Results:
- The rogue mix now fails with `Assert ... "net discipline: Step_TaskCJ_X_Tamper"`.
- The snapshot all-coarse model satisfies the assertion: 1 site with all seven faults (3,493,104 states), Net=L (20,358 states) and 2 sites (194,428 states).
- Cost: 2-site happy path 23 s → 29 s.

Also add a static rule: no `.lost` may appear in a variant unless `writes_net_loss`. Add `msg.from \in ProcsOf(g)` to `NetOK` if you want sender-identity checks too.

Keep `NetKeep` strict (no identical resends). Allowing a resend of an identical message that resets `lost` would again pass RefStep as a stutter while changing what receivers see (Proj_G has no lost flags). Retries need fresh keys (issue 7).

### 2. [Critical] Refinement receipts do not match the instances they are used for

The DESIGN proof (DESIGN.md:39-54) needs "the refinement checks are exhaustive for the same constants". The tooling and the contract break this:
- **Net variant.** `gen_ref.py:47` passes only `grain[group] = fine`. `mkmc.py:26` picks the first variant for groups without "C", so the Net group gets **R** (see `checks/mixes/MC_ref_WfSJ_M_C.tla`). No refinement receipt covers a Net=L campaign (e.g., `f1_lossy`). Under loss, the fine variant reaches states (waiting on a lost reply, timeouts) that never occur with R.
- **Faults.** The contract (IMPLEMENTATION-CONTRACT.md:39) says `--faults <your faults>`. Faults read by the environment (cjCrash, sjCrash, abort, netLoss) then never fire in the refinement check, so the fine variant's states under those faults are unchecked. Worse, fault gating is not monotone for refinement. If a fine step is ungated (or gated by fault φ) and matches a coarse step gated by ψ, the check passes with ψ enabled but transfers to no campaign without ψ. Realistic case: a fine PaySrc "shutdown clears refs, later pulls get an error" step is matched by coarse `Retire` via `"txTimeout"`. A campaign for the H30 straggler path without txTimeout then has a coarse PaySrc that can never produce those error replies.
- **Bounds.** The contract says "--sites 1, then 2 if tractable", while `mkmc.py` defaults to 2 sites. `gen_ref.py` has `--launch` but no `--attempt` (MaxAttempt is always 1), so stale-attempt hazards can never have a receipt.
- **Exhaustiveness.** `run_mc.py` labels timeouts `budget_stopped`, but nothing consumes this.

Fix:
- Make the receipt key explicit: `(Sites, MaxLaunch, MaxAttempt, Faults, Grain[Net], LossBudget, symmetry)`, written into `checks/results/ref_*.json`.
- `gen_ref.py`: default to `Net=L` with `netLoss` (L with loss enabled covers R); add `--attempt`; default `--faults` to the union of the campaign fault sets in `checks/scenarios.json`; better, run one refinement per distinct campaign instance (they are cheap at 1 site once issue 10's Inbox fix is in).
- `campaign.py`: label a result "transfers to finer mixes" only if every group that is fine in the target mix has an exhaustive receipt whose key equals the campaign's. Otherwise label it "mix-local".
- Change contract line 39 accordingly. "In every environment" (DESIGN.md:34) is neither checkable nor needed. Replace it with "in the all-coarsest environment, with the campaign's constants".

### 3. [High] Remaining proof gaps (AbsC, reads, more than two variants)

Precise conditions under which DESIGN's claim holds. Let M ≤ M' be mixes, M' finer pointwise. A safety property over ports, plus the privates of groups whose variant is the same in M and M', transfers from M to M' if:
1. **C1 Same instance.** Every group whose variant differs has an exhaustive receipt with exactly M's constants, Net variant and loss budget (issue 2). This covers every group that is fine in M', not only the one under study: the induction maps all of them at once.
2. **C2 Single environment.** Each receipt was produced with every other group at its coarsest variant. The circular induction then covers every finer environment. This needs no receptiveness argument, because steps never synchronize: each step constrains only its own group's writes. DESIGN §2.4 can drop "never blocks" and keep "guards read only ports and own privates".
3. **C3 Net discipline (issue 1).** Existing keys are immutable, new keys carry only the stepping group's kinds, and only Net flips lost flags.
4. **C4 Write isolation.** The generated frames enforce it, but see issue 5 and issue 8 (silent disable).
5. **C5 Read isolation and stable abstraction.**
   - The guards, effects and AbsC of every variant depend only on its own privates and the ports. This includes operators reached through helper modules; today the check is textual and per file.
   - **AbsC_G must not change on other groups' steps.** The proof's case "G not in S: ... it leads to t|S" (DESIGN.md:46) silently assumes this. If AbsC_G reads pH or `net` (natural for a coarse `handled` set: "keys of kind X that I have passed"), then an H step also moves G's coarse private. The mapped behavior then contains a joint H+G step, which the mix does not have. RefStep may even accept it, by matching a private-only C_G action.
   - Fix (`gen_ref.py`): add `RefEnv == [][UNCHANGED <<FinePrivs, Proj_G>> => UNCHANGED F!AbsC]_allVars` to `props`, and a static rule that the AbsC body mentions only the variant's own privates and its own port.
6. **C6 Same encoding.** This holds automatically for fields in Proj_G (refinement rejects values the coarse variant cannot produce), but only if the neighbor's receipt exists. A neighbor that is WIP poisons every claim for mixes containing it. Add a per-port `TypeOK` to `Ports<Comp>.tla` and check it in every mix, so encoding drift fails early.
7. **C7 Chains.** With more than two variants (C/M/F, as WfSJ had), checks of F ⊑ C and M ⊑ C say nothing about F ⊑ M. Generic counterexample: C allows port values {a, b}, M produces only a, F only b. Then `port /= b` holds in the M-mix and fails in all-fine. Fix: add a `"refines": "<variant>"` edge per variant in the registry, run a receipt per edge, and transfer only along chains.
8. **C8 Init.** RefInit passes and every Init is deterministic (issue 8).

Under C1-C8 I believe the induction in DESIGN.md:41-49 is correct. Without C3 and C5 it is not, as issue 1 shows.

Q1 sub-answers:
- **What Proj_G excludes.** Lost flags (fine only under C3); other kinds' messages (the hole); consumption (correctly excluded, since consumption is private); reads (not part of a step relation, so oracle reads by a fine variant are invisible to refinement and need the static check in issue 4).
- **"Can a fine step match a coarse action enabled for an unrelated reason?"** For port-visible steps the match fixes `net'`, the port and `AbsC'` completely. Any C_G step is then a legal coarse step, and the reason it was enabled is irrelevant to soundness. It matters in three places: the stutter disjunct (issue 1); fault-gated matches under a different fault set (issue 2); private-only matches triggered by AbsC moving on environment steps (C5).

### 4. [High] Ports-level process facts are oracles (kill = death; CJGone)

- **Kill is immediate death.** `CJAlive` (Ports.tla:48-50) is false as soon as `l \in pJobCP[c].killed`. `CJExitCode` (:52) reports "killed" right away, and JobCP_C ObserveExit takes `killed` as the child's exit.
  - TLC (`exp_inbox`, `w_kill`, faults {abort}, 1 site): `NoFreeWhileChildAlive` passes, while `NoFreeWhileRunCJRunning` (freed > 0 ⇒ no launch with `exit = "none"` and state ∈ {initialized, running, stopping}) is violated after 208 states. The trace is Launch → Initialize → RecvAbort → ObserveExit → ReportOutcome → FreeAllocation, with RunCJ's own port still saying "initialized".
  - Real code is asynchronous and can fail: `process_launcher.py:60-70` sends SIGKILL to the group, or only `adapter.terminate()` when it does not own the group; `:78-93` waits for the group with a bound. The model cannot express H19, H20, H21 or H49 through this property, whatever fine variants are written. All variants are forced to share one notion of liveness.
  - Fix: JobCP writes only intent (`killReq`). Add a RunCJ step `DieOfKill(c,l) == l \in pJobCP[c].killReq /\ pRunCJ[c][l].exit = "none" /\ pRunCJ' = [... exit = "killed"]`, with no fairness, so the kill may never land. `CJAlive` then drops the `killed` conjunct, and ObserveExit requires `pRunCJ[c][l].exit /= "none"`.
- **CJGone is a perfect failure detector.** `CJGone` (Ports.tla:57) lets SJ groups observe CJ death "at any later time". The coarse (`PayRcv_C.tla:34`) and fine (`PayRcv_F.tla:47,337`: "no fault toggle needed") PayRcv variants react to it. A peer can therefore never look dead while alive (connection drop, slow peer). That is exactly the false suspicion that feeds H29: SJ `os._exit` on transport failure while the CJ could still recover. Fix: `PeerFailure(c,l) == CJGone(c,l) \/ ("transportFail" \in Faults /\ CJAlive(c,l))` for all cross-process reactions, keeping the property that death may never be observed (H40).
- **Cross-process reads are unenforced and under-documented.** DESIGN.md:75 lists four reads. In practice TaskCJ, PaySrc and Trainer read pJobCP through CJAlive; every same-process group reads every other group's `fatal`; and SJ groups read CJ ports through CJGone. Nothing checks port reads by process. Fix: give each registry group `process` plus an allowlist (`"reads": {"pJobCP": ["launch", "killReq"]}`). In gen_mix, reject any mention of a foreign-process port variable outside the allowlisted Ports operators, and apply the same check to AbsC.

On the question "coarse PaySrc guards on CJAlive while the fine one does not": refinement then fails (fine acts where coarse cannot), so this is detected rather than hidden. The real coupling is the reverse: Ports fixes the semantics of liveness for every variant, and its current definition hides the hazards above.

### 5. [High] Live generator bug: groups without kinds leave `net'` unassigned

`gen_mix.py:230` always counts `net` as owned, so the frame never contains `net`. Trainer has `"kinds": []`, and Trainer_C actions never mention `net`. Live all-coarse, 1 site, no faults (`exp_live/logs/live3.log`): "Error: Successor state is not completely specified by action Step_Trainer_C_Stop ... The following variable is not defined: net", after 18,068 states. Every live mix that enables a Trainer step is currently broken.

Fix (in both `static_check` and `gen_mix`):
```python
own = set(vd["vars"]) | ({gd["port"]} if gd["port"] else set())
if gd["kinds"] or gd.get("writes_net_loss"):
    own.add("net")
```
Also add a `gen_mix.py --smoke` that runs the 1-site all-coarse BFS (seconds). SANY alone cannot catch this.

### 6. [High] Trace validation per mix: the transfer direction is wrong

DESIGN.md:113 says a real execution "can be checked at port level once, and that one check applies to every mix". Port behaviors satisfy Beh(finer) ⊆ Beh(coarser). Acceptance therefore transfers **upward only** (all-fine accepts ⇒ every coarser mix accepts), and rejection transfers downward. Acceptance by a coarse mix says nothing about fine variants.

Fix: replay the positive trace on the finest mix available (all-fine), and run the negative controls on all-coarse; these two runs cover every mix. Report a coarse-only acceptance as "coarse replay". Also, "a silent step leaves every port unchanged" clashes with owner-only port fields (e.g. `pJobSP.status`, stage-like fields) unless every such field is either probed or marked optional. This is one more reason for the exported projection in issue 10.

### 7. [High] Net semantics: retries, duplicates and incarnations

- **Retries.** A retry with the same key is a silent overwrite (issue 1). A retry with a fresh key needs a sequence number, and most ids lack one: GET_TASK and RESULT_ENVELOPE use `<<JobId,c,l>>`; PAYLOAD_PULL uses `<<"pull",ref,n>>`; confirm and cancel use `<<"confirm"|"cancel",ref>>`. With ref reuse, H09's old and new CANCEL collapse into one key. Live TaskCJ_C has started using `SubmitId(c,l,n)` (good). Make this the rule: `id` includes `seq \in 1..MaxRetry` for every retry-capable kind, and Send asserts `Fresh`.
- **Duplicates.** Deduplicating by key per receiver means a duplicate is never processed twice. H31 ("duplicate envelope replays RECEIVED") and H11 need duplicates the receiver actually processes, and those must come from sender retries with distinct keys. That is fine once ids carry `seq`.
- **Incarnations.** Messages to `CJ(c)` are visible to every launch. END_RUN's id has no launch, and RunCJ keeps per-launch `handled` sets. One END_RUN can therefore be consumed by launch 1 and again by launch 2. In reality a cell message reaches whichever incarnation is listening, once. This over-approximation can produce spurious CEs. Fix: key `handled` per process name for ids without a launch, or put the target launch in the id.
- **Loss after delivery.** Net_L `Lose(k)` does not require the message to be pending, and Net cannot know that, because consumption is private. Losses after consumption are pure state splitters. They also change multi-reader messages and inbox-presence guards. Loss at send fixes both (issue 10).

### 8. [Medium] Static-check gaps beyond net

- **Helper modules.** A variant may `EXTENDS` a helper module that declares a foreign private and defines operators over it. The variable comes into scope without appearing textually in the variant, so `gen_mix.py:80-83` and the declaration check (`:75-79`, current file only) miss it. Plain INSTANCE of another variant is caught, because the name must appear in WITH or VARIABLE. EXTENDS of another variant fails in SANY on duplicate `Init`/`Next`. Fix: allowlist `EXTENDS`/`INSTANCE` targets (Ports, Consts, Ports*, standard modules), and forbid `VARIABLE` in non-registry modules.
- **Writes through helpers are silently disabled.** A write to a foreign variable through a helper operator is not flagged; the generated frame makes that step FALSE. This prunes behavior silently, which is unsound for the "coarse over-approximates" side. Fix: run campaigns with `-coverage` and require every `Step_*` of a selected variant to fire somewhere, or move to a semantic check through `tla2sany.xml.XMLExporter` (present in `lib/tla2tools.jar`), computing transitive primed and read sets per `Step_*`.
- **Kinds regex.** `Msg\(\s*"KIND"` misses record literals, `Msg(kindVar, ...)` and helper constructors in `Ports<Comp>.tla`, which are shared by all groups of one component. The `KindOwner` test in `NetOK` (issue 1) subsumes it dynamically.
- **Init determinism.** Mix Init conjoins every variant's Init, so a nondeterministic Init in an unselected variant multiplies initial states. Generate `IF Grain["G"] = "V" THEN G_V!Init ELSE var = G_V!InitValue`.

### 9. [Medium] Coarse modeling mistakes that mislead cross-component checks

| Issue | Evidence | Status at 18:19 |
|---|---|---|
| A failed round or workflow panic exits cleanly, so SP reports FINISHED | f1_all CE: TaskTimeout retires the only site → CloseRound "failed" → WorkflowDone → Exit `sj="exited"` → FINISHED, violating `FinishedJobSaved` (`checks/results/f1_all.json`). Real code: `fedavg.py:389-390` raises; `server_runner.py` (workflow `control_flow` except) calls `system_panic`; SJ reports `UPDATE_RUN_STATUS{execution_error}` (`fed_server.py:595-603`); SP classifies `FINISHED_EXECUTION_EXCEPTION` (`job_runner.py:615-618`). | **Still present.** `WfSJ_C.tla:89` RaiseReturn sets `pWfSJ.panic`, but Exit (`:128`) still sets `"exited"`, and `SJExitCode` (Ports.tla:62) and `SJCrashed` (JobSP_C.tla:43) ignore `panic`. Fix: `SJExitCode` returns `"error"` when `pWfSJ.panic`, and Classify maps it to FAILED. The f1_all CE is a coarse artifact. |
| SP waits for every client outcome forever (no grace, no server-failure or abort skip) | Snapshot TLC: once START is sent, an SJ crash before END_RUN can never reach a terminal status (`w_sj` pass at 3,026 states; reachable: `w_sj_reach` at 86). A lost OUTCOME never reaches one either (`w_out` pass at 1,648; reachable at 992). Real: `job_runner.py:506-533` (grace, skip on server failure or run_aborted), `:625-636` (abort clients). FinishedJobAllOk was a tautology of FinalizeJob's IF. | Live JobSP_C adds OutcomeGraceExpired and Classify, which looks fixed. Rerun the same witnesses on the live mix. |
| An abort before launch never reports and keeps the allocation | Snapshot: `w_abort` pass at 10,963 states; aborted ∧ launch=0 ∧ allocated is reachable (106 states). | JobCP_C rewritten; not rechecked. |
| Kill is instant death | Issue 4 (`w_kill`). | Still present (Ports.tla:48-52). |
| RunCJ Stop waits for the receipt (`receipt /= "waiting"`), which hides H30 (END_RUN aborts the in-flight submit) | Snapshot RunCJ_C Stop. | Removed in live RunCJ_C. |
| WfSJ Decide compares the payload to a ground truth, `materialized = ResultValue(c, attempt)` | Snapshot WfSJ_C/WfSJ_M Decide. Real FedAvg skips only empty params (`fedavg.py:301-305`). The oracle filters exactly the stale-data hazards. | Removed in live WfSJ_C. |
| A sender learns about the loss of its own message | `JobSP_C.tla:288` reads `net[key].lost` (issue 1). | New. Resend periodically with a fresh `seq` instead. |
| Properties restate coarse guards | Snapshot: ClaimNeedsMaterialized is CommSJ_C Claim's guard, AcceptedWasClaimed is Decide's guard, FinishedJobAllOk is FinalizeJob's IF. They cannot fail with that group coarse. A violating fine variant shows up first as a **RefStep failure**, not as an MC CE. | Add to the §4 triage: a refinement failure on a hazard-relevant guard is a candidate bug; loosen the coarse variant, never the fine one, then rerun MC. |
| "Coarse" variants are not coarse | Live JobSP_C: 40 actions, 22 of them private-only (stage bookkeeping: Claim, Release, RegisterRunning, DeployEval, SelectCompletion, ...). PaySrc_C and PayRcv_C have 4 each. Each private-only step is a pure state splitter. | Merge each private-only step into the next port-visible step. Rule 2 allows this: private steps map to stutters. Have `gen_mix.py` warn on private-only actions in `_C` modules. |

### 10. [Medium] State space and checkability: measured reductions

Base: snapshot all-coarse, 2 sites, no faults, symmetry on, PORT_INVS, 16 workers. Each row is cumulative.

| Change | Distinct states | TLC time |
|---|---|---|
| baseline (`exp_inbox` before the rewrite; reproduces the 194k) | 194,428 | 2 min 38 s |
| `k \in Inbox(p,kind)` → `InInbox(k,p,kind)` (Ports.tla predicate) | 194,428 | 23 s |
| + drop JobCP_C RecvReady (`ready` is never read) | 86,803 | 11 s |
| + merge OutcomeReturned into FreeAllocation, CompleteSettlement into RecordOutcome | 50,983 | 8 s |
| + replace private receives (JobSP RecvResourcesOk, RunCJ RecvEndRun) by inbox-presence guards | 34,725 | 5 s |

Lossy net, 1 site, Net=L, netLoss, budget 1 (`exp_loss`): loss anytime gives 20,358 states; loss at send gives 2,778 (7.3x), and PORT_INVS pass in both. For scale: 1 site with all seven faults is 3,493,104 states (2 min 10 s with the Inbox fix). Two sites with all faults is out of reach without these reductions.

Recommendations:
1. **Inbox predicate.** Sound, a pure rewrite, and the biggest win. `k \in Inbox(..)` under `\E k \in DOMAIN net` rebuilds the set for every k, which is O(|net|²) per action. Add `InInbox(k, p, kind) == net[k].msg.to = p /\ net[k].msg.kind = kind /\ ~net[k].lost` to Ports.tla and rewrite (`sed -E 's/([A-Za-z_]\w*) \\in Inbox\(/InInbox(\1, /'`, but not inside set comprehensions). The live `k \in Envelopes(c)` and `SentKeys(...)` patterns have the same cost.
2. **Exported projection.** Most port fields are read only by their owner, for example `pPaySrc.settled`, `pTaskCJ.envelopeSent`/`done`, `pJobCP.allocated`/`exitSeen`/`reported`, `pWfSJ.open`/`done`/`endSent` and `pPayRcv.want`. Proj_G includes them, so every flip must match step for step, and merging is forbidden. Compute exported fields as those read by another group or by Props, set `Proj_G` = exported fields + G-kind messages, and move the rest to private. Rows 3-4 are sound only under this change, and only if the fine counterparts are port-invisible.
3. **Loss at send** (sound for single-consumer messages; it also removes the after-delivery artifacts in issue 7):
   ```
   LossChoices(n) == IF "netLoss" \in Faults /\ Cardinality({k \in DOMAIN n : n[k].lost}) < LossBudget THEN BOOLEAN ELSE {FALSE}
   SendB(b, n, m) == [k \in DOMAIN n \cup {MsgKey(m.kind, m.from, m.to, m.id)} |-> IF k = MsgKey(m.kind, m.from, m.to, m.id) THEN [msg |-> m, lost |-> b] ELSE n[k]]
   \* in variants:  /\ \E lb \in LossChoices(net) : net' = SendB(lb, net, m)
   ```
4. **Symmetry.** `Permutations(Sites)` is already on and worth at most 2x at 2 sites. It is sound for PORT_INVS and RefStep while no CHOOSE ranges over site-dependent sets and AbsC is symmetric. Keep it off for trace replay. Launches are ordered, so no symmetry there.
5. **VIEW.** Not recommended: dropping `handled` or consumed messages is sound only for bisimilar states, and inbox-presence guards and SentMsgs-based Props read old messages. Delete dead private fields instead (`paySrc_c.served`, `wfSJ_c.started`, `commSJ_c.requests` in the snapshot). They cost nothing in states; the receive steps that write them do.
6. **Action splitting in Mix.** No effect on states. To save evaluation, hoist `Grain["G"] = "V"` outside the `\E c, k` binders, or generate a per-mix root containing only the selected variants.
7. **Per-site grain.** Grain is per group. For per-site groups (JobCP, RunCJ, TaskCJ, PaySrc, Trainer), allowing `Grain[g][c]` makes s2 coarse while s1 is fine. That is enough for CloseRound-type hazards, and much cheaper than both sites fine. The same induction applies per (group, site) instance; it costs symmetry and needs per-instance receipts.
8. **Constraints.** Per-campaign CONSTRAINTs on crash or timeout counts are fine, but label the results as bounded. Use `-simulate` for 2-site runs with fine groups.

### 11. [Medium] Operational: metadir leaks and orphan JVMs (matters on this full disk)

- **Metadir leak.** `tlc.sh:5` sets `set -euo pipefail`. A non-zero TLC exit (every violation, every error) aborts before `rm -rf "$meta"` (`:23`). Confirmed: my 6 violating runs left 6 metadirs, and one error run left 208 MB (removed). `W/.tlc` currently holds 3.0 GB. Fix: `trap 'rm -rf "$meta"' EXIT`, then `set +e; java ...; rc=$?`.
- **Orphan JVMs.** `run_mc.py:65-69`: `subprocess.run(..., timeout=...)` kills only the `tlc.sh` bash on timeout, so java keeps running with ppid 1. My own `budget_stopped` simulation run left one, which I killed. Orphans seen at about 18:35: pid 2440673 (`MC_ref_WfSJ_M_C`, more than 45 min), 2579907 (`MC_job_allC_s1_w`), 2591368 (`MC_pay_cc_witness`), 2598524 (`MC_fed_allC_s1_w`), 2610042 (`MC_pay_cc_witness_sim`), 2620494 (`MC_pay_cc_reg`). They compete for CPU with every agent's checks. Fix: `Popen(..., start_new_session=True)`, then `communicate(timeout=...)`; on timeout `os.killpg(p.pid, SIGTERM)`, wait 10 s, then SIGKILL. In `tlc.sh`, forward TERM to java.

### 12. [Low] Smaller items

- `Step_PayRcv_C_Pull_1` is `Pull(c, 2)` (snapshot Mix:96). Name split steps by their literal arguments, because CE triage reads these names.
- DESIGN.md:37 says `checks/refinement/Ref_<G>.tla`, but receipts land in `checks/mixes/MC_ref_*`.
- `--negative` only maps C's private to its Init. Also add a port-side mutant (e.g., RefStep with one coarse disjunct removed must fail) to show that Proj_G mismatches are caught and that every coarse action is exercised by the fine variant.
- `RefInit` as a PROPERTY triggers TLC's state-formula warning, which is harmless and intended; say so in the receipt.
- `Has(r, f)` optional port fields (Ports.tla:43) make guards depend on record shape. Prefer fixed shapes (`fatal |-> FALSE` in the PortInit) and a TypeOK.

## Answers to the four questions

1. **Soundness.** RefStep is the right shape. It is sound only under C1-C8, and today C1 (issue 2), C3 (issue 1) and C5 (issue 3) are not enforced. Counterexample to the stated claim: `TaskCJ_X` (issue 1, run with TLC), plus the generic three-variant chain counterexample (C7).
2. **Decoupling.** The static check does not enforce net ownership, resend semantics or reads (issues 1, 4, 8). The cross-process facts are not a soundness hole for refinement, which detects them, but they hard-code oracle semantics (issue 4). The append-only log with private consumption is good, but needs `seq` ids, a Fresh-asserting Send and loss at send (issue 7).
3. **Checkability.** Issue 10: 6.9x time from one sound rewrite, 5.6x states from four small coarse edits, 7.3x from loss at send.
4. **Coarse modeling.** Issue 9. Still present at 18:19: panic → clean exit → FINISHED, and kill = death. Since fixed in the live coarse variants: the receipt guard on Stop and the Decide oracle.

## What is solid

- One generated root with `Grain` as a constant, interleaving composition and generated frames. No group can change another group's port or privates; the only exceptions are net and a variant that leaves its own variables unassigned, which TLC reports.
- Every snapshot coarse action constrains its whole write set (scripted check: 0 gaps). `CRef!Next` therefore fixes `net'`, the port and `AbsC'`, so port-visible matches are exact and coarse steps cannot combine two port effects unnoticed.
- Private consumption over an append-only log: no shared-consumption races, and receivers never interfere. Ids carry launch and attempt.
- The 18:19 proof in DESIGN.md has the right structure (s|S reachability by induction), states exhaustiveness and same constants explicitly, and excludes liveness. With C3, C5 and receipt matching it goes through.
- Negative refinement checks exist and fire (`ref_WfSJ_M_C_neg`: 59 states). The static checks fail closed. Port shapes and fault names are partitioned per component, and the registry fragments keep agents out of each other's files.
- Zoom-in triage (refine the coarse groups a CE touches) is the right workflow. It needs only the refinement-failure-as-signal addition from issue 9.
