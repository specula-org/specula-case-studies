# Solana Tower BFT — Trace Harness Instrumentation Guide

This document describes how the trace harness for `solana_3` works and how
Phase 3 (validation) can adjust it.

## Files

| Path | Purpose |
|------|---------|
| `harness/src/tla_trace.rs` | Trace emission library (mutex-protected writer, validator name + hash interning, shadow PC state thread-locals). |
| `harness/src/tla_trace_scenarios.rs` | Seven `#[test]` scenarios that drive real consensus code paths and emit NDJSON events. |
| `harness/apply.sh` | Copies the two modules into `core/src/`, adds `serde_json` to `core/Cargo.toml`, and registers the modules in `core/src/lib.rs`. Idempotent. |
| `harness/run.sh` | Applies instrumentation, builds the test binary, runs each scenario with `TLA_TRACE_FILE=<scenario>.ndjson`, reports line counts. |
| `harness/.libclang/libclang.so` | Symlink to system libclang for rocksdb's bindgen. Auto-created by `run.sh`. |

## How it works

The harness is a **scenario-based driver** rather than a deeply patched
instrumented binary. Each `#[test]` scenario:

1. Constructs real types (`Tower`, `FileTowerStorage`, `VoteStakeTracker`,
   `LatestValidatorVotesForFrozenBanks`, `TowerVoteState`).
2. Calls the real production methods (`record_vote`,
   `FileTowerStorage::store`, `Tower::restore`,
   `VoteStakeTracker::add_vote_pubkey`,
   `LatestValidatorVotesForFrozenBanks::check_add_vote`,
   `Tower::update_last_vote_from_vote_state`, etc.).
3. After each call, reads state from the real struct (`tower.last_voted_slot()`,
   `tower.root()`, `oc.stake()`, etc.) and emits an NDJSON line carrying the
   captured state plus a per-event field set.

Shadow PC variables (`pcTower`, `adoptPc`, `online`, `stray`) live in
thread-locals (`tla_trace::set_pc_tower`, `set_adopt_pc`, ...) since the
implementation tracks them implicitly across multiple files/threads. The
scenario advances the shadow PC at the boundaries described in the
instrumentation spec.

Hashes are interned to spec names: `Hash::default()` → `"nullhash"`, the
first concrete hash → `"hA"`, the second → `"hB"`. Validators are mapped to
`"v1"`, `"v2"`, `"v3"` per Trace.cfg.

## Spec actions covered by event

| Spec action | Code path driven |
|---|---|
| `RecordBankVote` | `Tower::record_vote` (dev-context-only-utils alias for `record_bank_vote_and_update_lockouts`) |
| `StoreTower` | `FileTowerStorage::store(SavedTowerVersions::from(SavedTower::new(...)))` |
| `BroadcastVoteTx` | (synthetic — no single-call API; emitted with post-store live tower state) |
| `FinishVoteCycle` | (synthetic — cycle end) |
| `Crash` | (synthetic — shadow state set, no code call) |
| `Restart` | `Tower::restore(FileTowerStorage, &pubkey)` |
| `CheckSwitchThreshold` | `emit_check_switch_threshold` helper exists but no scenario drives it (requires full ProgressMap + ancestors). |
| `AdoptOnChainVoteState_Step1` | `tower.vote_state = target` direct field write |
| `AdoptOnChainVoteState_Step2` | `tower.update_last_vote_from_vote_state(hash, block_id)` (pub(crate)) |
| `AdoptOnChainVoteState_Step3` | (synthetic — cache refresh, no public API) |
| `AccumulateOCVote` | `VoteStakeTracker::add_vote_pubkey` (state read via `oc.stake()`, `oc.voted().len()`) |
| `RpcResolveOC` | (synthetic — RPC bank promotion) |
| `GossipLatestFrozen` | `LatestValidatorVotesForFrozenBanks::check_add_vote` |
| `AddLockoutInterval` | (synthetic — bookkeeping inside `compute_bank_stats`) |
| `AdvanceRoot` | (synthetic — `bank_forks.set_root`) |
| `ProposeBlock` | (synthetic — DAG growth) |
| `ByzantineEquivocate` / `ByzantineVoteWithinLockout` | (synthetic — fault injection) |

State-capture levels are documented per event in `instrumentation-spec.md`.

## Reproducing

From `.specula-output/`:

```bash
bash harness/run.sh
```

This:
1. Resets the agave working tree (`git reset --hard`).
2. Applies the harness (`apply.sh`).
3. Sets `LIBCLANG_PATH` to a local symlinked dir (rocksdb needs libclang).
4. Builds `cargo test -p solana-core --features dev-context-only-utils
   --no-run tla_trace_scenarios::` (about 1-2 min on warm cache, up to 30
   min cold).
5. Runs each scenario with `TLA_TRACE_FILE=<path>` set, one trace file per
   scenario in `traces/`.

## Known issues — please fix in Phase 3

These are **inputs** from Phase 1/2 that the harness can't validate against
without small adjustments to the spec files.

### 1. `Trace.cfg` syntax — function literal not parseable

```
Stake = [v1 |-> 1, v2 |-> 1, v3 |-> 1]    \* TLC reports: expecting `]`
```

Function literals in `.cfg` are not supported. Move to `Trace.tla` as an
operator and bind via `CONSTANT Stake <- StakeConst` in `.cfg`:

```tla
\* In Trace.tla, after SpecValidator:
StakeConst == [v \in Validator |-> 1]
```

```
\* In Trace.cfg:
CONSTANTS
    Stake     <- StakeConst
    ...
```

### 2. Trace constants are TLC model values; trace JSON carries strings

Trace.cfg as generated:

```
Validator = {v1, v2, v3}        \* model values
Hash      = {hA, hB}            \* model values
NullSlot  = nullslot
NullHash  = nullhash
```

The NDJSON trace emits `"v1"`, `"hA"`, `"nullslot"`, `"nullhash"` as JSON
strings (deserialized as TLA+ strings). TLC model values compare equal only
to themselves, so `"v1" /= v1` and validation fails.

Fix: change Trace.cfg to use string literals:

```
Validator = {"v1", "v2", "v3"}
Faulty    = {"v3"}
Honest    = {"v1", "v2"}
Hash      = {"hA", "hB"}
NullSlot  = "nullslot"
NullHash  = "nullhash"
```

### 3. `base.tla` semantic errors

TLC reports four semantic errors in `base.tla` (parsed during validation):

```
line 161: Unknown operator: Pow2.       \* recursive Pow2 missing RECURSIVE decl
line 456-458: Unknown operator: iv.     \* set-builder filter on wrong side of `:`
```

Both are bugs in the generated `base.tla`. Suggested fixes:

**Line 161** — `Pow2` is defined but unused (`Pow2_` is the recursive
version). Delete the broken `Pow2(n) == ...` line entirely:

```tla
\* Lockout window in slots: 2^confirmation_count (cap at MaxLockout).
\* consensus.rs Lockout::lockout = 2^confirmation_count.
\* (use Pow2_ — the recursive helper below)
RECURSIVE Pow2_(_)
Pow2_(n) == IF n <= 0 THEN 1 ELSE 2 * Pow2_(n - 1)
```

**Lines 449-458** — the set comprehension mixes mapping syntax with filter
syntax. Rewrite the filter as a guarded set:

```tla
ValidVoters ==
    LET FilteredIntervals ==
        { iv \in
              UNION { lockoutIntervals[c] : c \in
                  { x \in Slot :
                       /\ x # lvs
                       /\ x > root
                       /\ IsValidSwitchingProofVote(t, x, lvs, switch) } }
          :  /\ iv.end >= lvs
             /\ iv.start \notin lva
             /\ iv.start > root }
    IN { iv.voter : iv \in FilteredIntervals }
```

### 4. ValidateTowerState uses unprimed variables

`Trace.tla::ValidateTowerState` reads `pcTower[v]`, `liveTower[v]`, etc.
(unprimed). In TLA+, unprimed = PRE-state — so the trace is being checked
against the validator's state **before** the action runs.

The harness, following the instrumentation spec's "state captured AFTER the
spec action's effect is realized in the implementation" text, emits
**POST-state**. This causes a mismatch.

Two ways to reconcile:

A. **Adjust the spec to use primed variables** (the standard pattern):
   ```tla
   ValidateTowerState(v) ==
       LET st == logline.state IN
       /\ HasField(st, "last_voted_slot")
           => LastVotedSlot(liveTower'[v]) = st.last_voted_slot      \* primed
       /\ HasField(st, "pc_tower")
           => pcTower'[v] = st.pc_tower                                \* primed
       ...
   ```
   This matches the harness's POST-state emit and is the more conventional
   trace-replay pattern.

B. **Adjust the harness to emit PRE-state.** Move the `set_pc_tower(...)`
   shadow transitions to happen AFTER the emit call instead of before, and
   read tower state BEFORE calling `record_vote`/`store`/etc. This matches
   the spec as-written but is unusual.

Recommendation: do (A). The Trace.tla also uses primed variables for
`broadcastVotes'`, `lastSwitchCheck'`, etc. — so making `ValidateTowerState`
consistent (primed) keeps the spec uniform.

### 5. Numeric vs sentinel field for missing slots

The harness emits `"nullslot"` (a string) for `Option<Slot>::None`. TLA+
unconditionally compares `slot_opt(None) = NullSlot`. With fix (2) above
(`NullSlot = "nullslot"`), this works.

Alternative: use field omission (the spec already handles missing fields
via `HasField`). Edit `tla_trace.rs::slot_opt` to return `Option` and have
callers conditionally insert the field. The current `parent: "nullslot"`
in `ProposeBlock` is fine because Trace.tla has:

```tla
parent == IF HasField(logline, "parent") THEN logline.parent ELSE NullSlot
```

Both approaches work after fix (2).

## How to add a new event type

1. Define a helper in `tla_trace_scenarios.rs`:
   ```rust
   fn emit_my_action(pk: &Pubkey, x: u64) {
       emit(json!({
           "event": "MyAction",
           "node": nid(pk),
           "my_field": x,
           "state": tower_state_obj(pk, ...),
       }));
   }
   ```

2. Add a scenario (or extend an existing one) that drives the real code
   path and calls the helper.

3. Re-run `bash harness/run.sh`.

## How to add a new state field to an existing event

1. Add the field to `tower_state_obj` / `store_tower_state_obj` /
   `oc_state_obj` in `tla_trace.rs`.

2. Make sure the field name matches `ValidateTowerState`'s `HasField` check
   in `Trace.tla`.

3. Re-build (`cargo test --no-run`) — incremental build is seconds.

## How to move a capture point

Each scenario controls the order of emit calls relative to the real method
calls. To capture BEFORE a method instead of AFTER, move the `emit_*` call
to before the corresponding production-code call, and update any
shadow-state setters accordingly.

## Rebuild / re-run after changes

```bash
# Sync edits into the artifact (no rebuild needed — apply copies files)
bash harness/apply.sh

# Incremental rebuild (~30 sec for in-crate edits)
LIBCLANG_PATH="$PWD/harness/.libclang" \
    cargo test -p solana-core --features dev-context-only-utils \
                --no-run tla_trace_scenarios:: -C $ARTIFACT_DIR

# Or just re-run run.sh — it does apply + build + run
bash harness/run.sh
```

## Cleaning up

`apply.sh` does `git -C agave reset --hard HEAD` on each run, so leftover
edits are wiped. To fully revert the artifact:

```bash
git -C ../artifact/agave reset --hard HEAD
git -C ../artifact/agave clean -fd core/src/tla_trace.rs core/src/tla_trace_scenarios.rs
```
