# Instrumentation Spec — HotShot (Espresso Network)

Mapping between TLA+ spec actions in `base.tla` / `Trace.tla` and Rust source
locations in `crates/hotshot/`. The downstream harness-generation phase will
turn this into concrete `tracing::info!` calls and a per-event JSON writer.

## Section 1: Trace Event Schema

### Envelope (all events)

```json
{
  "tag":   "trace",
  "event": {
    "name":   "<spec action name>",
    "nid":    "<replica id as string>",
    "view":   <Nat>,
    "epoch":  <Nat>,
    "state":  { ... post-action state snapshot ... },
    "msg":    { ... event-specific fields ... }
  }
}
```

### State fields (captured at every event)

| Trace field | Spec variable | Source |
|---|---|---|
| `state.curView` | `curView[i]` | `consensus.read().await.cur_view()` |
| `state.curEpoch` | `curEpoch[i]` | `consensus.read().await.cur_epoch()` |
| `state.lockedView` | `lockedView[i]` | `consensus.read().await.locked_view()` |
| `state.latestVotedView` | `latestVotedView[i]` | `quorum_vote/mod.rs:447` `self.latest_voted_view` |
| `state.highestBlock` | `highestBlock[i]` | `consensus.read().await.highest_block()` |
| `state.highQcInMemView` | `highQcInMem[i].view` | `consensus.read().await.high_qc().view_number()` |
| `state.highQcPersistedView` | `highQcPersisted[i].view` | **Shadow field**: production code does not expose this; instrumentation must read directly from storage (`storage.high_qc().await`) just before/after the storage write. |
| `state.crashed` | `crashed[i]` | derived from harness, not the impl. |

### Message fields (per event)

See § 2 for which subset each event carries.

---

## Section 2: Action-to-Code Mapping

### `HandleQuorumProposalRecv`
- **Code location**: `crates/hotshot/task-impls/src/quorum_proposal_recv/handlers.rs:425` (`handle_quorum_proposal_recv` return)
- **Trigger point**: *after* the function returns `Ok(())` and AFTER the final `broadcast_view_change` (L417-423). State snapshot reads `consensus.read().await` once more.
- **Trace event name**: `"HandleQuorumProposalRecv"`
- **Fields**:
  - `msg.view`     — `proposal.data.view_number()` (Rust u64 → JSON)
  - `msg.leaf`     — `Leaf2::from_quorum_proposal(&proposal.data).commit()` (hex string)
  - `msg.parentLeaf` — `proposal.data.justify_qc().data.leaf_commit` (hex string)
  - `msg.epochClaim` — `option_epoch_from_block_number(...)` per L279-283
  - `msg.evidenceKind` — one of `"EvNone" | "EvTimeout" | "EvViewSync"` derived from `proposal.data.view_change_evidence()`
- **Notes**: must capture state AFTER all internal mutations (update_leaf at L114, update_locked_view at L126, update_high_qc inside helpers.rs:836). Use a single `consensus.read()` for the snapshot to avoid tearing.

### `SubmitVote`
- **Code location**: `crates/hotshot/task-impls/src/quorum_vote/handlers.rs:567` (`submit_vote` final broadcast)
- **Trigger point**: AFTER `broadcast_event(QuorumVoteSend(vote), ...)` (L564) but BEFORE function return. Important: this is also where Family B's "no persist of vote action" gap lives — capture `latestVotedView` *before* the broadcast and again after to confirm in-memory bump.
- **Trace event name**: `"SubmitVote"`
- **Fields**:
  - `msg.view` — `view_number` (u64)
  - `msg.leaf` — `leaf.commit()` (hex)
  - `msg.epoch` — `membership.epoch()` (option u64; null when None)
  - `msg.block_no` — `leaf.height()` if `membership.epoch().is_some()` else null
- **Notes**: a second SubmitVote at the same `(nid, view)` is a Family B equivocation signal — the spec uses `latestVotedView[s] = p.view` as the in-memory bump.

### `TimeoutVote`
- **Code location**: `crates/hotshot/task-impls/src/consensus/handlers.rs:449` (`handle_timeout` — the *send* side of timeout vote)
- **Trigger point**: AFTER signing and broadcasting `TimeoutVoteSend`. Capture the *digest* hex separately so Family A's epoch-strip is observable in trace.
- **Trace event name**: `"TimeoutVote"`
- **Fields**:
  - `msg.view` — `view_number` (u64)
  - `msg.epoch` — `cur_epoch` (option u64). **Family A note**: this is the *carrier* field; the signed digest at `simple_vote.rs:460-468` does NOT include it. The harness should also emit `msg.digest_hex` (the `TimeoutData2.commit()` output bytes) so a downstream check can confirm the strip.
  - `msg.digest_hex` — bytes from `TimeoutData2.commit()` (hex)

### `FormQC`
- **Code location**: `crates/hotshot/task-impls/src/vote_collection.rs` (`VoteCollectionTaskState::handle_vote` finalize path); for the *receive* side at the next leader, also `consensus/handlers.rs:79` (handle_quorum_vote_recv after threshold reached)
- **Trigger point**: AFTER the cert is constructed (i.e., the threshold-met branch in `VoteCollectionTaskState::handle_vote`) and BEFORE it is broadcast on the event bus.
- **Trace event name**: `"FormQC"`
- **Fields**:
  - `msg.view`    — `cert.view_number()`
  - `msg.leaf`    — `cert.data.leaf_commit`
  - `msg.epoch`   — `cert.data.epoch.unwrap_or_default()` (Family A: this is the signed-into digest, so it cannot be retagged)
  - `msg.signers` — list of stake-table indices in `cert.signatures`

### `FormTC`
- **Code location**: same as FormQC but for `TimeoutVote2` aggregator
- **Trigger point**: at threshold-met for `TimeoutCertificate2` construction
- **Trace event name**: `"FormTC"`
- **Fields**:
  - `msg.view`        — `tc.data.view`
  - `msg.epochClaim`  — `tc.data.epoch.unwrap_or_default()` (**Family A**: this is the cert-carried value, NOT the digest content)
  - `msg.signers`     — list of stake-table indices in `tc.signatures`
- **Notes**: For Family A bug-hunting it is critical to also emit `msg.digest_hex` so a downstream comparison can detect retagged certs sharing the same digest.

### `ObserveQC`
- **Code location**: `crates/hotshot/types/src/consensus.rs:1325` (`update_high_qc` entry)
- **Trigger point**: at the START of `update_high_qc` (BEFORE the `if self.high_qc == high_qc` early-return at L1327) so we capture every QC the node sees, including ones the impl silently drops at L1330.
- **Trace event name**: `"ObserveQC"`
- **Fields**:
  - `msg.view`    — `high_qc.view_number()`
  - `msg.leaf`    — `high_qc.data.leaf_commit`
  - `msg.epoch`   — `high_qc.data.epoch.unwrap_or_default()`
  - `msg.signers` — signer indices
  - `msg.accepted` — boolean: whether the L1330 check passes (i.e., whether the QC will become the new high_qc)
- **Notes**: this is the Family-B equivocation visibility instrumentation. Capturing `accepted = false` for a same-view-different-leaf QC is exactly the "silently dropped" case.

### `ProposeLeader`
- **Code location**: `crates/hotshot/task-impls/src/quorum_proposal/handlers.rs:740-820` (proposal creation final)
- **Trigger point**: AFTER the `QuorumProposalSend` broadcast.
- **Trace event name**: `"ProposeLeader"`
- **Fields**:
  - `msg.view`         — `proposal.data.view_number()`
  - `msg.leaf`         — leaf commit
  - `msg.evidenceKind` — one of `"EvNone"|"EvTimeout"|"EvViewSync"`

### `CommitLeaf`
- **Code location**: `crates/hotshot/task-impls/src/consensus/handlers.rs` (decide path, triggered by `LeafDecided`)
- **Trigger point**: AFTER the decided leaf is recorded.
- **Trace event name**: `"CommitLeaf"`
- **Fields**:
  - `msg.view` — view at which leaf was committed
  - `msg.leaf` — committed leaf commit

### `ViewSyncVote`
- **Code location**: `crates/hotshot/task-impls/src/view_sync.rs:702-706` (PreCommit→Commit vote), `:793-797` (Commit→Finalize vote), and `:899-918` (initial PreCommit vote)
- **Trigger point**: AFTER each `broadcast_event(...VoteSend(...), &event_stream)` call. Three sites; same event name with `msg.phase` distinguishing.
- **Trace event name**: `"ViewSyncVote"`
- **Fields**:
  - `msg.epoch` — `certificate.data().epoch` (or local `cur_epoch` for initial PreCommit)
  - `msg.view`  — `self.next_view`
  - `msg.relay` — `certificate.data().relay` (**Family C critical**: this is the cert-carried relay, NOT `self.relay`)
  - `msg.phase` — `"PhasePreCommit" | "PhaseCommit" | "PhaseFinalize"`
- **Notes**: capturing the cert-carried relay (rather than the replica's local `self.relay`) is exactly what surfaces the Family-C relay-rotation asymmetry at view_sync.rs:660-685.

### `FormViewSyncCert`
- **Code location**: aggregator construction sites in `view_sync.rs` (per-phase certificate building inside `ViewSyncTaskState::handle`).
- **Trigger point**: AFTER threshold met and the cert is broadcast via `ViewSync*CertificateRecv` event.
- **Trace event name**: `"FormViewSyncCert"`
- **Fields**:
  - `msg.epoch` — `cert.data().epoch`
  - `msg.view`  — `cert.view_number()`
  - `msg.relay` — `cert.data().relay`
  - `msg.phase` — phase
  - `msg.signers` — signer indices

### `Crash`
- **Code location**: harness-controlled (no production code path).
- **Trigger point**: harness drops the node process / clears Arc<RwLock<Consensus>>.
- **Trace event name**: `"Crash"`
- **Fields**: `nid` only.

### `Recover`
- **Code location**: harness restart — node startup at `crates/hotshot/hotshot/src/lib.rs:SystemContext::new`.
- **Trigger point**: AFTER `consensus.read().await.high_qc()` has been seeded from `storage.high_qc().await`.
- **Trace event name**: `"Recover"`
- **Fields**: `nid` only; the state snapshot captures the recovered values.

---

## Section 3: Special Considerations

### 3.1 `highQcPersisted` requires a shadow read

The implementation does not expose `storage.high_qc()` as a state-snapshot
field. Instrumentation must explicitly call `storage.high_qc().await` at every
event capture and write the result into `state.highQcPersistedView`. This adds
one storage read per event — acceptable for traces but should not be enabled
in production.

### 3.2 `pendingPersistHighQC` window (Family D)

The window between `storage.update_high_qc2(qc).await` (helpers.rs:781) and
`consensus_writer.update_high_qc(qc.clone())?` (helpers.rs:834) is the heart
of Family D's MC4 finding. To make this window visible in trace, emit a
synthetic event `"UpdateHighQcPersisted"` BEFORE the in-mem write (between
L818 and L820). The base spec does not have a separate action for this —
`UpdateHighQcPersistThenInMem` collapses the two updates because TLC's
interleaving semantics over `vars` already exposes the crash window. If a
deeper validation is needed (e.g., observing the *exact* persisted-only state
through a real crash), the spec should be split into two actions; this is a
known refinement axis.

### 3.3 `submit_vote` does not persist vote action — Family B

There is intentionally NO `storage.append_vote` call in `submit_vote`. The
trace cannot capture "I voted view V" because the impl does not record it.
The Family-B harness should therefore inject a crash event between
`broadcast_event(QuorumVoteSend(...))` and the *next* event for that node;
the recovered node will then re-vote at the same view. The trace will show
two `"SubmitVote"` events with the same `(nid, view)` but different
`msg.leaf` — that is the equivocation signal.

### 3.4 Byzantine actions are NOT in production instrumentation

`ByzReplayTcAcrossEpoch`, `ByzDoubleVote`, `ByzProposeMisdeclaredEpoch`, and
`ByzForceLockedViewAdvance` are model-only actions used during MC bug hunting.
They cannot be derived from honest production traces. The trace spec
intentionally omits them. Validation of honest traces against the base spec
will exercise the *honest* control flow only; bug hunting happens in MC.cfg /
MC_hunt_*.cfg.

### 3.5 Bootstrap initial state

`TraceInit` matches the base spec `Init` exactly. The first trace event
should be either `Crash` (for a node started in the middle of a network) or
`ProposeLeader` / `HandleQuorumProposalRecv` (for normal startup). If the
harness emits a synthetic `"Bootstrap"` event before genesis, it should be
filtered out at trace-loading time.

### 3.6 Symmetry and node naming

Node IDs in the trace must match the `Server` constant in `Trace.cfg`. Use
short string IDs (`"s1"`, `"s2"`, ...) rather than hex public keys, and
maintain a lookup table during instrumentation.

### 3.7 Field omission and zero values

JSON serialization in Rust often omits zero-valued fields. The
`Trace.tla` `ValidatePostState` predicates use exact equality on fields like
`state.curView` — the harness must therefore emit every field explicitly,
even when zero. Use `serde_json::to_string` with explicit struct fields, not
shortcut macros that may elide defaults.
