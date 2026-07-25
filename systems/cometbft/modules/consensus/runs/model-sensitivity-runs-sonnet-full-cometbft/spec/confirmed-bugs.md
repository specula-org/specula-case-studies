# CometBFT — Bug Confirmation Report

**Target**: CometBFT v0.38.19  
**Phase**: 4 — Bug Confirmation  
**Date**: 2026-06-07  

---

## Summary

| Bug | Source | Status | Severity | Location |
|-----|--------|--------|----------|----------|
| Bug 3 — Evidence pool hash collision | MC (counterexample) | **REPRODUCED** | High | `types/evidence.go:326` |
| Bug 2 — Double-sign check off-by-one | Code Review | **REPRODUCED** | Medium | `consensus/state.go:2647` |
| Family 1 — Vote extension self-bypass | Code Review | **FALSE POSITIVE** | — | `consensus/state.go:2308` |
| Family 4 — Blocksync maxPeerHeight stale | Code Review | **FALSE POSITIVE** | — | `blocksync/pool.go:449` |

---

## Bug 3 — Evidence Pool Hash Collision

- **Source**: MC — TLC produced an actual 3-state counterexample violating `EvidenceDeduplicationSound` under `MC_hunt_family3.cfg`
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `types/evidence.go:326`

### Description

`LightClientAttackEvidence.Hash()` uses `copy(bz[:tmhash.Size-1], ...)` to copy `ConflictingBlock.Hash()` into the pool-key buffer, incorporating only 31 of 32 bytes. The 32nd byte (index 31) is never written and stays zero. Two evidence objects whose `ConflictingBlock.Hash()` values differ only in byte 31 produce identical pool keys, so the second evidence is silently dropped when the pool finds the slot already occupied (`isPending` returns true for a different evidence value).

### Trigger Scenario

1. Byzantine node B sends validator V honest evidence E1 with `ConflictingBlock.Hash() = H1` where `H1[31] = 0x9D`.
2. Later (or concurrently) honest node A sends evidence E2 with `ConflictingBlock.Hash() = H2 = H1 XOR 0x62` (differs in last byte only).
3. `E1.Hash() == E2.Hash()` due to the truncation (pool key collision).
4. The pool stored E1 at key K; `isPending(E2)` returns true; E2 is silently discarded.
5. If E2 is the evidence with the highest-count commit signatures, the better evidence is lost.

### Developer Intent Investigation

- The `Hash()` function has a comment (line 314) acknowledging the hash is designed to cause intentional collisions for the same *permutation* of signatures, with a TODO to improve it. The comment does **not** acknowledge the off-by-one; the TODO describes adding more fields, not fixing the truncation.
- The CHANGELOG (UNRELEASED) contains a parallel fix for `ProposerPriorityHash` (PR #5613) which fixed a similar buffer-offset bug. That fix demonstrates awareness of this bug pattern but does **not** cover `LightClientAttackEvidence.Hash`.
- No known issue or PR was found in the local repository explicitly citing the `Size-1` off-by-one in `LightClientAttackEvidence.Hash`. This appears to be a **new, unreported bug**.
- Engineering principle: `copy(bz[:N-1], src)` vs `copy(bz[:N], src)` when `bz` was allocated with `make([]byte, N+n)` is a straightforward off-by-one. The adjacent `copy(bz[tmhash.Size:], buf)` correctly uses `tmhash.Size` as its start offset (not `tmhash.Size-1`), suggesting the `-1` in the first copy is an error and not intentional.

### Reproduction Test

- **File**: `repro/test_bug3_evidence_hash_collision.sh` (runs `artifact/cometbft/types/repro_bug3_evidence_hash_collision_test.go`)
- **Escalation level reached**: 0 (pure black-box — calls public `Hash()` method only)
- **Command**: `cd artifact/cometbft && go test ./types/ -run TestBug3 -v -count=1`

### Reproduction Result: PASS

```
=== RUN   TestBug3_HashTruncatesLastByte
    repro_bug3_evidence_hash_collision_test.go:114: BUG CONFIRMED: ConflictingBlock.Hash()[31] = 0xA5 is DROPPED from the evidence key
    repro_bug3_evidence_hash_collision_test.go:116:   actualHash (buggy):  AE399B41DD3AE9EEEF9AE750B394F8B50EDF7DB82032CBF69385E9513D2E9AE7
    repro_bug3_evidence_hash_collision_test.go:117:   correctHash (fixed): F384536383CC7624CFEC2E81A9CF6E5B0954AD2078F11317467DE7EC1604FC53
    repro_bug3_evidence_hash_collision_test.go:118:   differ at position:  31
--- PASS: TestBug3_HashTruncatesLastByte (0.00s)
=== RUN   TestBug3_EvidencePoolKeyCollision
    repro_bug3_evidence_hash_collision_test.go:196: COLLISION CONFIRMED
    repro_bug3_evidence_hash_collision_test.go:197:   bh1[31]       = 0x9D
    repro_bug3_evidence_hash_collision_test.go:198:   bh1prime[31]  = 0x62
    repro_bug3_evidence_hash_collision_test.go:199:   key(E1)       = 2D648E50E26275391D60731E6A907DD11E631443401B00DFB31343DC78C5B911
    repro_bug3_evidence_hash_collision_test.go:200:   key(E1prime)  = 2D648E50E26275391D60731E6A907DD11E631443401B00DFB31343DC78C5B911
    repro_bug3_evidence_hash_collision_test.go:201:   Both keys are equal → pool slot occupied by E1 silently suppresses E1prime
--- PASS: TestBug3_EvidencePoolKeyCollision (0.00s)
PASS
ok      github.com/cometbft/cometbft/types      0.015s
```

The tests confirm:
1. `actualHash` matches the buggy 31-byte computation exactly, not the correct 32-byte computation.
2. `bz[31]` (the 32nd byte in the key buffer) is always `0x00` — the last byte of the block hash is never written.
3. Two evidence values with block-hash last bytes `0x9D` and `0x62` produce **identical** pool keys `2D648E50...`.

### Recommendation

Change `types/evidence.go:326`:
```go
- copy(bz[:tmhash.Size-1], l.ConflictingBlock.Hash().Bytes())
+ copy(bz[:tmhash.Size], l.ConflictingBlock.Hash().Bytes())
```
The buffer `bz` is already allocated with `make([]byte, tmhash.Size+n)` so there is no risk of overflow. This is a one-character fix.

---

## Bug 2 — Double-Sign Check Off-By-One

- **Source**: Code Review (MC simulation found no violation; bug confirmed by code inspection)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `consensus/state.go:2647`

### Description

`checkDoubleSigningRisk` guards against validators that restart after a crash and may double-sign due to lost WAL. The loop `for i := int64(1); i < doubleSignCheckHeight` runs one fewer iteration than intended (`< N` instead of `<= N`). When `DoubleSignCheckHeight = 1` (the intended "check 1 block back" setting), `doubleSignCheckHeight = min(1, height) = 1` and the loop runs **zero** iterations at every height — providing no protection at all. The fix `i <= doubleSignCheckHeight` would make the loop check `LoadSeenCommit(height-1)`, the most recently committed block.

### Trigger Scenario

1. Operator configures `DoubleSignCheckHeight = 1` to enable one-block lookback on restart.
2. Validator V participates in height H and its signature is included in the committed block (stored in `LoadSeenCommit(H)`).
3. V crashes; WAL is lost.
4. V restarts. `Start()` calls `checkDoubleSigningRisk(H+1)`.
5. With `DoubleSignCheckHeight = 1`: `doubleSignCheckHeight = 1`; the buggy loop runs 0 iterations → returns `nil` (no error).
6. V enters consensus at height H+1 without detecting its prior signature at H.
7. In corner cases (e.g., V has already sent a precommit at H+1 under a different block before the crash), this can lead to a double-sign equivocation.

### Developer Intent Investigation

- The bug report cites open PR #5668 (approved by maintainer) as already containing the `<` → `<=` fix. This PR could **not** be independently verified from the local source tree (no git history, no online access).
- The CHANGELOG UNRELEASED section does **not** include this fix, suggesting the PR has not been merged into v0.38.19.
- The function comment (`// look back to check existence of the node's consensus votes`) clearly states the intent is to look back. `for i < N` vs `for i <= N` is a straightforward off-by-one against that stated intent.
- **Conclusion**: The bug is either newly found or the cited PR is real but unmerged. Either way, the code in v0.38.19 is buggy. Reported as REPRODUCED; if PR #5668 is confirmed, this becomes Code Review × Known and the status would downgrade to DROPPED.

### Reproduction Test

- **File**: `repro/test_bug2_double_sign_height1.sh` (runs `artifact/cometbft/consensus/repro_bug2_double_sign_height1_test.go`)
- **Escalation level reached**: 2 (state injection — blockStore populated directly with prior commit)
- **Command**: `cd artifact/cometbft && go test ./consensus/ -run TestBug2 -v -count=1`

### Reproduction Result: PASS

```
=== RUN   TestBug2_DoubleSignCheckZeroIterations
    repro_bug2_double_sign_height1_test.go:109: BUG CONFIRMED: checkDoubleSigningRisk(height=2, DoubleSignCheckHeight=1) returns nil
    repro_bug2_double_sign_height1_test.go:110:   doubleSignCheckHeight = min(1, 2) = 1
    repro_bug2_double_sign_height1_test.go:111:   Buggy loop:  for i=1; i<1  → 0 iterations → misses LoadSeenCommit(1)
    repro_bug2_double_sign_height1_test.go:112:   Validator address: A3C64BA40AC20FE9B6622E47157AAFCBADD21F00
    repro_bug2_double_sign_height1_test.go:127: FIXED code would find: prior signature in LoadSeenCommit(1)
    repro_bug2_double_sign_height1_test.go:136: Fixed code: 1 iteration checks LoadSeenCommit(1) → finds valAddr → would return ErrSignatureFoundInPastBlocks
    repro_bug2_double_sign_height1_test.go:137: SUMMARY: validator can double-sign because checkDoubleSigningRisk provides zero protection
--- PASS: TestBug2_DoubleSignCheckZeroIterations (0.00s)
=== RUN   TestBug2_LoopIterationCount_AllCases
    h=1 DSCH=1 → clamped=1 buggy=0_iters fixed=1_iters (gap=1)
    h=2 DSCH=1 → clamped=1 buggy=0_iters fixed=1_iters (gap=1)
    h=3 DSCH=1 → clamped=1 buggy=0_iters fixed=1_iters (gap=1)
    h=2 DSCH=2 → clamped=2 buggy=1_iters fixed=2_iters (gap=1)
    h=3 DSCH=2 → clamped=2 buggy=1_iters fixed=2_iters (gap=1)
    h=3 DSCH=3 → clamped=3 buggy=2_iters fixed=3_iters (gap=1)
    h=5 DSCH=3 → clamped=3 buggy=2_iters fixed=3_iters (gap=1)
    Key finding: DoubleSignCheckHeight=1 (common config default) results in
    ZERO protection at ALL heights due to the off-by-one.
--- PASS: TestBug2_LoopIterationCount_AllCases (0.00s)
PASS
ok      github.com/cometbft/cometbft/consensus  0.021s
```

The `TestBug2_DoubleSignCheckZeroIterations` test at escalation level 2:
- Injects a commit at height 1 (with the validator's address) into the blockStore.
- Calls `checkDoubleSigningRisk(2)` with `DoubleSignCheckHeight=1` → returns `nil` (the bug).
- The manually-executed fixed loop finds the prior signature at `LoadSeenCommit(1)`, proving the protection is suppressed by the off-by-one.

### Recommendation

Change `consensus/state.go:2647`:
```go
- for i := int64(1); i < doubleSignCheckHeight; i++ {
+ for i := int64(1); i <= doubleSignCheckHeight; i++ {
```
This ensures `DoubleSignCheckHeight = N` actually checks the last N heights (not N-1). Aligns with the stated intent of the function and its config documentation.

---

## Family 1 — Vote Extension Self-Bypass

- **Source**: Code Review (MC simulation reached no commit states in depth-58 traces)
- **Status**: FALSE POSITIVE
- **Severity**: —

### Code Audit

The bypass is at `consensus/state.go:2308`:
```go
if vote.Type == cmtproto.PrecommitType && !vote.BlockID.IsZero() &&
    !bytes.Equal(vote.ValidatorAddress, myAddr) { // Skip VerifyVoteExtension for own vote
```
The validator deliberately skips `ABCI.VerifyVoteExtension` for its own precommit when processing votes.

### Developer Intent Investigation

- The guard has an inline comment explicitly stating "Skip VerifyVoteExtension for own vote".
- The bug report cites `tendermint/tendermint#8487` as the design decision record. The inline comment unambiguously marks this as intentional.
- Rationale: the validator generated the extension itself via `ExtendVote` and trusts its own output; re-verifying it via ABCI would be redundant. All other validators independently verify each other's extensions, providing cross-validation.

### Classification

The code behavior is intentional and documented. The `ExtensionInCommitVerified` spec invariant is too strong: it requires ABCI verification for ALL validators including the self-vote. The correct invariant excludes `j = i`. This is a **spec invariant issue**, not an implementation bug.

### Recommendation (Spec)

Modify `ExtensionInCommitVerified` in `base.tla` to exclude the self-vote:
```tla
\A j \in Server \ {i} :   \* was: \A j \in Server
    (precommits[i][r][j] = decision[i][h]) => extABCIVerified[i][j][h]
```

---

## Family 4 — Blocksync maxPeerHeight Stale on Disconnect

- **Source**: Code Review (MC BFS explored only the CONSENSUS sub-space; blocksync actions unreachable)
- **Status**: FALSE POSITIVE
- **Severity**: —

### Code Audit

`blocksync/pool.go:449-451` contains a conditional recalculation: `updateMaxPeerHeight()` is called on disconnect only when `peer.height == pool.maxPeerHeight`. This means disconnecting a non-max-height peer leaves `maxPeerHeight` unchanged (correct), but disconnecting the max-height peer triggers a full recalculation. The concern is that if a peer's height drops below the current max (via a lower-height `SetPeerRange` report), the peer is banned and removed with its OLD height still recorded, which happens to be the max → `updateMaxPeerHeight()` IS called. The banning behavior (`blocksync/pool.go:384-393`) compensates for the gap.

### Developer Intent Investigation

No known issue or design comment was found specifically about the conditional recalculation. The banning behavior for peers that report lower heights appears to be the implementation's implicit guard.

### Classification

The model checking found no violations because all nodes start in CONSENSUS mode (spec Init predicate, `base.tla:1051`) and no action transitions a node to BLOCKSYNC. The invariant holds vacuously. Even with the spec gap corrected, the implementation's ban-on-height-decrease behavior would prevent the exact scenario the spec models. This is a **spec modeling gap**, not a code bug.

### Recommendation (Spec)

1. Fix the Init predicate in the hunt config to start at least one node in BLOCKSYNC mode.
2. Add the ban-on-height-decrease behavior to `SetPeerRange` in the spec so the model correctly represents what the implementation allows.
3. The fragile conditional recalculation should be hardened regardless: always call `updateMaxPeerHeight()` on any peer disconnect to eliminate the dependency on the banning behavior.
