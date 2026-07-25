# Aptos BFT — Deep Code Analysis: Decoupled Execution Pipeline & Block Storage

Scope: 14 files under `consensus/src/pipeline/` and `consensus/src/block_storage/`, plus collateral citations into
`pipeline/pipeline_builder.rs`, `safety-rules/src/safety_rules.rs`, `consensus/src/dag/` (only when called out by paths).
All line numbers refer to the source files at `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/`.

---

## 1. Pipeline phase diagram

The decoupled pipeline (`consensus.decoupled = true`) is wired together by
`decoupled_execution_utils.rs::prepare_phases_and_buffer_manager` (lines 29-138). Each phase runs as
its own tokio task spawned via `PipelinePhase::start` (`pipeline_phase.rs:88-108`); the `BufferManager`
sits in the middle and routes work through `tokio::select!` (`buffer_manager.rs:953-1012`).

```
                        ┌─────────────────────────────────────────────────┐
                        │          BufferManager (single async task)      │
                        │                                                 │
   OrderedBlocks  ─────▶│  block_rx (unbounded)                           │
   (from consensus)     │  buffer = LinkedList<BufferItem>                │
                        │  state of each item: Ordered → Executed         │
                        │                                       → Signed  │
                        │                                       → Aggregated│
                        └─────────────────────────────────────────────────┘
                              │      ▲        │     ▲        │     ▲       │
                              ▼      │        ▼     │        ▼     │       ▼
              ExecutionRequest │ EWaitReq │ SigRequest │ PersistReq          ──┐
              (CountedRequest) │          │            │                       │
                              ▼      │        ▼     │        ▼     │       │
        ┌──────────────────┐  │  ┌──────────────┐  │  ┌──────────┐ │  ┌──────────┐
        │ ExecSchedulePhase│──┘  │ ExecWaitPhase│──┘  │SigningPhse│─┘  │PersistPhase│
        │  (no DB)         │     │ (no DB)      │     │(no DB)    │    │(IO; calls  │
        │ produces fut     │     │ awaits fut   │     │ calls     │    │ executor   │
        └──────────────────┘     └──────────────┘     │ safety_   │    │ pre_commit/│
                                                     │ rules     │    │ commit_    │
                                                     │ .sign_    │    │ ledger via │
                                                     │ commit_   │    │ pipeline   │
                                                     │ vote      │    │ futures)   │
                                                     └──────────┘     └──────────┘
                                                                            │
                                                                            ▼
                                                              broadcast_commit_vote
                                                                (from pipeline_builder
                                                                line 1215-1217 inside
                                                                commit_vote() future)
                                                              + send_epoch_change
                                                                (persisting_phase.rs:75-79)
```

Per-block work for the Zaptos optimisations actually lives inside `pipeline_builder.rs` (the per-block
future graph). The BufferManager / phases above are a thin layer that *drives* those futures: the
SigningPhase only signs synchronously when the block has no per-block `commit_vote_fut` (signing_phase.rs:79-92);
the PersistingPhase only delivers the commit-proof to the per-block `commit_proof_tx` and waits for
`wait_for_commit_ledger()` (persisting_phase.rs:65-72).

### Where each operation actually happens

| Operation                          | Code location                                                     | Notes |
|------------------------------------|-------------------------------------------------------------------|-------|
| Commit signature created           | `signing_phase.rs:90-92` (calls `safety_rules.sign_commit_vote`); also `pipeline_builder.rs:1213-1218` (per-block fast path that broadcasts before phase runs) | Two paths; safety_rules does NOT persist anything for commit votes (`safety_rules.rs:372-418`). |
| Commit signature broadcast         | `pipeline_builder.rs:1215-1217` (per-block) and `buffer_manager.rs:741-744` (via `do_reliable_broadcast`) | Broadcast happens *before* the local node persists. |
| Commit proof first reaches persist | `persisting_phase.rs:65-71` (forwards via per-block `commit_proof_tx`) | Persisting phase does not write directly; it triggers the pipeline future `commit_ledger`. |
| Commit ledger durably written      | `pipeline_builder.rs:1297-1305` (`executor.commit_ledger(...)` inside `commit_ledger()` future) | Spawn-blocking call to the storage executor. |
| Pre-commit (optimistic) write      | `pipeline_builder.rs:1257-1263` (`executor.pre_commit_block`) | Happens after order proof but before commit proof. |
| Block tree pruning persisted       | `block_tree.rs:591-596` and `block_store.rs:858-873` (test-only path) | Best-effort; failure is `warn!`-only — see Section 4. |
| Insert block to disk               | `block_store.rs:524-526` (`storage.save_tree(vec![block], vec![])`) | Synchronous before in-memory insert. |
| Insert QC to disk                  | `block_store.rs:564-567` (`storage.save_tree(vec![], vec![qc])`)   | Same. |
| 2-chain TC to disk                 | `block_store.rs:582-585`                                          | Synchronous. |
| Fast-forward sync save             | `sync_manager.rs:619`                                             | Whole tree+QCs saved before `execution_client.sync_to_target`. |

### If the node crashes between signing and persisting

The commit vote is broadcast as soon as the local future signs it
(`pipeline_builder.rs:1215-1217`). The signature itself is **not** persisted — `safety_rules.sign_commit_vote`
(`safety_rules.rs:372-418`) only verifies and signs; it never updates `safety_data.last_voted_round`
(only the *block* vote path at `safety_rules.rs:218-225` does that). The acknowledgement-tracking
`AckState` in `commit_reliable_broadcast.rs:67-110` is in-memory only.

`buffer_manager.rs:861-863` (in `rebroadcast_commit_votes_if_needed`) acknowledges this explicitly:

```rust
// Since we don't persist the votes, nodes that crashed would lose the votes even after send ack,
// We'll try to re-initiate the broadcast after 30s.
```

Concrete crash window:
- Crash *after* `broadcast_commit_vote` but *before* `executor.pre_commit_block` ⇒ on-disk state still
  reflects the previous block; the node will re-derive the same signature on restart from
  `LedgerInfo` (deterministic), so equivocation is not introduced. But the buffer manager loses any
  partial signatures it had collected (`SignatureAggregator` is in-memory in
  `buffer_item.rs:65-77`), and pending commit votes cached in `BufferManager.pending_commit_votes`
  (`buffer_manager.rs:170, 264-265`) are also lost.
- Crash *after* `executor.pre_commit_block` but *before* `commit_ledger` ⇒ pre-committed state is on
  disk, but client-visible ledger is not. README says this is intended ("data is not visible to
  clients"). State is recovered from `pre_commit_status` and `recovery_data.start(...)`.

---

## 2. Channel / hand-off inventory

All inter-phase channels are constructed by `decoupled_execution_utils.rs::prepare_phases_and_buffer_manager`
via `create_channel::<T>()` which is `unbounded::<T>()` (`buffer_manager.rs:96-100`) — so **every**
inter-phase channel has unlimited buffer.

| # | From → To                                                | Channel kind | Buffer    | Message type                    | Code |
|---|----------------------------------------------------------|--------------|-----------|---------------------------------|------|
| 1 | consensus → BufferManager                                | unbounded    | unbounded | `OrderedBlocks`                 | `decoupled_execution_utils.rs:34` (`block_rx`) |
| 2 | BufferManager → ExecutionSchedulePhase                   | unbounded    | unbounded | `CountedRequest<ExecutionRequest>` | `decoupled_execution_utils.rs:55-56` |
| 3 | ExecutionSchedulePhase → BufferManager                   | unbounded    | unbounded | `ExecutionWaitRequest`          | `decoupled_execution_utils.rs:57-58` |
| 4 | BufferManager → ExecutionWaitPhase                       | unbounded    | unbounded | `CountedRequest<ExecutionWaitRequest>` | `decoupled_execution_utils.rs:67-68` |
| 5 | ExecutionWaitPhase → BufferManager                       | unbounded    | unbounded | `ExecutionResponse`             | `decoupled_execution_utils.rs:69-70` |
| 6 | BufferManager → SigningPhase                             | unbounded    | unbounded | `CountedRequest<SigningRequest>`| `decoupled_execution_utils.rs:80-81` |
| 7 | SigningPhase → BufferManager                             | unbounded    | unbounded | `SigningResponse`               | `decoupled_execution_utils.rs:82-83` |
| 8 | BufferManager → PersistingPhase                          | unbounded    | unbounded | `CountedRequest<PersistingRequest>` | `decoupled_execution_utils.rs:94-95` |
| 9 | PersistingPhase → BufferManager                          | unbounded    | unbounded | `ExecutorResult<Round>`         | `decoupled_execution_utils.rs:96` |
|10 | network/RPC → BufferManager                              | aptos_channel| (per-key) | `(Author, IncomingCommitRequest)` | `buffer_manager.rs:127-132` |
|11 | epoch_manager → BufferManager (reset)                    | unbounded    | unbounded | `ResetRequest`                  | `decoupled_execution_utils.rs:35` (`sync_rx`) |
|12 | verification worker → main loop (verified votes)         | unbounded    | unbounded | `IncomingCommitRequest`         | `buffer_manager.rs:932` |

In addition, every block has its **own** per-block `oneshot` channels constructed in
`pipeline_builder.rs:316-365` (`qc_tx`, `rand_tx`, `order_vote_tx`, `order_proof_tx`,
`commit_proof_tx`, `secret_shared_key_tx`). The phases hand off to those (`persisting_phase.rs:67-69`,
`execution_schedule_phase.rs:65-71`).

### Phase task counter

`CountedRequest` (`pipeline_phase.rs:47-64`) wraps every inter-phase request and holds a
`TaskGuard` that increments `ongoing_tasks` on construction, decrements on drop. The guard is
dropped after `processor.process(req).await` returns (`pipeline_phase.rs:90-95` — the `_guard` falls
out of scope before `tx.send(response)` on line 102). `BufferManager::reset` polls
`ongoing_tasks > 0` (`buffer_manager.rs:591-593`) — so reset waits for *in-flight processing*, but
**not** for the response message to be flushed into the next channel (it is already gone from the
counted scope by then; cf. line 95 vs line 102).

---

## 3. Crash-window table — every persistence write

Below: every storage write reachable from the analysed files.

| Write                                  | What it writes                                                    | Preceding non-atomic ops                                                                     | Crash *before*                                                                                                            | Crash *after*                                                                                  |
|----------------------------------------|-------------------------------------------------------------------|---------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `storage.save_tree(vec![block], vec[])` `block_store.rs:524-526` | A single block | Sleep until block_time (`block_store.rs:514-523`); pipeline_builder may already have spawned `materialize/decrypt/prepare` futures (`block_store.rs:502-509`) | Block lost, but consensus will re-deliver via QC chain on restart. | Block on disk, but `BlockTree.id_to_block` may not yet contain it (line 527 `inner.write().insert_block`). Recovery will reconstruct from saved tree. |
| `storage.save_tree(vec![], vec[qc])` `block_store.rs:564-567` | A single QC | The pipelined block's `set_qc` was already mutated in memory (`block_store.rs:559`) and `BlockStage::QC_ADDED` observed (lines 549-558) | QC lost. In-memory `pipelined_block` already has the QC stored, so this run is fine but next start will not have it. **Inconsistent** if process is restarted with stale state — the block will not have a QC for it, but other validators believe it does. | OK. |
| `storage.save_highest_2chain_timeout_cert(tc)` `block_store.rs:582-585` | TC | Round comparison only (line 579) | Old TC remains. | New TC durable. |
| `storage.save_tree(blocks, qcs)` `sync_manager.rs:619` | All gap blocks + QCs | `LedgerRecoveryData::find_root` validation (lines 593-617); `abort_pipeline_for_state_sync` *before* this in line 622-627? No — order is **save then abort**, but abort happens *after* save | Sync re-runs from stored state. | Sync continues; if executor.sync_to_target (line 628-630) crashes after save, **storage has the new tree but the actual state still points at the old root**. Recovery via `storage.start(...)` (line 635) is intended to handle. |
| `executor.pre_commit_block(block.id())` `pipeline_builder.rs:1257-1263` | Per-block "soft commit" to ledger DB | `parent_pre_commit_fut.await`, `order_proof_fut.await`, `pre_commit_status` mutex check | State not pre-committed. The buffer item is still `Signed` or `Aggregated` in memory only. | Pre-committed; if `commit_ledger` does not run, state visible only to the executor's pre-commit table, not to clients. |
| `executor.commit_ledger(ledger_info_with_sigs)` `pipeline_builder.rs:1299-1305` | The committed ledger info (final, client-visible) | `parent_commit_fut.await`, `pre_commit_fut.await`, `commit_proof_fut.await` (line 1287-1289) | Ledger not committed (state is still pre-committed). On restart, since the commit proof is in `recovery_data` only if it was received in time, the block may need to be replayed from the QC. | OK. |
| `storage.prune_tree(ids_to_remove)` `block_tree.rs:591-595` | Removes pruned blocks/QCs from DB | `find_window_root`, `find_blocks_to_prune` (lines 588-589) — pure in-memory | OK; pruning is best-effort, errors only `warn!` on line 595. **`process_pruned_blocks`, `update_window_root`, `update_highest_commit_cert` (lines 597-599) still happen even if the storage prune fails.** | OK. |
| `storage.prune_tree(ids_to_remove)` `block_store.rs:858-866` (test/fuzz only `cfg(any(test, feature = "fuzzing"))`)| Same | Same | warn-only; in-memory updates proceed. | OK. |
| `state.save_certified_node(node)` (DAG path) `dag/dag_store.rs:526` | Not in BFT-pipeline files, mentioned for completeness | – | – | – |

### Notable crash-window observations

- **CW-1 (signing/persisting gap).** Signing happens in `pipeline_builder.rs:1213-1218` (broadcast
  commit vote inside `commit_vote()` future) before any DB write; the corresponding state mutation
  (`safety_data.last_voted_round`) **never happens for commit votes** (compare
  `safety_rules.rs:218-228` for proposal votes vs `safety_rules.rs:372-418` for commit votes — the
  latter has no persistence).
  Crash here is safe in principle (the commit vote can be re-derived from the same `LedgerInfo`),
  but `BufferManager` loses every cached `pending_commit_votes` and every in-memory partial
  aggregator (`buffer_item.rs:65-77`).
- **CW-2 (commit-vote rebroadcast).** `buffer_manager.rs:861-863` documents that crashed nodes lose
  votes even after acknowledging them. With reliable-broadcast retransmit on a 30s/1500ms cadence,
  a crash here is recoverable as long as quorum stays up.
- **CW-3 (pre-commit vs commit gap).** Pre-commit runs after order proof, commit_ledger after
  commit proof. A crash between writes leaves an over-committed pre-commit table that
  `pre_commit_status` re-synchronises — but only if the on-disk `pre_commit_status` is consistent
  with what was persisted; `pre_commit_status` itself is **in-memory only** (`pipeline_builder.rs:83-117`),
  so on restart it starts at round 0 and is updated by `BlockStore::build` (`block_store.rs:251-253`)
  using `root_block_round`. If pre_commit ran for round R but the run did not finish writing the
  ledger to root metadata, the recovered status may understate progress.
- **CW-4 (QC saved but block already mutated).** `insert_single_quorum_cert`
  (`block_store.rs:531-568`) calls `pipelined_block.set_qc(...)` in-memory at line 559, **then**
  saves to storage at line 564. If we crash between the two, the in-memory tree (this process) is
  fine, but on restart the QC is missing from the recovery data — see also Section 6.
- **CW-5 (prune errors swallowed).** `block_tree.rs:591-596` and `block_store.rs:856-866` both
  treat `storage.prune_tree` failure as a warning, then proceed to mutate the in-memory tree
  unconditionally. This means the in-memory tree can advance its `commit_root_id` /
  `window_root_id` (lines 597-599) while the on-disk store still contains pruned blocks — recoverable
  on restart but weaker durability semantics than the comment claims ("kept consistent with executor"
  is conditional on the next commit succeeding).

---

## 4. Block-store atomicity findings

### What is atomic

- **Single in-memory tree mutation under `RwLock`.** `BlockStore::inner` is `Arc<RwLock<BlockTree>>`
  (`block_store.rs:86`). Writers hold the write lock for one method (`update_ordered_root`,
  `insert_quorum_cert`, etc.). The writes are atomic *within* one call.
- **`commit_callback` block_tree side.** `block_tree.rs:567-600` runs under the caller's write
  lock (caller in `block_store.rs:490-499` does `tree.write().commit_callback(...)`), so
  `prune_tree` IO + `process_pruned_blocks` + `update_window_root` + `update_highest_commit_cert`
  all happen while holding the lock. **However** these include synchronous
  `storage.prune_tree(...)` IO under the write lock — that blocks readers, and any in-flight
  `path_from_commit_root`, `get_block`, etc. wait until storage IO finishes. (See "what isn't atomic"
  below for what this still doesn't atomise across.)

### What is **not** atomic

- **A1: `insert_single_quorum_cert` mutates in-memory state then disk.**
  `block_store.rs:531-568`: `pipelined_block.set_qc` (line 559) and the metric observation
  (lines 549-558) happen before `storage.save_tree(vec![], vec![qc])` (line 564). On restart we may
  see the QC on the in-memory tree (this process) but never persisted. Crash here → next start
  loses the QC even though it was visible to consumers (e.g. `BlockReader::highest_quorum_cert`
  may have already returned this QC to a caller).
- **A2: `BlockTree::insert_quorum_cert` advances multiple fields one-by-one.**
  `block_tree.rs:349-386`: under one write lock it sets `highest_certified_block_id` +
  `highest_quorum_cert` (lines 367-371), then `id_to_quorum_cert.entry(...).or_insert_with`
  (lines 376-378), then `highest_ordered_cert = Arc::new(qc.into_wrapped_ledger_info())` (line 382).
  All atomic w.r.t. external readers because the write lock is held the entire time. **However**
  `update_highest_commit_cert` is *not* called here — `highest_commit_cert` still lags. Result:
  there is a window where `highest_ordered_cert > highest_commit_cert` even though the same QC
  could in principle satisfy both. A reader observing `highest_ordered_cert` and
  `highest_commit_cert` between unrelated `insert_quorum_cert` and `commit_callback` (which is
  what advances commit cert via `update_highest_commit_cert`, `block_tree.rs:341-346`) will see
  inconsistent values.
- **A3: `send_for_execution` mutates two roots non-atomically.** `block_store.rs:348-351`:
  ```rust
  self.inner.write().update_ordered_root(block_to_commit.id());
  self.inner.write().insert_ordered_cert(finality_proof_clone.clone());
  ```
  Two **separate** `write()` acquisitions. A reader between them sees the new ordered_root but the
  old highest_ordered_cert. This is the kind of "QC visible but tree not yet" race the prompt asked
  about — **confirmed**.
- **A4: `BlockStore::send_for_execution` then `execution_client.finalize_order`.**
  Same method, lines 348-358: in-memory tree updates (lines 348-351) happen **before**
  `execution_client.finalize_order` (line 354), which is the call that hands the blocks to the
  pipeline (and eventually `pre_commit`/`commit_ledger`). If `finalize_order` errors, the tree was
  already advanced — `expect("Failed to persist commit")` (line 357) panics, but only after the
  side effect on the in-memory tree has happened.
- **A5: `commit_callback` storage IO under write lock.** `block_tree.rs:591-595` runs
  `storage.prune_tree(...)` while holding the write lock. This serialises block-store reads against
  IO; not an atomicity bug but a latency/ordering hazard. If `storage.prune_tree` fails, the lock
  is still held for `process_pruned_blocks` + `update_window_root` + `update_highest_commit_cert`,
  so the in-memory tree progresses even though storage didn't.
- **A6: Pruning order — in-memory before disk in test path.** `block_store.rs:855-873` (test/fuzz
  only): IDs to remove are computed under `inner.read()` (line 856), then `storage.prune_tree` is
  called outside any lock (line 858), then `inner.write()` advances three roots and process pruned
  blocks. A concurrent `insert_block` can run between read and write, observing stale roots.
- **A7: `process_ordered_blocks` sends to executor before pushing to buffer.**
  `buffer_manager.rs:412-431`: the `ExecutionRequest` is dispatched (lines 415-418) **before** the
  `BufferItem` is pushed onto the buffer (line 431). Since execution happens on a separate task,
  the `ExecutionResponse` could in principle arrive at the BufferManager (`process_execution_response`,
  line 627-698) before the item is in the buffer. Mitigation: `process_execution_response` is on
  the same `select!` arm as `process_ordered_blocks`, so they execute serially in the BufferManager
  loop. **Still**, `find_elem_by_key` on line 630 returns `None` if the item is not found — the
  result is dropped silently (line 631-633). That is correct only if dispatch and push always run
  before the response can come back; if the executor pipeline ever returns synchronously
  (`spawn_ready_fut`-style), this is a hidden assumption.
- **A8: `update_highest_commit_cert` indirectly advances `commit_root_id`.**
  `block_tree.rs:341-346`: when the new commit cert has a higher round, the function calls
  `update_commit_root(self.highest_commit_cert.commit_info().id())`. The `assert!(self.block_exists(&root_id))`
  (line 442) panics if the corresponding block was pruned. There is no guarantee that the block
  for the new commit_cert is still in the tree — `find_blocks_to_prune` keeps the children of the
  new window root, but `commit_root_id` can lag the window root (commit_root and window_root are
  separately tracked and updated; cf. `block_tree.rs:436-454`).

---

## 5. Sync-manager Byzantine surface

### What is **accepted from peers**

- `BlockRetrievalResponse` payloads: each `Block` returned by a peer is checked for hash match on
  the head (`sync_manager.rs:980-986`) and target (lines 988-1011), but the **content** of each
  block — including its embedded `quorum_cert` — is consumed without independent signature
  verification. The QCs are then inserted via `insert_single_quorum_cert` in `fetch_quorum_cert`
  (`sync_manager.rs:359-364`).
- `fast_forward_sync` (`sync_manager.rs:481-641`): blocks come from `retrieve_blocks_in_range`
  (line 510), with the constraint `blocks[i].id() == quorum_certs[i].certified_block().id()`
  (line 582). The `quorum_certs` come from the peer-supplied `block.quorum_cert()` chain
  (lines 521-527). **The first QC in the list is `highest_quorum_cert`, supplied by the *caller*
  (the peer's SyncInfo), not the chain.** Verification: `LedgerRecoveryData::new(...).find_root`
  (lines 593-617) only checks that a root can be derived; it does not by itself verify each
  intermediate QC's signature.
- `BlockRetriever::retrieve_block_chunk` (`sync_manager.rs:783-895`) trusts the peer-returned
  blocks. If `retrieve_batch_size == 1`, it can satisfy itself from `pending_blocks` (lines 801-820)
  — i.e. self-fulfilling RPC.
- `process_block_retrieval_inner` (`sync_manager.rs:659-707`) is the *server* side, returning
  blocks the peer asked for. Because the server returns whatever is in its tree, the requester's
  trust model must verify on receipt. (See above — verification is incomplete.)

### Is the fetched state validated against signatures?

- The peer-claimed `highest_quorum_cert` is **the QC the caller already trusts** (it came from the
  `SyncInfo` whose authenticity is presumably verified by the caller of `add_certs`). So as long
  as `add_certs` is only called with verified `SyncInfo`, this anchor is OK.
- But the **chain of intermediate QCs** is constructed locally from `block.quorum_cert()`
  attached to each peer-returned block (`sync_manager.rs:521-527`). Each block's QC is *not* verified
  inside `fast_forward_sync`. A Byzantine peer could supply blocks with **fake** `quorum_cert`
  fields — the only check is `blocks[i].id() == quorum_certs[i].certified_block().id()`
  (line 582), which is satisfied by self-consistent fakes.
  - The downstream `LedgerRecoveryData::find_root` (lines 593-617) and `recovery_data.start(...)`
    (line 635) eventually verify, but only against the trusted ledger info anchor; intermediate
    QC-on-block links can in principle be forged if the verifier validates only the root and not
    each link.
- `fetch_quorum_cert` (`sync_manager.rs:328-365`) calls `insert_single_quorum_cert` for each
  intermediate QC (line 361). `insert_single_quorum_cert` itself (`block_store.rs:531-568`) does
  **not** verify the QC's signature — it only checks block-info equality with the local block and
  asserts on round consistency. The signature verification of the QC is supposed to happen
  elsewhere (the QC enters the system through `insert_quorum_cert` paths in the round manager).
  In `fetch_quorum_cert`, a peer can therefore push **unverified QCs** into the tree.
- `insert_quorum_cert` in `sync_manager.rs:270-296` does not call `qc.verify(...)` either — it
  decides between fetch and direct insert based on `need_fetch_for_quorum_cert`, but neither path
  verifies the QC's aggregated signature against the validator set. The verification responsibility
  is delegated to the entry points that constructed the `SyncInfo`.

**Bottom line:** `sync_manager.rs` largely trusts that the caller's `SyncInfo` and the `QuorumCert`
arguments have already been verified (e.g. by `RoundManager` or `EpochManager` when the SyncInfo
was first received). Any intermediate QC harvested from peer-returned blocks is inserted into the
tree without re-verification.

### Could a Byzantine peer push a block with a fake QC?

Yes, in the following sense: if the peer-returned block contains a forged `quorum_cert` field, the
block is inserted alongside that QC into our tree (`fetch_quorum_cert` at lines 359-364 calls
`insert_single_quorum_cert(block_qc)` then `insert_block(block)`). The QC's signature is **not
verified inside the sync path itself** — verification depends on the verifier in the round manager
having vetted the blocks. The defence is the eventual root-anchored validation:
`LedgerRecoveryData::find_root` (`sync_manager.rs:593-617`) makes sure a coherent chain leads from
the trusted root. But during fast-forward sync we may transiently store the fake QC.

---

## 6. Asynchronous hand-off race surface

### State that lives in one phase but is read in another

- **`pipelined_block.pipeline_tx()` and `pipeline_futs()`** are mutated by phases as the block
  flows: `execution_schedule_phase.rs:65-71` sends randomness and secret-shared key; `persisting_phase.rs:65-72`
  sends commit proof and waits for `commit_ledger`. Each `tx.take()` is single-shot (consumed via
  `Option::take`). If a block reaches `persisting_phase` more than once (e.g. due to retry path
  in `advance_signing_root`, `buffer_manager.rs:486-489`), the second take returns `None` and the
  commit proof never reaches the future.
- **`SignatureAggregator` lives inside the `BufferItem`** (`buffer_item.rs:65-77`). It is
  consumed by `try_advance_to_aggregated` (`buffer_item.rs:294-348`) which calls
  `aggregate_and_verify`. Concurrent flow: `process_signing_response` (line 712-749) acquires
  `signing_root` cursor, takes the item out (line 733), and replaces it (line 744 or 746). During
  this critical section other commits coming through `process_commit_message` (line 754-840) could
  interleave **only if they are dispatched on a separate task** — they are not; they share the
  BufferManager `select!` loop. So this is single-threaded by design.

### Phases that can process out-of-order

- `ExecutionSchedulePhase` and `ExecutionWaitPhase` run as **separate tasks** with a futures
  channel between (`decoupled_execution_utils.rs:56-78`). Schedule produces an `ExecutionWaitRequest`
  containing a `BoxFuture`; Wait awaits it. Schedule passes through Buffer manager
  (`process_execution_schedule_response`, `buffer_manager.rs:616-623`) which **forwards** the
  wait request as a `CountedRequest` to `execution_wait_phase_tx`. So the buffer manager re-injects
  ordering — but the response hand-off after `wait_for_compute_result` (lines 73-79 of schedule
  phase) is independent per future. Two blocks A,B with B's compute-result completing first will
  arrive at the buffer manager in the order their futures resolve, not their request order.
- The buffer manager handles this by indexing in the buffer with `find_elem_by_key`
  (`buffer_manager.rs:630`), so **out-of-order completion is OK**. But this means
  `execution_root` is only an *advancement hint*, not a strict ordering invariant.
- `process_commit_message` (`buffer_manager.rs:754-840`) calls `find_elem_by_key` against the
  buffer head (line 768) and produces an Aggregated transition. If commit messages for round R+1
  arrive before round R's votes complete, R+1's item can become Aggregated first. That's
  consistent with the `advance_head` walk (`buffer_manager.rs:500-559`) which pops items until it
  hits the target — **but the popped items in between must already be Aggregated**. The
  `unwrap_aggregated` on line 512 panics if any prefix item isn't yet aggregated.
  - This is the classic "out-of-order aggregation" hazard: if R is `Signed` and R+1 is
    `Aggregated`, `advance_head(R+1)` will iterate past R, call `item.get_blocks().clone()` (line
    504) for R, then reach R+1 and try `unwrap_aggregated()` (line 512). The unwrap is fine for
    R+1 itself, but R's blocks were already added to `blocks_to_persist` (line 504) and dispatched
    to the persist channel (lines 541-546) **before R was Aggregated** — so the persist phase will
    receive R's blocks under the commit-proof of R+1.
  - The README claims this is acceptable because R+1's commit-proof commits R as a prefix
    (`pipeline_builder.rs:1292-1294`). The `commit_ledger` future drops blocks whose `block.id()`
    does not match the commit proof's `commit_info.id()`, so the prefix-commit assumption is what
    makes this safe. **Subtle but correct.**

---

## 7. Buffer manager & ordering

### Where ordered blocks enter

- `buffer_manager.rs:956-963`: `block_rx.next()` arm of the select loop. Calls
  `process_ordered_blocks` (line 383-432). This pushes to the buffer (line 431) **after**
  dispatching the execution request (line 415-418).

### How buffer items are tracked

- `Buffer<BufferItem>` in `buffer.rs:20-25`: a `HashMap<HashValue, LinkedItem<T>>` plus head/tail
  cursors. `LinkedItem` has an `index` to allow `find_elem_by_key` to enforce "after cursor"
  semantics (`buffer.rs:137-145`).
- `BufferItem` has 4 states (`buffer_item.rs:84-89`). Transitions via `advance_to_executed_or_aggregated`
  (lines 114-195), `advance_to_signed` (lines 197-228), `try_advance_to_aggregated_with_ledger_info`
  (lines 232-292), `try_advance_to_aggregated` (lines 294-348). Each transition is single-step
  inside one `take` + `set` on the buffer.

### Reset / reconfig handling

- `BufferManager::reset` (`buffer_manager.rs:564-594`):
  1. Drains `pending_commit_blocks` by **awaiting** each block's `wait_for_commit_ledger` (lines 565-569).
  2. Drains the buffer by **aborting** each block's pipeline (lines 570-576).
  3. Replaces the buffer (line 577); clears roots.
  4. Drains the `block_rx` queue (lines 583-589).
  5. Polls `ongoing_tasks` to zero with 10ms sleep (lines 591-593).
- `process_reset_request` (`buffer_manager.rs:597-614`) handles `Stop` (sets `stop=true`) and
  `TargetRound` (updates `highest_committed_round` and drains pending commit proofs to that round
  via `drain_pending_commit_proof_till`, lines 364-379).
- **Epoch-end reset:** triggered at `advance_head` line 548-551 if commit proof ends epoch — the
  reset is initiated **after** the persist request has been sent (line 541-546) so the persist
  phase can finish its in-flight work.

### What if execution returns a different result than signing expected?

- Two separate cases:
  1. **Pure execution**: `process_execution_response` (lines 627-698). The result advances the
     item from `Ordered` → `Executed`. There's no signing yet at that point. So "signing expected
     X but execution returned Y" cannot occur on the *first* execution path.
  2. **Pre-aggregated commit proof was inserted while the item was Ordered**: this is the
     fast-forward path. `OrderedItem.commit_proof` (`buffer_item.rs:60`) is set by
     `try_advance_to_aggregated_with_ledger_info` for Ordered items (lines 272-287). When
     execution finishes, `advance_to_executed_or_aggregated` at lines 121-189 verifies
     `commit_proof.commit_info() == commit_info` via **`assert_eq!`** at `buffer_item.rs:149`.
     **A panic on inconsistency.** If the local executor produces a different result than what the
     commit-proof from peers asserts, the BufferManager process panics. This is the correct safety
     behaviour (we cannot sign two conflicting commit infos), but it's a hard crash.
  3. Similarly `try_advance_to_aggregated_with_ledger_info` for `Executed` items asserts
     `commit_info == *commit_proof.commit_info()` (`buffer_item.rs:262`) — same hazard.

---

## 8. TODOs / FIXMEs / WARNs (across all 14 files + nearby)

| File:Line | Marker | Text | Risk |
|-----------|--------|------|------|
| `buffer_manager.rs:801` | TODO | "send_commit_vote() doesn't care about the response and this should be direct send not RPC" | RPC misuse for fire-and-forget; protocol-level oddity, not safety. |
| `buffer_manager.rs:828` | TODO | Same for `send_commit_proof()` | Same. |
| `buffer_manager.rs:861-863` | comment / WARN | "Since we don't persist the votes, nodes that crashed would lose the votes even after send ack" | Documents persistence gap. |
| `buffer_manager.rs:381-396` (info macro) | log | "the queue size is {}" | Reveals unbounded growth concern. |
| `buffer_manager.rs:550` | comment | "the epoch ends, reset to avoid executing more blocks, execute after this persisting request will result in BlockNotFound" | Documents reset-during-pipeline race rationale. |
| `block_store.rs:778` | TODO | "cleanup" — about pipeline_pending_latency | Cosmetic. |
| `block_tree.rs:381` | comment | "Question: We are updating highest_ordered_cert but not highest_ordered_root. Is that fine?" | **Live unanswered concern about state consistency.** |
| `block_tree.rs:592-595` | warn | "fail to delete block" / "it's fine to fail here, as long as the commit succeeds, the next restart will clean up dangling blocks" | Best-effort persistence assumption. |
| `block_tree.rs:327-332` | warn | "Multiple blocks received for round" | Equivocation warning that does not reject the block. |
| `block_store.rs:864` | warn | "fail to delete block" | Same as block_tree. |
| `sync_manager.rs:530-531` | TODO | "this is probably still necessary, but need to think harder, it's pretty subtle" — about forked-QC fetch in non-order-vote path | **Author admits sync-path subtlety.** |
| `safety-rules/src/safety_rules.rs:412-413` (collateral) | TODO | "add guarding rules in unhappy path" / "add extension check" — inside `guarded_sign_commit_vote` | **No durability guard for commit votes.** |
| `pipeline/buffer_manager.rs:734` | comment | "it is possible that we already signed this buffer item (double check after the final integration)" | Author flagging unverified invariant. |

---

## 9. Top suspicious findings

Mapped to bug families used by the case study (Persistence/Atomicity, Async-handoff Race,
Byzantine Acceptance, Reset/Reconfig, Crash Window, Pre-commit/Commit ordering).

### F1 — `insert_single_quorum_cert` makes the QC visible in-memory before persisting it. (Persistence/Atomicity)
- File: `block_store.rs:531-568`.
- `pipelined_block.set_qc(Arc::new(qc.clone()));` at line 559 mutates the in-memory tree; only at line 564 do we hit `storage.save_tree(vec![], vec![qc.clone()])`. Crash between lines 559 and 564 ⇒ this run thinks it has the QC, broadcasts it, advances state, but a restarted node loses the QC. Combined with **F2** below this is a real "QC visible to one consumer, missing to another" race.

### F2 — Two-step root update in `send_for_execution` exposes inconsistent state to readers. (Async-handoff Race)
- File: `block_store.rs:348-358`.
- `self.inner.write().update_ordered_root(...)` then a separate `self.inner.write().insert_ordered_cert(...)`. Between them, any reader sees the new ordered root with the old ordered cert. `BlockReader::sync_info` (`block_store.rs:692-700`) and many other callers grab whichever pointer they want without correlating; they can produce a self-contradictory `SyncInfo`.

### F3 — `commit_callback` lets in-memory tree advance even if persistent prune fails. (Persistence/Atomicity)
- File: `block_tree.rs:591-599`.
- If `storage.prune_tree` returns `Err`, code logs `warn!` and **then** runs `process_pruned_blocks`, `update_window_root`, `update_highest_commit_cert`. After a crash, on-disk tree contains blocks the in-memory tree no longer references, and the on-disk root is still old — the warning comment "as long as the commit succeeds" is *true* only if `executor.commit_ledger` (already executed by this point) was actually durable.

### F4 — Buffer manager dispatches execution before pushing the buffer item. (Async-handoff Race)
- File: `buffer_manager.rs:412-431`.
- `execution_schedule_phase_tx.send(request).await` (lines 415-418) precedes `self.buffer.push_back(item)` (line 431). Because the schedule phase response goes to the same `select!` arm as `process_ordered_blocks`, in normal operation push always wins the race. But there's no static enforcement — a future refactor that makes any of the dependent steps complete synchronously (or reorders the arms) could cause `process_execution_response` to silently drop the result (lines 631-633).

### F5 — Pre-aggregated commit proof + local execution mismatch panics the validator. (Crash Window)
- File: `buffer_item.rs:149` and `buffer_item.rs:262`.
- `assert_eq!(commit_proof.commit_info().clone(), commit_info)`. If a Byzantine peer pushes a commit decision that was *legitimately* aggregated against a different state, and our local execution disagrees, the BufferManager panics. Safety-correct, liveness-bad. (See also `block_tree.rs:442` on root-update assertions.)

### F6 — Sync-manager inserts peer-supplied QCs without re-verifying their aggregated signatures. (Byzantine Acceptance)
- Files: `sync_manager.rs:359-364` (`fetch_quorum_cert`), `sync_manager.rs:521-527` (`fast_forward_sync` builds the QC chain from peer-returned blocks).
- `insert_single_quorum_cert` (`block_store.rs:531-568`) only checks block-info equality. Final defence is `LedgerRecoveryData::find_root` against the trusted commit cert anchor; intermediate QCs along the way may transiently be unverified forgeries, and the comment at `sync_manager.rs:530-531` is the author's own "need to think harder, it's pretty subtle". Combined with **F1**, an unverified QC could be propagated to in-memory state.

### F7 — `insert_block_inner` builds the per-block pipeline (which can spawn `executor.pre_commit_block`) before persisting the block. (Pre-commit/Commit ordering)
- File: `block_store.rs:475-528`.
- `pipeline_builder.build_for_consensus(...)` (line 502-509) spawns the per-block future graph, including pre_commit (which writes to ledger DB). Only after that does `self.storage.save_tree(vec![block], vec![])` at line 524-526 persist the block to consensus storage. If pre_commit completes but the consensus-storage write is lost (crash or save_tree error which is converted to error and bubbled up at line 526), we have ledger state for a block whose existence is no longer in consensus storage — recoverable via state-sync but a dual-source-of-truth hazard.

### F8 — `pre_commit_status` is in-memory only, recomputed from `root_block_round` at startup. (Crash Window)
- File: `pipeline_builder.rs:83-117` plus `block_store.rs:251-253`.
- `PreCommitStatus.round` is initialised from `root_block_round` after recovery (`block_store.rs:251-253`). If the executor pre-committed round R (which is ahead of the ordered/commit root) and crashed before commit, the recovered `pre_commit_status.round` is the commit root, **not** R. Pre-commit can re-fire for R, attempting to overwrite already-pre-committed state. Whether this is idempotent depends on `executor.pre_commit_block` semantics (out of scope for these files).

### F9 — Reset can drop ordered blocks that have already been delivered. (Reset/Reconfig)
- File: `buffer_manager.rs:570-589` (in `reset`) and `buffer_manager.rs:564-594` overall.
- `reset` aborts per-block pipelines and drains `block_rx` (lines 583-589). But ordered blocks delivered to consensus before the reset are **not** persisted by the buffer manager — they live in `block_rx`. After reset, those blocks are gone forever from the BufferManager's view. They can be re-derived via state-sync, but during the gap nothing in the BufferManager remembers them.

### F10 — Pruning only persists when the in-memory tree has a write lock; advance happens regardless. (Persistence/Atomicity)
- File: `block_tree.rs:591-600`.
- Storage IO (sync `prune_tree`) is invoked under the write lock, which serialises every reader. Failures are swallowed, then the tree is mutated. Combined: long IO stall blocks the entire BlockReader path; on stall failure the in-memory tree silently diverges from disk.

### Bonus — `block_tree.rs:381` author-flagged consistency question
- "We are updating `highest_ordered_cert` but not `highest_ordered_root`. Is that fine?" — Yes, currently no caller of `insert_quorum_cert` updates the ordered_root (that's done separately in `send_for_execution`), but the comment confirms there is **no proof** of consistency between these fields and they live as independent slots updated by different code paths.

---

## Appendix — Channels are *unbounded* everywhere

`buffer_manager.rs:96-100` defines:

```rust
pub fn create_channel<T>() -> (Sender<T>, Receiver<T>) {
    unbounded::<T>()
}
```

This is used for every inter-phase channel listed in Section 2. There is no back-pressure between
phases. The only back-pressure mechanism is `need_back_pressure()` on the *intake* channel
(`buffer_manager.rs:924-928`), which only kicks in when the gap between ordered round and
committed round exceeds `MAX_BACKLOG = 20`. If execution stalls but commits trickle in (e.g. via
remote commit decisions), the intake stays open while the execution-bound channels grow without
bound.
