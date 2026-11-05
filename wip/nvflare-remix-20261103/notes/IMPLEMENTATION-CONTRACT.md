# Contract for component implementation agents

Workspace: `/home/ubuntu/nvflare-remix-20261103` (W). Read first: `W/GOAL.md`, `W/DESIGN.md` (framework, variant contract, soundness argument), `W/spec/Consts.tla`, `W/spec/Ports.tla`, your `W/spec/Ports<Comp>.tla`, your registry fragment `W/spec/registry.d/<comp>.json`, the coarse modules of your groups, `W/spec/Props.tla`, your seed partition notes `W/notes/seeds/<seed>-partition.{md,json}` and `W/notes/phase1-hazards.{md,json}` (if present). Seed inputs are read-only copies under `W/inputs/seeds/<seed>/`. NVFlare source (read-only) is `/home/ubuntu/nvflare-integrated-model-20261103/sources/current`, pin `c411a201ead0ec2d4bd0df27fc8b88955c086cfd`.

## Hard rules

- Never write outside W. Never modify `W/inputs/`, `/home/ubuntu/nvflare-integrated-model-20261103`, or `/home/ubuntu/Specula`. `/` and `/tmp` are full: always run TLC and SANY through `W/scripts/tlc.sh`, `W/scripts/run_mc.py` or `W/scripts/gen_ref.py`, which keep every temp file and metadir under W.
- TLC budget per run: at most 24 workers (`--workers`), heap 16g or less (`--heap`), and always a timeout. Runs over 10 minutes go into `scripts/run_mc.py ... --timeout N` launched in the background. Never leave JVMs running when you finish.
- You may edit only:
  - your component's group modules (`spec/<Group>_<V>.tla` for your groups);
  - your `spec/Ports<Comp>.tla`;
  - your `spec/registry.d/<comp>.json`;
  - new files under `checks/<comp>/`, `notes/<comp>-*.md`, and `scripts/<comp>_*.py`.

  `Consts.tla`, `Ports.tla`, `Props.tla`, `Mix.tla` (generated), other components' files and the core scripts belong to the coordinator. If you need a change there, write it to `notes/port-requests.md` (append; say who, what, why) and work around it conservatively.
- Port changes: you may add fields to your own groups' port records and add message body fields for kinds you own. Before renaming or removing any port field or message field, grep `spec/` for readers. If another component reads it, keep it and add instead.
- Every edit must keep `python3 scripts/gen_mix.py` (static decoupling checks) and SANY on `spec/Mix.tla` passing. Run both after each change.

## What to build

For each of your groups, produce a FINE variant `F` derived faithfully from the seed, and update the COARSE variant `C` so that `F` refines `C` on the group's port projection (DESIGN.md §2).

Fine variant:
1. Keep the seed's actions for this group's mechanisms: names, guards, updates and `file:line` anchors. Re-home them to the group's private variable (`<group>_f`), its port variable, and `net`. Most of the seed's record fields become private fields. A seed field that another group reads becomes either a port field or message content.
2. Replace seed-internal stand-ins for other components with the real neighbor's port or messages. Examples: the pre-registered payload transaction, the eager client result, a spontaneous READY or exit, the abstract workflow progress, a seed-local network queue. Every cross-process interaction becomes a message with the same key and body the coarse variant uses for the same event.
3. Keep the seed's failure, timeout and cancel branches. Gate faults on `Faults` toggles from your component's fault set (add names to your `Ports<Comp>.tla` `*Faults` set if needed). Bound counters so that instances stay finite.
4. Use a deterministic Init. Define `InitValue`, `AbsC` (the value of the coarse variant's private variable as a function of your private state and ports), and `AbsCInit` (`AbsC`'s initial value; used by the negative check).
5. Use the slice profile: one job, sites as model values, one result transaction per (site, launch, attempt), one ref, one receiver (SJ). Seed constants are fixed as in `inputs/vertical-slice/checks/interfaces/<comp>/*Refinement.tla` unless a hazard needs more.

Coarse variant:
- It must over-approximate the fine variant on ports, including every failure outcome the fine variant can put on its ports or messages.
- It may merge only port-invisible steps. If fine changes two port-visible things in two steps, coarse needs two steps as well.
- Keep it small. Coarse exists to make mixes cheap.

## Checks to run and record

Record every command, result and run time in `notes/<comp>-impl.md`.
1. `python3 scripts/gen_mix.py`, then SANY on `spec/Mix.tla`.
2. Refinement for every group: `python3 scripts/gen_ref.py <Group> F C --sites 1 --faults <your faults> --run`, then `--sites 2` if tractable. Also run the negative check `--negative` (it must report a violation). The result JSON lands in `checks/results/`.
3. Baseline mixes with `scripts/mkmc.py` plus `scripts/run_mc.py`:
   - all-coarse;
   - all-coarse except your groups fine;
   - your groups fine plus `--faults` for your hazards.

   Use 1 site and, if tractable, 2 sites. Invariants: the default set from `mkmc.py`. Witness: `--inv NotJobFinished`; it must be violated, which shows the job can still finish. For every invariant violation, run `python3 scripts/ce.py <name> -v` and classify it as one of: (a) your model is wrong; (b) a coarse over-approximation artifact (re-run with the involved groups fine); (c) a candidate system behavior (keep the CE and explain it with source lines).
4. Do not weaken properties in `Props.tla` to make runs pass. If a property is wrong, explain why in `notes/port-requests.md`.

## Final reply (under 300 words)

List:
- the files you created;
- the action counts for fine and coarse;
- refinement results (states, sites, faults, pass/fail, negative check);
- baseline mix results;
- any CE classified (c);
- open problems and port requests.

## Addendum (18:40, after notes/design-review.md)

- Net discipline is asserted on every generated step: existing messages are immutable (no resend to an existing key), new keys carry only your kinds, and nothing outside Net mentions `.lost`. Put a sequence number in the id of every retry-capable kind.
- Use `InInbox(k, p, kind)` instead of `k \in Inbox(p, kind)`, which is about 7x faster.
- Process facts:
  - `pJobCP.killed` is a kill request; RunCJ's `DieOfKill` makes it land, with no fairness.
  - Cross-process failure reactions must use `PeerFailureCJ`/`PeerFailureSJ`, which include false suspicion under `transportFail`.
- `gen_ref.py` now also checks `RefEnv` (AbsC is stable under other groups' steps). It writes a receipt to `checks/receipts/` keyed by sites, Net variant, launch and faults. Campaign results transfer to all-fine only when the receipt matches exactly, so produce receipts for the instances the scenarios use (`checks/scenarios.json`), including Net=L where listed.
- With three variants, check the chain edges (F ⊑ M, M ⊑ C), or keep only two variants.
