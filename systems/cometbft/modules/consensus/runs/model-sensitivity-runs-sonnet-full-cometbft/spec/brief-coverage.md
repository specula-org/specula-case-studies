# Phase 2.5 Self-Audit: Brief Coverage

Maps every claim in `modeling-brief.md` §2/§5/§6.1 to the spec and MC artifacts produced in Phase 2.

---

## §2 Bug Families → Hunt Configs

| Family | Brief §2 Title | Hunt Config | Target Invariant(s) |
|--------|---------------|-------------|---------------------|
| 1 | Vote Extension Verification Asymmetry | `MC_hunt_family1.cfg` | `ExtensionInCommitVerified`, `LightClientExtensionConsistency` |
| 2 | Double-Sign Protection Off-by-One | `MC_hunt_family2.cfg` | `NoDoubleSignAtHeight1` |
| 3 | Evidence Hash Collision via Off-by-One | `MC_hunt_family3.cfg` | `EvidenceDeduplicationSound` |
| 4 | Blocksync Peer State Manipulation | `MC_hunt_family4.cfg` | `MaxPeerHeightBoundedOnDisconnect`, `BlockSyncLiveness` |
| 5 | ABCI Response Callback Deadlock | **Excluded** (Go mutex re-entrancy; see brief §3.2) | — |
| 6 | Remote Signer Extension Protocol Gap | **Excluded** (wire protocol design gap; see brief §3.2) | — |

**Coverage**: All 4 modeled families (1–4) each have a dedicated hunting config. The 2 excluded families are documented in brief §3.2 with rationale (Go-level concurrency issues unsuitable for TLA+).

---

## §5 Invariants → Artifacts

| Invariant | Type | Enabled in Hunt Config | Also in MC.cfg | Notes |
|-----------|------|----------------------|----------------|-------|
| `ConsensusAgreement` | Safety | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` | Yes (always on) | Standard Tendermint agreement |
| `ExtensionInCommitVerified` | Safety | `MC_hunt_family1.cfg` | Commented out | Targets MC1 |
| `LightClientExtensionConsistency` | Safety | `MC_hunt_family1.cfg` | Commented out | Targets MC2 |
| `NoDoubleSignAtHeight1` | Safety | `MC_hunt_family2.cfg` | Commented out | Targets MC3 |
| `EvidenceDeduplicationSound` | Safety | `MC_hunt_family3.cfg` | Commented out | Targets MC4 |
| `MaxPeerHeightBoundedOnDisconnect` | Safety | `MC_hunt_family4.cfg` | Commented out | Targets MC5 |
| `BlockSyncLiveness` | Liveness | `MC_hunt_family4.cfg` (PROPERTIES) | Commented out | Targets Family 4 liveness |

**Coverage**: Every §5 invariant is enabled in at least one hunt config. Bug-family invariants are commented out in `MC.cfg` (the general model-checking run) to avoid spurious violations during unconstrained exploration; they are activated in targeted hunting configs only.

---

## §6.1 Model-Checkable Findings → Hunt Config Fault Setup

| ID | Brief Description | Hunt Config | Fault Setup That Makes It Reachable |
|----|------------------|-------------|--------------------------------------|
| MC1 | Proposer self-vote extension bypass enables application-invalid extension in commit | `MC_hunt_family1.cfg` | `MaxInvalidVELimit=1` (one Byzantine invalid extension injection); `Faulty={s3}` Byzantine server; self-bypass modeled at state.go:2310 via `ReceivePrecommitConsensus` branch for `m.source = i` |
| MC2 | Light client accepts commit with unverified extension signatures | `MC_hunt_family1.cfg` | `AcceptCommitLightClient` action enabled; `MaxInvalidVELimit=1` so a commit with extension that failed consensus-path ABCI check can be produced, then light client accepts it unconditionally |
| MC3 | Off-by-one at height=1 allows double-sign when WAL absent | `MC_hunt_family2.cfg` | `DoubleSignCheckHeight=1`, `MaxCrashLimit=1`, `MaxRestartLimit=1`; `RestartWithoutWAL` models node crash + restart without WAL at height=1; `lookbackChecked[v][1]=FALSE` since loop never runs |
| MC4 | Hash-colliding Byzantine evidence suppresses honest evidence | `MC_hunt_family3.cfg` | `HashAliases=(bh1:>"k1" @@ bh2:>"k1" @@ bh3:>"k3")` with `MaxInjectEvidenceLimit=1`; Byzantine `InjectCollidingEvidence` pre-populates pool key `<<commonH, "k1">>` before honest `SubmitLightClientEvidence` with colliding hash |
| MC5 | Byzantine peer reports two heights then disconnects; maxPeerHeight remains inflated | `MC_hunt_family4.cfg` | `MaxByzPeerReportLimit=2` (two `MCByzantineSetPeerRange` calls: first inflated height, then lower); `Faulty={s3}` then `RemovePeer(s3)`; `removePeer` bug at pool.go:449-451 modeled as conditional recalculation |

**Coverage**: Every §6.1 finding has a hunt config with the fault injection setup explicitly sized to make the violation reachable.

---

## Spec Variable Coverage (§4 Proposed Extensions)

| §4 Extension | TLA+ Variable | Location in base.tla |
|--------------|--------------|---------------------|
| Extension verification split | `voteExt`, `extABCIVerified`, `selfExtBypassed`, `lightClientAccepted`, `blocksyncAccepted` | `extVars` variable group |
| Self-extension bypass | `selfExtBypassed[v][h]` | set TRUE in `ReceivePrecommitConsensus` when `m.source = i` |
| Evidence pool key | `evidencePool`, `HashAliases`, `EvidencePoolKey(commonH, bh)` | `evidenceVars` variable group; key formula: `<<commonH, HashAliases[bh]>>` |
| Double-sign lookback | `walPresent[v]`, `lookbackChecked[v][h]` | `walVars` variable group; set in `CheckDoubleSigningRisk` |
| Peer max height | `maxPeerHeight`, `peerRecords[v]`, `localSyncHeight[v]` | `syncVars` variable group |
| Faulty Byzantine adversary | `Faulty ⊆ Server` (CONSTANT) | base.cfg / MC.cfg |

**Coverage**: All 6 §4 extensions are modeled. The `hashCollision` auxiliary variable (computed from `HashAliases`) is added in base.tla for debugging; it exposes the collision condition directly in `TraceAlias`.

---

## §3.2 Do-Not-Model Exclusions

| §3.2 Item | Reason Given | Outcome |
|-----------|-------------|---------|
| ABCI client mutex deadlock | Go goroutine/mutex semantics; existing test in PR #5850 | No spec action; not in any hunt config |
| WAL non-atomic durability | Compensated by EndHeightMessage fsync + ABCI handshake replay | Not modeled; crash recovery via `Recover` action abstracts over WAL correctness |
| Remote signer `extensionsEnabled` wire gap | Interface protocol fix; not a distributed safety question | No spec action |
| Remote signer resource exhaustion | Implementation-level; connection management change | No spec action |
| Mempool `CheckTx` race | Uncertain status; Go race detector territory | No spec action |
| Proposer timestamp (PBTS) | Separate analysis round (#1731) | No spec action |

---

## Completeness Check

**Every §5 invariant enabled in ≥1 hunt cfg**: YES (7 / 7)
**Every §2 modeled family has a targeting hunt cfg**: YES (4 / 4)
**Every §6.1 finding has a hunt cfg whose fault setup makes it reachable**: YES (5 / 5)
**Excluded families documented with rationale**: YES (Families 5 and 6)

**Output files produced**:
- `base.tla` — core spec with all 4 bug family extensions
- `base.cfg` — structural constants, no bug-family invariants
- `MC.tla` — counter-bounded fault injection wrappers
- `MC.cfg` — MC constants + limits, bug-family invariants commented out
- `MC_hunt_family1.cfg` — targets MC1, MC2 (Family 1)
- `MC_hunt_family2.cfg` — targets MC3 (Family 2)
- `MC_hunt_family3.cfg` — targets MC4 (Family 3)
- `MC_hunt_family4.cfg` — targets MC5 + BlockSyncLiveness (Family 4)
- `Trace.tla` — trace validation wrapper
- `Trace.cfg` — TraceMatched property enabled; safety invariants on
- `instrumentation-spec.md` — 24 action-to-code mappings with source locations and capture notes
- `brief-coverage.md` — this document
