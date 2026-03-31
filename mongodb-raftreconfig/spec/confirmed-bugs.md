# Confirmed Bug Report — mongodb-raftreconfig

## Summary

- Total findings reviewed: 10
- Confirmed: 3 (0 reproduced, 3 code-audit only)
  - 3 known/by-design (Bugs 2–4)
- Reclassified: 1
  - Bug 1: newlyAdded quorum reduction → **SPEC UNFAITHFULNESS** (false positive)
    - Quorum reduction to 1 is real, but the rollback is not achievable
    - Reproduction test: `repro/test_bug1_newlyadded.py` (executed, rollback NOT triggered)
- False positives: 4 + 1 (Bug 1 reclassified)
- Inconclusive: 2

---

## Bug 1: newlyAdded Quorum Reduction Allows Committed Data Rollback

- **Source**: MC (20-state counterexample, 174M states explored, 24M distinct)
- **Status**: SPEC UNFAITHFULNESS (reclassified from CONFIRMED after reproduction attempt)
- **Severity**: Low — quorum reduction is real but rollback is not achievable
- **Reproduction**: `repro/test_bug1_newlyadded.py` (executed — Phase A demonstrated, Phase B failed)
- **Location**: `member_config.h:177-186` (isVoter), `repl_set_config.cpp:631-648` (quorum calculation), `replication_coordinator_impl.cpp:4110-4206` (RemoveNewlyAdded)
- **MC output**: `spec/output/MC_hunt_newlyadded_v2.out`
- **MC config**: `MC_hunt_newlyadded_v2.cfg` (ForceReconfigLimit=0 — no force reconfig involved)

### Description

The `newlyAdded` mechanism marks new voting members as non-voting (`isVoter()` returns false). This reduces the effective voter set, and therefore the data quorum size. When a config has 2 members but one is newlyAdded, the effective quorum is 1 — a single node can commit entries. When `newlyAdded` is later removed, the quorum expands to 2-of-2, but entries committed under the 1-of-1 quorum are not guaranteed to be replicated to the newly-promoted voter. A stale election using an older config can then override the committed entry.

### Trigger Scenario (from MC counterexample)

1. Primary s2 removes s1 from config: `{s1,s2,s3}` → `{s2,s3}` (single-node change, ConfigIsSafe passes)
2. Primary s2 adds s1 back: `{s2,s3}` → `{s1(newlyAdded),s2,s3}` (single-node change)
3. Primary s2 removes s3: `{s1(newlyAdded),s2,s3}` → `{s1(newlyAdded),s2}` (single-node change)
   - Effective voters = `{s2}`, DataQuorum = `{{s2}}` — quorum of 1
4. s2 commits entry `[term:2, index:1]` with only itself acknowledging (1-node quorum)
5. s2 auto-removes newlyAdded from s1 via heartbeat-triggered reconfig
   - Effective voters now = `{s1,s2}`, DataQuorum = 2-of-2
   - The committed entry from step 4 is NOT guaranteed replicated to s1
6. s1 wins election (term 3) using stale config `{s1,s2,s3}` (getting votes from s3, which was removed but retains old config)
7. s2 rolls back its committed entry to sync with s1's log → **NeverRollbackCommitted violated**

### Code Audit Evidence

**1. isVoter() excludes newlyAdded** (`member_config.h:177-186`):
```cpp
bool isVoter() const {
    return (getVotes() != 0 && !isNewlyAdded());
}
```

**2. Quorum calculation uses isVoter()** (`repl_set_config.cpp:631-640`):
```cpp
const int voters = std::count_if(begin(getMembers()), end(getMembers()),
    [](const auto& x) { return x.isVoter(); });  // excludes newlyAdded
_writeMajority = std::min(_majorityVoteCount, _writableVotingMembersCount);
```
With config `{s1(newlyAdded), s2}`: voters=1, `_writeMajority`=1.

**3. RemoveNewlyAdded has NO replication check** (`replication_coordinator_impl.cpp:4110-4206`):
- Only verifies member reached `RS_SECONDARY` state (heartbeat check at line 416-417)
- Does NOT verify all entries committed under the reduced quorum are replicated to the newly-voting member
- Uses `doReplSetReconfig(force=false)`, which applies ConfigIsSafe — but ConfigIsSafe only checks config quorum (which is satisfied by s2 alone when s2 is the only effective voter)
- Comment at line 4203: "We intentionally do not wait for config commitment"

**4. Single-voter-change check uses base votes** (`repl_set_config_checks.cpp:269-278`):
```cpp
const int numVotersOldConfig = std::count_if(...,
    [](const auto& x) { return x.getBaseNumVotes() > 0; });  // ignores newlyAdded
```
This means removing a normal voter while a newlyAdded member exists passes the single-node-change check — but the effective voter count drops from 2 to 1.

**5. Removed nodes retain stale configs**: After s3 is removed from config, s2 stops heartbeating s3. s3 retains config `{s1,s2,s3}` indefinitely and can vote in elections requested by nodes with matching stale configs.

### Developer Intent Investigation

- **No evidence developers anticipated this scenario**: Git history (SERVER-46344, SERVER-46351, SERVER-47717, SERVER-46628) shows careful testing of newlyAdded mechanics but no discussion of single-voter-quorum creation via newlyAdded.
- **Architecture guide** (SERVER-46723) documents quorum overlap property but doesn't address the quorum reduction from newlyAdded creating a 1-of-1 quorum.
- **Not modeled in existing spec**: The MongoDB TLA+ spec (`MongoReplReconfig.tla`, 492 lines) does not model newlyAdded at all. The TLAPS safety proof covers only the base protocol without newlyAdded.
- **Developer awareness of single-voter safety**: SERVER-46186 addressed single-voter replica set safety for crash recovery, showing awareness of the general issue — but in a different context.

### Reproduction Results

**Test**: `repro/test_bug1_newlyadded.py` — 3-node MongoDB 8.2.6 RS via Docker.

**Phase A (Quorum Reduction): DEMONSTRATED**
- Reconfig sequence: `{s1,s2,s3}` → `{s2,s3}` → `{s1(newlyAdded),s2,s3}` → `{s1(newlyAdded),s2}`
- `newlyAdded` field confirmed in raw config (`local.system.replset`); hidden from `replSetGetConfig` by `toBSONWithoutNewlyAdded()`
- Effective write majority = 1; `w:majority` write succeeded with only s2 acknowledging
- With s1 stopped, the committed write existed only on s2 — a single point of failure

**Phase B (Full Rollback): NOT REPRODUCED — SPEC UNFAITHFULNESS**
- After starting s1, it caught up (replicated committed writes) and reached SECONDARY
- Auto-removal of `newlyAdded` triggered; s1's config atomically changed to `{s1, s2}` (without `mongo3`)
- **Key finding**: once `newlyAdded` is removed, s1's config is `{s1, s2}` — NOT `{s1, s2, s3}` as in the MC counterexample's State 17
- s1 cannot contact s3 for votes because s3 is not in s1's config
- The MC counterexample requires an **impossible intermediate state**: s1 being non-newlyAdded while having stale config `{s1,s2,s3}`

### Root Cause: Spec Unfaithfulness

The TLA+ spec models `newlyAdded` as a **separate global variable** (`VARIABLE newlyAdded`), independent of `config`. This decoupling allows `RemoveNewlyAdded(s2, s1)` to set `newlyAdded[s1] = FALSE` while `config[s1]` retains the stale value `{s1,s2,s3}`.

In the real implementation, `newlyAdded` is a field **inside the config document** (`member_config.h:71`, `member_config.idl:87-94`). Config installation is atomic (`_rsConfig.update()` at `replication_coordinator_impl.cpp:4587`). This creates an impossible dilemma for the counterexample:
1. If s1 has stale config → s1 is still `newlyAdded` → `isElectable()` returns false → s1 **cannot start election**
2. If s1 receives the newlyAdded-removed config → member list is `{s1, s2}` → s1 **cannot contact s3 for votes**

Additionally, auto-removal only triggers after the member reaches `RS_SECONDARY` state (`replication_coordinator_impl_heartbeat.cpp:416-417`), which requires replicating all committed data first. This ensures committed entries under the reduced quorum are replicated before quorum expansion — a defense mechanism not captured by the TLA+ model.

### Recommendation

1. **Fix the TLA+ spec**: Model `newlyAdded` as part of the config document, not as a separate global variable. The `RemoveNewlyAdded` action should simultaneously update the member's voting status AND the config membership visible to that member.
2. **No code fix needed**: The implementation's defense mechanisms (atomic config + SECONDARY-gate) prevent the rollback scenario. The quorum reduction to 1 is a design property, not a bug.
3. **Documentation improvement**: Consider documenting that reconfig sequences creating a single effective voter are possible with `newlyAdded`, so operators are aware of the transient durability reduction.

---

## Bug 2: Force Reconfig Committed Data Rollback

- **Source**: MC (11-state counterexample, 6.3M states explored)
- **Status**: CONFIRMED (code audit) — **known limitation**
- **Severity**: Medium (documented design trade-off)
- **Location**: `replication_coordinator_impl.cpp:3563-3624` (three `if (!force)` guards), `repl_set_config.h:82-99` (ConfigVersionAndTerm comparison)
- **MC output**: `spec/output/MC_hunt_force_v2.out`
- **Known tickets**: SERVER-55376, SERVER-47852, SERVER-54746

### Description

Force reconfig (`rs.reconfig({...}, {force: true})`) bypasses all three ConfigIsSafe preconditions (config quorum check, config term invariant, oplog commitment), the single-node-change restriction, and the quorum pre-check. Combined with `configTerm=-1` (which causes version-only comparison), force reconfig can create isolated config islands where committed entries are overwritten.

### Code Audit Evidence

Three explicit bypass guards in `_doReplSetReconfig`:
1. **Line 3563**: `if (!force && ... && !skipSafetyChecks)` — skips primary writability check
2. **Line 3579**: `if (!force && !skipSafetyChecks)` — skips config term invariant
3. **Line 3593**: `if (!force && !skipSafetyChecks)` — skips config commitment + oplog commitment

Plus `configTerm = -1` semantics (`repl_set_config.h:87-95`): "If term of either item is uninitialized (-1), then we ignore terms entirely and only compare versions." Comment explicitly states: "This allows force reconfigs to override other configs by using a high config version."

### Developer Intent

Known and intentional. SERVER-55376 documents reconfig can roll back committed writes. SERVER-47852 and SERVER-54746 (two primaries after force reconfig) were closed as "Works as Designed." Force reconfig is an emergency tool documented as potentially causing data loss.

### Recommendation

No fix needed — this is a documented design trade-off. Consider stronger documentation warnings about the data loss risk.

---

## Bug 3: Force Reconfig Election Safety Violation

- **Source**: MC (4-state counterexample, 617 states explored)
- **Status**: CONFIRMED (code audit) — **known limitation**
- **Severity**: Medium (documented design trade-off)
- **Location**: Same as Bug 2
- **MC output**: `spec/output/MC_hunt_force_deep.out`
- **Known tickets**: SERVER-47852, SERVER-54746

### Description

Force reconfig allows creation of isolated configurations where separate nodes can independently self-elect in the same term. In the counterexample: s1 self-elects (term 1) in `{s1}`, then s2 force-reconfigures to `{s2}` and self-elects (term 1) — two leaders in term 1.

### Developer Intent

Same as Bug 2 — known and documented. SERVER-47852 explicitly describes the two-primary scenario.

### Recommendation

No fix needed — known design trade-off of force reconfig.

---

## Bug 4: Arbiter Quorum Overlap Violation

- **Source**: MC (initial state violation)
- **Status**: CONFIRMED (code audit) — **known design property**
- **Severity**: Low (design limitation for arbiter-heavy configs)
- **Location**: `repl_set_config.cpp:683-688` ($configMajority includes arbiters), `repl_set_config.cpp:637-648` ($majority excludes arbiters)
- **MC output**: `spec/output/MC_hunt_arbiter.out`

### Description

With 2 data nodes + 3 arbiters, the config quorum (3 of 5) can be all-arbiter `{s3,s4,s5}`, which has zero overlap with the data quorum `{s1,s2}`. A config can be "committed" by arbiters without any data node acknowledging.

### Developer Intent

Known property. MongoDB documentation warns against arbiter-heavy configurations. The `$configMajority` vs `$majority` distinction is by design: arbiters participate in membership decisions but not data replication.

### Recommendation

Consider adding a startup validation warning when `|arbiters| >= |data nodes|`.

---

## False Positives

### FP-1: Missing `updateLastCommittedInPrevConfig` in Heartbeat Reconfig (C1)

- **Source**: Code review (modeling brief §6.3 C1)
- **Status**: FALSE POSITIVE
- **Location**: `replication_coordinator_impl_heartbeat.cpp:1050-1055`

**Why false positive**: While the heartbeat reconfig path genuinely does NOT call `updateLastCommittedInPrevConfig`, the `_firstOpTimeOfMyTerm` mechanism provides equivalent safety. When a secondary becomes primary:
1. `processWinElection()` sets `_firstOpTimeOfMyTerm = {INT_MAX, INT_MAX}` — blocks all reconfigs during drain
2. `doOptimizedReconfig` during `signalDrainComplete` updates `_firstOpTimeOfMyTerm` to the actual first entry of the new term
3. `getConfigOplogCommitmentOpTime()` returns `max(_lastCommittedInPrevConfig, _firstOpTimeOfMyTerm)` — the new term's optime supersedes the stale value

The compensating mechanism makes the stale `_lastCommittedInPrevConfig` irrelevant by the time the new primary could perform a user reconfig.

### FP-2: `doOptimizedReconfig` Safety (C2)

- **Source**: Code review (modeling brief §6.3 C2)
- **Status**: FALSE POSITIVE
- **Location**: `replication_coordinator_impl.cpp:3519-3521`

**Why false positive**: `doOptimizedReconfig` only runs during step-up (drain completion), only changes `configTerm` (not membership), and the single-node-change validation is NOT guarded by `skipSafetyChecks` — it's still enforced. A concurrent force reconfig would require a separate node, and the election term bump isolates the new primary from stale configs.

### FP-3: `_firstOpTimeOfMyTerm` Sentinel Blocks Reconfig (C3)

- **Source**: Code review (modeling brief §6.3 C3)
- **Status**: FALSE POSITIVE

**Why false positive**: This is by design. During `kLeaderElect` state, reconfig is blocked by config state checks (not `kConfigSteady`). The sentinel `{INT_MAX, INT_MAX}` is a defense-in-depth measure, not a bug.

### FP-4: Drain Mode Reconfig Races (Family 2)

- **Source**: Code review + MC (29M states, no violation)
- **Status**: FALSE POSITIVE (for current code)

**Why false positive**: MC explored 29M states with drain mode interleaving and found no violation. The 7+ historical bugs in this area have been fixed with targeted guards (reject HB reconfig if kCandidate, check configVersionAndTerm hasn't changed, etc.). The current code appears safe, though future changes to this complex area should be re-verified.

---

## Inconclusive

### I-1: Heartbeat Reconfig during kCandidate Regression (T2)

- **Source**: Code review (modeling brief §6.2 T2, SERVER-48257)
- **Status**: INCONCLUSIVE
- **Location**: `replication_coordinator_impl_heartbeat.cpp:700-716`

The fix for SERVER-48257 rejects heartbeat reconfig if the node is a candidate. Verifying this requires an integration test with precise election/heartbeat timing that is outside the scope of this code audit.

### I-2: REMOVED Node Heartbeat Cessation Regression (T3)

- **Source**: Code review (modeling brief §6.2 T3, SERVER-46897)
- **Status**: INCONCLUSIVE

After a node is removed from config, the primary stops sending heartbeats to it. If the node is later re-added, it may never learn about re-addition. Verifying this requires a multi-node integration test.

---

## MC Exploration Summary

| Bug Family | Config | States Explored | Distinct | Result |
|------------|--------|-----------------|----------|--------|
| Family 5: newlyAdded | MC_hunt_newlyadded_v2.cfg | 174M | 24M | **NeverRollbackCommitted violated** (20 states) |
| Family 1: Force (data) | MC_hunt_force_v2.cfg | 6.3M | 1.2M | **NeverRollbackCommitted violated** (11 states) |
| Family 1: Force (election) | MC_hunt_force_deep.cfg | 617 | 290 | **ElectionSafety violated** (4 states) |
| Family 4: Arbiter | MC_hunt_arbiter.cfg | - | - | **ArbiterQuorumOverlap violated** (initial state) |
| Family 2: Drain mode | MC_hunt_drain_v3.cfg | 29M | 3M | No violation |
| Family 3: Heartbeat | MC_hunt_heartbeat_v2.cfg | 207M | 14.7M | No violation |

---

## Key Takeaway

**Bug 1 (newlyAdded quorum reduction)** was reclassified from "potentially new" to **SPEC UNFAITHFULNESS** after reproduction testing revealed a fundamental gap between the TLA+ model and the implementation:

- **The TLA+ model** treats `newlyAdded` as a separate global variable, decoupled from the config document. This allows the MC counterexample to construct an impossible intermediate state where a node is non-newlyAdded but has a stale config with different member list.
- **The implementation** embeds `newlyAdded` as a field inside the config document. Config installation is atomic, so newlyAdded removal and member list updates are coupled. Additionally, auto-removal only triggers after the member reaches SECONDARY (i.e., after replicating all committed data).

The **quorum reduction to 1** via newlyAdded IS real and was demonstrated (Phase A of reproduction test). However, the implementation's defense mechanisms prevent this from causing data rollback:
1. Atomic config update couples newlyAdded status with member list (prevents stale-config elections)
2. SECONDARY-gate ensures committed data is replicated before quorum expansion

**Lesson**: When modeling per-member flags that affect quorum semantics (like `newlyAdded`), the flag must be modeled as part of the config document — not as a separate variable — to preserve the atomicity of config propagation. Decoupling introduces unreachable states that produce spurious counterexamples.
