# AlephBFT Analysis Report

Detailed audit trail of the code-analysis run on `Cardinal-Cryptography/AlephBFT` at commit `f35c7bb` (main). Companion to `modeling-brief.md`.

## Phase 1 — Reconnaissance

### Repository layout
- Root crate workspaces: `consensus/`, `rmc/`, `crypto/`, `mock/`, `types/`, plus `examples/{blockchain,ordering}`.
- Core consensus code in `consensus/src/` (~10 kLOC).

### Lines of code (core, excluding tests/mock)
```
consensus/src/alerts/         ~1,038 LOC  (mod 138, handler 701, service 199)
consensus/src/backup/         ~  464 LOC
consensus/src/collection/     ~  710 LOC
consensus/src/consensus/      ~  769 LOC
consensus/src/creation/       ~  898 LOC
consensus/src/dag/            ~1,097 LOC  (validation 428, mod 669)
consensus/src/dag/reconstruction/ — parents.rs, dag.rs, mod.rs
consensus/src/dissemination/  ~1,289 LOC
consensus/src/extension/      ~  726 LOC  (election 390, extender 129, units 169, mod 38)
consensus/src/network/        ~  369 LOC
consensus/src/units/          ~1,233 LOC  (control_hash 395, validator 260, store 303, mod 275)
rmc/src/                       ~  940 LOC  (handler 351, service 347, scheduler 208)
crypto/src/                    ~1,023 LOC
Total core                    ~13,955 LOC (incl tests)
```

### System category
**Category A (Distributed / Message-Passing).** Network-RPC consensus across n nodes with disk-backed persistence. The fault model is BFT (≤ f Byzantine of n=3f+1).

### Threat model (recorded from target instructions and confirmed by code)
- Static identity: n committee members fixed at session start (`Keychain::new(n, my_index)`); membership change is across sessions, not within.
- Authenticated: every message that affects consensus state is signed (`SignedUnit`, `UncheckedSigned<Alert>`, `Signed<Indexed<H>>`).
- Network: fully asynchronous; the implementation deliberately gives up "Asynchronous Liveness" (random common-vote / random head order) — see `docs/src/how_alephbft_does_it.md` § 2.4. Safety is preserved without randomness.
- Threshold: `n = 3f+1`; `consensus_threshold = floor(2n/3) + 1 = 2f+1 = n-f` (`crypto/src/node.rs:87-89`).

### Concurrency model
- The session is composed of independent async tasks coordinated via `futures::mpsc` unbounded channels and a hierarchical `Terminator`:
  - **creator** (`consensus/src/creation/mod.rs`)
  - **consensus service** (`consensus/src/consensus/service.rs`) — single-threaded synchronous logic for incoming units / requests / responses / forking notifications
  - **backup saver** (`consensus/src/backup/saver.rs`)
  - **alerter service** (`consensus/src/alerts/service.rs`)
  - **network hub** (`consensus/src/network/hub.rs`)
  - **initial unit collection** (`consensus/src/collection/service.rs`)
- The consensus service is *synchronous* (`Consensus::process_incoming_unit` etc. are not async). This is intentional after PR #431 (A0-4212: "Reconstruct synchronously") and PR #558 (A0-3477: "Separate out the synchronous logic from consensus"). The asynchronous boundaries are: creator→service (own units), saver↔service (persist), alerter↔service (forking notifications), network↔service (peer traffic).

### Key architectural decisions vs. AlephBFT paper
- Implements *QuickAleph* with explicit fork-alerter + reliable multicast, not Reliable-Broadcast-for-every-unit (per `docs/src/differences.md`).
- Uses **control hashes** (compressed parent representation) plus on-demand explicit parents (`Request::ParentsOf`), instead of full hash lists.
- Uses **deterministic** common-vote and head-order — sacrifices asynchronous liveness for simplicity (paper §2.4 explicitly notes this).
- Adds *ancient parents* (PR #506/#514/#528, 2024): a unit can include parents at any earlier round (not strictly round-1), enforced through a separate `direct_parents` predicate. The election rule still uses `direct_parents` only, so safety arguments port over unchanged.

---

## Phase 2 — Bug Archaeology

### Coverage statistics
- 477 commits on `main` after unshallow (was a shallow clone with 1 commit by default).
- Bug-fix commits matching keywords (`fix|bug|race|panic|deadlock|crash|wrong|forg`): ~80 over the project's lifetime.
- **All commits touching `consensus/src/alerts`, `consensus/src/dag`, `consensus/src/creation`, `consensus/src/extension`, `consensus/src/backup`, `consensus/src/collection`** examined directly (`git show`) and the corresponding PRs read via `gh pr view <num> --comments` for the most interesting ones.
- GitHub issues: only **3 issues** ever filed (#258 stub, #309 closed, #373 open) — the project tracks work internally in Aleph Zero JIRA (A0-XXX / AZ-XXX), surfaced as PR titles. Issues deeply read: #309, #373. Other interesting context surfaced from PR bodies.
- Closed PRs deeply read: #30, #47, #65, #79, #80, #81, #84, #102, #108, #109, #130, #137, #141, #143, #190, #193, #195, #197, #221, #234, #235, #311, #312, #314, #315, #335, #338, #362, #399, #406, #417, #431, #436, #506, #514, #528, #536, #549, #555, #556, #558 — **40+ PRs**.
- Open PRs (only 4 non-draft on `main`): all typo/dependency PRs, no functional bug fixes pending.

### Confirmed bugs / fixes by family

#### Family A: Fork handling & alerter (highest density)
- `c97e253` (#65) — multiple Byzantine-prep fixes (forker re-add prevention, store counter, threshold)
- `cb9c04b` (#81) — initial alerter using RMC; previously cross-session alerts accepted; finalized-alert duplicate detection added
- `60102f2` (#102, **TOB-ALEPH-004**) — `mark_forker` didn't decrement per-round unit count; corrupted threshold computation
- `e5d0096` (#130) — fork variant in `unit_by_coord` map caused honest creator's own unit to fail control-hash check, causing network freeze (~1/50 in `small_byzantine_one_forker` test before fix)
- `5511b90` (#80) — panic on parents-response for non-WrongControlHash unit
- `7ddcf49` (#30) — late parent arrival vs DAG admission interleaving
- `0ee89dc` (#315) — refactor: sync alerter Handler + async Service split
- `1b5e7b2` (#335) → `8ec90d3` (#362) — alert backup added then removed (the team decided alerts don't need backup persistence, since they can be re-detected on restart)

#### Family B: Async/channel error handling
- `60ac638` (#108, **TOB-ALEPH-009**) — different sites handled closed channels differently; some logged, some panicked, leaving partial state. Fix: uniform `expect(...)` on every channel send (fail-stop semantics).
- `1854744` (#109, **TOB-ALEPH-007**) — async tasks could die independently and leave parent running with dead service. Fix: `spawn_essential` returns a handle that the parent `select!`s over.
- `038382b` (#235) — false errors on cascading shutdown. Fix: `Terminator` tree with `terminate_sync` ack.
- `bd76102` (#234) — nested awaits inside `select!` arms blocked progress. Fix: extract `Packer` task for sign+data.
- `22f8191` (#314) — two bugs: creator's graceful exit incorrectly torn down whole session; `FusedStream` `is_terminated()` panic in `select!`.

#### Family C: Creator / control hash / round logic
- `485d9eb` (#141) — creator silently exited on closed parents channel.
- `c3a3c9c` (#84) — creator never bounded by `max_round`.
- `0b37285` (#79) — creator delay inside parents `select!` arm starved parent consumption.
- `4f94fc7` — `is_behind` heuristic moved out of creator; "possibly fixed a bug" per commit.
- `36cebee` (#312) — operator could configure `max_round * delay` to terminate before alerts could finalize; fix validates against `time_to_reach_max_round`.
- `2cec6cd` (#417) — round-0 control hash not validated up front.
- `1227231` (#143) — own units broadcast at creation time but DAG-added later; transient "request → can't answer" window.

#### Family D: Extender / threshold
- `c97e253` (#65) — Extender threshold off-by-one + add_unit early-return bug. Threshold was `(2N)/3` strict-`>` instead of `floor(2N/3)+1` ≥; for N=4 allowed decisions with only 2 votes (below f+1=3). **Real safety bug — fixed in 2021.**
- `82151d8` (#431) → `eebbf2b` (#436) → `6ff871b` (#406) — synchronous refactors of reconstruction and extender that eliminate whole classes of async interleaving bugs by construction.

#### Family E: Backup / recovery / restart safety
- `af8e2cd` (#137) — original crash recovery design.
- `92ec3cf` (#195) — initial backup loader.
- `838bd70` (#197) — wires backup-loader vs initial unit collection: returns `None` (refuse to participate) when peers know of a round that backup doesn't. **Equivocation guard across restarts.**
- `978f41c` (#311) — flipped save-before-broadcast order; backs up ALL units in ch-DAG (not just own).
- `f6384cf` (#338) → `36638fd` (#399) → `6a82d74` (#556) — architectural cleanups; loader from service to plain function.
- `fe09add` (#549) → `d674476` (#555) — initial unit collection separated from runway.

#### Family F: Ancient-parents / censorship-resistance (2024, last major feature)
- `71f0314` (#506) — Extender API now distinguishes `parents()` vs `direct_parents()`.
- `1a35839` (#514) — `ControlHash` carries `NodeMap<Round>` and `combined_hash` over `(hash, round)`.
- `496ff02` (#528) — Creator's `UnitsCollector` accumulates `(hash, round)` per node, copied forward; allows a unit at round r to point to an ancestor at round r' < r-1.
- `4b3d8f2` (#536) — test fix.
- Per maintainer comment on Issue #309: "ABFT is not strictly censorship resistant; we have weak censorship resistance, if you submit to f+1 nodes it's guaranteed". Censorship-resistance work is **liveness**, not safety.

### Bug-prone surfaces (counted)
| Surface | # bug-fix commits | Severity |
|---|---|---|
| fork detection + alerter | 11+ | several HIGH (safety-adjacent) |
| creator / control hash | 8 | mostly liveness, one HIGH (#65) |
| extender / election | 4 (incl. #65 threshold) | one HIGH safety bug (fixed 2021) |
| backup / restart equivocation guard | 6 | one HIGH (#311 save-before-broadcast); the chain is now load-bearing |
| async lifecycle / shutdown | 5 | medium |

---

## Phase 3 — Deep Analysis

The Phase 3 work was distributed across 4 parallel subagents, each reading one major component completely. Below is the consolidated set of findings, classified.

### F1. **`alert_confirmed` populates `known_rmcs` before commitment verification** (handler.rs:272-273)
```rust
// handler.rs
pub fn alert_confirmed(&mut self, multisigned: ...) -> Result<...> {
    let alert = match self.known_alerts.get(multisigned.as_signable()) {
        Some(alert) => alert.as_signable(),
        None => return Err(Error::UnknownAlertRMC),
    };
    let forker = alert.proof.0.as_signable().creator();
    self.known_rmcs.insert((alert.sender, forker), alert.hash());  // LINE 272
    self.verify_commitment(alert)?;                                 // LINE 273
    Ok(ForkingNotification::Units(alert.legit_units.clone()))
}
```

A Byzantine `sender` can broadcast an alert with valid `proof` but a deliberately invalid `legit_units` commitment (e.g., legit_units containing two units of the same round, or units not from the alleged forker, or unsigned units). Because `verify_commitment` is **only run at `alert_confirmed` time**, not at `on_network_alert` (handler.rs:201 only calls `verify_fork`), honest nodes will:
1. Receive the alert, validate the `proof` (which IS valid), mark the forker locally.
2. Sign the alert hash for RMC (RMC participants don't re-verify commitment; they sign because the alert was "accepted").
3. RMC eventually completes.
4. `alert_confirmed` inserts `(byzantine_sender, forker) → bad_hash` into `known_rmcs` first, THEN fails `verify_commitment` and returns Err.
5. `service.rs:163` just `warn!`s on the error.

**Consequences**:
- `ForkingNotification::Units` for this (sender, forker) pair is never propagated. The DAG never receives the `legit_units` list (which would have been empty/garbage anyway).
- `known_rmcs.contains_key((byzantine_sender, forker))` is now true → if the same sender later broadcasts a *good* alert for the same forker, line 204 rejects it as `RepeatedAlert` (the new alert still gets inserted into `known_alerts` but is not RMC'd).
- Other honest detectors are not blocked: their alerts go under a different `(sender, forker)` key. They can produce a valid commitment.

**Severity**: liveness griefing (recoverable as long as at least one honest detector raises its own alert) + RMC traffic amplification for the bad alert. Not a safety violation.

### F2. **`known_alerts` is unbounded** (handler.rs:205)
Even after `RepeatedAlert`, the alert is inserted into `known_alerts`. There is no eviction. A Byzantine sender can craft arbitrarily many distinct alert blobs for the same `(sender, forker)` (varying `legit_units` length/content), each with a distinct hash. Memory growth is unbounded.

**Severity**: DoS / memory griefing. Modeling-wise: not a TLA+ target (resource-bound issue, better as a Rust unit-test).

### F3. **`known_forkers` divergence** (validation.rs:70 vs alerts/handler.rs:82)
Two separate sets:
- `dag/validation.rs` `Validator::known_forkers: NodeSubset` — set when the *local* node detects fork.
- `alerts/handler.rs` `Handler::known_forkers: HashMap<NodeIndex, ForkProof>` — set on alert receive.

The two sets are bridged one-way via `ForkingNotification::Forker` which dispatches the proof to the DAG and triggers `add_unit` → `mark_forker` (`dag/mod.rs:188-193`). So a node only marks a creator as forker in `validation.rs` after it has *itself* processed two distinct units from that creator. Under asynchrony this means **honest nodes can have diverging views of "currently marked forkers"**.

**Severity**: by-design (acknowledged in code comments at validation.rs:99-102). Does not break safety because admission of forker units into the extender is gated by alert RMC + ancestry; covered by the protocol's `legit unit` invariant. Worth modeling **as evidence the spec must capture local-vs-global forker views**.

### F4. **Different honest detectors commit to different `legit_units`** (validation.rs:88-106)
`mark_forker` copies the *first-seen* canonical units per round for the forker. Different honest detectors will see different first variants (since the forker delivers selectively). Each raises its own alert with a *different* `legit_units` list. All such alerts pass RMC. The DAG accepts all (`dag/mod.rs:194-200`).

**Consequence**: in the DAG storage, *multiple variants* of the same `(forker, round)` coexist (in `by_hash`), with the local first-received one as canonical. The extender consumes only what comes through `process_forking_notification → validate_committed → reconstruction.add_unit → Dag::add_unit → on_unit_backup_saved`. Different honest nodes can end up with different *sets* of forker units in their DAG, but the *intersection* is always sufficient because:
- Round-r forker units only matter to the extender if reachable from some honest unit's parent chain.
- Honest units validate their parents via control hash, so a forker variant only becomes a "useful" parent if an honest unit chose it before alert detection.
- The deterministic election + `parent_for(creator)` direct-descendant check at election.rs:108 makes the local extender produce the same head across honest nodes for rounds with sufficient honest descendants.

**Severity**: protocol-level invariant clarification, not a bug. **Worth modeling explicitly** — the spec author should track "per-node DAG content" not assume a unique global DAG.

### F5. **`add_parents` with mismatched hashes silently retains the orphan** (parents.rs:200-216)
```rust
pub fn add_parents(&mut self, unit_hash: HashFor<U>, parents: HashMap<UnitCoord, HashFor<U>>) -> ReconstructionResult<U> {
    match self.reconstructing_units.remove(&unit_hash) {
        Some(unit) => match unit.with_parents(parents) {
            Ok(unit) => ReconstructionResult::reconstructed(unit),
            Err(unit) => {
                self.reconstructing_units.insert(unit_hash, unit);  // put it back
                ReconstructionResult::empty()                        // no re-request emitted
            }
        },
        None => ReconstructionResult::empty(),
    }
}
```

A Byzantine peer responding to `Request::ParentsOf(U)` with parents that have wrong hashes leaves U stuck in `reconstructing_units` with no new request emitted from *this layer*. Recovery depends entirely on the outer dissemination task layer re-emitting the request.

**Severity**: latent liveness. Looking at `dissemination/task.rs`: `add_request` is called from consensus on each `ReconstructionResult::request(...)` (`consensus/handler.rs:114-116`). If the reconstruction-layer never emits a new request, the dissemination task layer doesn't get a "renew" signal — the original request lives in `task_queue` and re-fires on the schedule (`task.rs:198-203` `coord_request_delay` / `parent_request_delay`). So the task layer **does** re-request periodically based on its own clock. This makes F5 a liveness latency issue, not a stall.

### F6. **Initial unit collection liveness gap** (collection/service.rs:288-298)
The "catch-up delay" only sets `delay_passed=true` if status is still `Pending`. It does NOT force a starting round. If <`threshold` responses arrive (e.g., one honest peer is unreachable in addition to f Byzantine peers being silent), the collection stays Pending indefinitely; the creator never starts.

**Severity**: documented limitation (`collection/service.rs:69` "isn't quite BFT"). Cannot be exploited into a safety violation, but is a real liveness hazard under genuinely asynchronous network conditions or when a single honest peer is partitioned.

### F7. **Salt entropy weak** (collection/mod.rs:24-28)
`generate_salt()` uses `DefaultHasher::new()` hashing `Instant::now()`. SipHash key is per-process random but the hashed value has nanosecond resolution (~30 effective bits per process).

**Severity**: non-issue today (the salt only correlates request to response; the signed body is the security-bearing primitive). Could become an issue if future protocol changes require salt unpredictability. **Worth filing a hardening PR**.

### F8. **Extender does not retract** (extender.rs:43-68)
Once a unit is in the extender, it stays. If validator/alerter retroactively determines a unit was bogus, there is no mechanism to remove it from the extension queue. This is intentional design: only legit units reach the extender (the path goes through `validate` or `validate_committed`), and once a forker is detected its subsequent units are rejected; existing units stay because they were "legit at the time".

**Severity**: by-design, not a bug. But it composes with F4: the *order in which alerts are processed at different honest nodes* determines what's in the extender at the time of finalization. The election's deterministic candidate sort + common-vote schedule must absorb this ordering nondeterminism without diverging — that's the safety claim. **The right modeling target: verify this claim**.

### F9. **`AsyncWrite::flush` ≠ fsync** (saver.rs:36-40)
The library's `save_unit` does `write_all + flush`. The trait `AsyncWrite + Send + Sync` makes no durability guarantee — `flush` only drains the in-process buffer to the underlying handle. For `tokio::fs::File`, that does NOT call `fsync`. A power-loss-before-fsync window could lose the saved unit even though the API returned Ok.

**Severity**: documentation hazard. The library's safety argument across restart (no double-signing) implicitly assumes `AsyncWrite::flush` is durable. If a user wraps a non-fsync'd file handle, double-signing becomes possible after power loss (only if the broadcast happened — which it doesn't, since broadcast is strictly after saver returns).

### F10. **No re-verification of unit session in dissemination responder** (responder.rs)
The responder serves units from the store without rechecking session. The store only contains validated units (post `Validator::validate_unit`, which checks session). So this is safe by virtue of the producer side. **Worth noting in the spec**: responses are trusted only because input ingress validates.

### F11. **Determinism of common-vote and candidate ordering — verified safe** (election.rs:9-19, :163-171)
- `common_vote(relative_round)` is a pure function of `relative_round`. Deterministic.
- `RoundElection::for_round` sorts candidates by hash via `Hash::Ord` (lexicographic on byte representation). Deterministic.
- The election only uses `direct_parents` (parents from round r-1, after the ancient-parents refactor). The First Common Cause (FCC) lemma uses direct edges only, so the safety argument from the paper transfers unchanged.

**No safety bug** in election. The deterministic head election is what gives consistency without random common-vote.

### F12. **Threshold = 2f+1 = n-f** (crypto/src/node.rs:87-89)
`consensus_threshold() = (n*2)/3 + 1`. For n=3f+1: `floor((6f+2)/3) + 1 = 2f + 1 = n - f`. Used in:
- `previous_round_have_enough_parents` (control_hash.rs:141-150)
- `vote_from_parents` (election.rs:73, :76-84)
- `Collection::threshold` (collection/service.rs:134)
- Creator `prospective_parents` (collection.rs:64)

All threshold uses are `>= consensus_threshold()`. The historical `(2N)/3` with `>` bug (PR #65, 2021) is fixed.

### F13. **Cross-session unit/alert filtering** (validator.rs:84-87, alerts/handler.rs:144, backup/loader.rs:103-109)
All three ingress paths (network unit, network alert, backup load) check `session_id` against the local session. **Safe**.

---

## Phase 4 — Modeling Brief

See companion file `modeling-brief.md`.

---

## Coverage statistics

- **Files read in full (in main context or via subagent)**: 35+ source files in `consensus/src/`, `rmc/src/`, `crypto/src/`.
- **PRs deeply read (description + comments)**: 40+ (listed above).
- **Closed GitHub issues read**: #309, #373 (the only non-stub ones).
- **Commits analyzed via `git show`**: ~30 key bug-fix commits across alerter, creation, extension, backup, recovery.
- **Open PRs reviewed**: 4 (all typo/dependency, no functional content).
- **Parallel subagents used**: 7 total (3 in archaeology, 4 in deep analysis).
- **No issues "trusted by title alone"** — all references confirmed by reading the actual diff or PR body.
