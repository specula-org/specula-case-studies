# Autobahn Deep Analysis: Synchronization, Ordering, and Waiter Logic

Source: `/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact/primary/src/`

Methodology: read all files in `Files to read carefully`, plus `core.rs`,
`messages.rs`, `primary.rs`, and `node/src/main.rs` to trace channel wiring
and loopback flows. Findings are tagged with severity, attack model, and
how they can be verified (model-checkable / test / code-review).

------------------------------------------------------------------------

## Finding 1 — GarbageCollector is dead code: `consensus_round` never advances

**CLAIM**: `GarbageCollector::run` is wired to a channel (`rx_consensus`)
that nobody ever writes to. Therefore `consensus_round` (`Arc<AtomicU64>`)
is fixed at `0` for the whole lifetime of the node, every GC code path in
`HeaderWaiter::run` and `Core::run` that is gated on
`round > self.gc_depth` is permanently disabled, and all "GC" maps grow
without bound.

**EVIDENCE**:

`node/src/main.rs:117-156` creates `(tx_feedback, rx_feedback)` and passes
`rx_feedback` to `Primary::spawn` as `rx_consensus`, but the only writer
to `tx_feedback` is the `Consensus::spawn(...)` call which is fully
commented out:
```
118:            let (tx_new_certificates, rx_new_certificates) = channel(CHANNEL_CAPACITY);
119:            let (tx_feedback, rx_feedback) = channel(CHANNEL_CAPACITY);
...
133:                /* rx_consensus */ rx_feedback,
...
140:            /*Consensus::spawn(
...
148:                /* tx_mempool */ tx_feedback,
...
155:            );*/
```

`primary/src/primary.rs:214-221`:
```
GarbageCollector::spawn(
    &name,
    &committee,
    store.clone(),
    consensus_round.clone(),
    rx_consensus,                // <- never receives anything
    tx_certificates_loopback.clone(),
);
```

`primary/src/garbage_collector.rs:86` is the *only* writer to
`consensus_round.store(round, Ordering::Relaxed)`. Verified via grep:
```
$ grep -rn 'consensus_round\.store' primary/src/
primary/src/garbage_collector.rs:86:                self.consensus_round.store(round, Ordering::Relaxed);
```

Consumers all read but cannot observe a non-zero value:
* `primary/src/header_waiter.rs:427-440`:
  ```
  let round = self.consensus_round.load(Ordering::Relaxed);
  if round > self.gc_depth {              // never true
      let mut gc_round = round - self.gc_depth;
      ...
      self.pending.retain(|_, (r, _)| r > &mut gc_round);
      self.batch_requests.retain(|_, r| r > &mut gc_round);
      self.parent_requests.retain(|_, (r, _)| r > &mut gc_round);
      self.header_requests.retain(|_, (r, _)| r > &mut gc_round);
  }
  ```
* `primary/src/core.rs:2336-2349`: same shape; `self.last_voted`,
  `self.cancel_handlers`, and `self.gc_round` are never cleaned.

The `tx_loopback` channel used by GC also points to
`_rx_certificates_loopback` (`primary.rs:100`) which is `_`-prefixed
(unused).

**SEVERITY**: Critical (liveness/availability) — silent unbounded memory
growth in every long-running primary. `last_voted: HashMap<Height, HashSet<PublicKey>>`,
`cancel_handlers: HashMap<Height, Vec<...>>`,
`HeaderWaiter::{pending, batch_requests, parent_requests, header_requests}`
all leak. Also `sanitize_header` keeps accepting headers with
`gc_round = 0`, so an attacker can flood arbitrary heights.

**IMPACT**:
* Memory exhaustion / OOM kill of every primary.
* Cancel handlers retained forever means TCP sockets cannot be torn down.
* Quorum cannot use the documented "header too old" backpressure.

**CLASS**: benign (a misconfiguration that turns into a byzantine
amplification primitive) — model-check not required; **code-review-only**
(this is a wiring bug, not a protocol invariant). Easily test-verifiable
by running for several minutes and observing RSS.

------------------------------------------------------------------------

## Finding 2 — Committer panics on a byzantine `Commit` referencing a genesis digest at height > 0

**CLAIM**: A byzantine leader who can drive a `Confirm`->`Commit` (only
needs honest votes for `Confirm`, no collusion) can include a
`Proposal { header_digest: <genesis digest of any pk>, height: 5 }` in
the `Commit`'s `proposals` map. `Synchronizer::get_proposals` happily
treats it as ready (it short-circuits on the genesis digest *without*
checking the proposal's height). The committer then enters
`get_all_headers_for_proposal`, which calls `get_header(genesis_digest)`,
finds no store entry (genesis is *never* written to the store), and
panics on `.expect("already synced should have header").unwrap()`.

**EVIDENCE**:

`primary/src/synchronizer.rs:146-161` (Commit branch of `get_proposals`):
```
ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
    for (pk, proposal) in proposals {
        if proposal.height == 0 {                                // (1)
            continue;
        }
        if proposal.header_digest == self.genesis_headers.get(&pk).unwrap().digest() {
            proposals_vector.push(self.genesis_headers.get(&pk).unwrap().clone()); // (2)
            continue;
        }
        match self.store.read(proposal.header_digest.to_vec()).await? {
            Some(header) => proposals_vector.push(bincode::deserialize(&header)?),
            None => missing.push(proposal.clone()),
        }
    }
}
```
Filter (1) only checks `proposal.height == 0`, not the digest. Branch
(2) accepts `(genesis_digest, height > 0)` as ready.

`primary/src/committer.rs:130-167`:
```
ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
    for (pk, proposal) in proposals {
        let stop_height = *state.last_executed_heights.get(pk).unwrap();
        if proposal.height <= stop_height { continue; }
        let headers = self.synchronizer.get_all_headers_for_proposal(
            proposal.clone(), stop_height,
        ).await.expect("should have ancestors by now");
        ...
```

`primary/src/synchronizer.rs:248-271`:
```
pub async fn get_all_headers_for_proposal(
    &mut self, proposal: Proposal, stop_height: Height,
) -> DagResult<Vec<Header>> {
    ...
    let mut header: Header = self.get_header(proposal.header_digest)
        .await.expect("already synced should have header").unwrap();  // panics
    let mut current_height = proposal.height;
    while current_height > stop_height {
        ancestors.push(header.clone());
        header = self.get_parent_header(&header).await?
            .expect("should have parent by now");                     // panics too
        current_height = header.height();
    }
```

Genesis headers are never persisted — search confirms:
```
$ grep -rn 'genesis.*store\.write\|store\.write.*genesis\|write_genesis' primary/src/
(no matches)
```

So `get_header(genesis_digest)` returns `Ok(None)` and `.unwrap()` panics
the committer task; same for `get_parent_header` of any genesis-rooted
proposal whose claimed height is greater than the lane's last executed
height.

How a single byzantine leader gets honest replicas to sign a `Confirm`
with such a proposal: honest replicas validate via
`synchronizer.get_proposals` for the Confirm message
(`synchronizer.rs:131-145`), which also lacks a height check on the
genesis digest, so they vote yes. The leader collects 2f+1 votes and
forms a valid `Confirm` QC, then converts to `Commit` and broadcasts it.

**SEVERITY**: Critical (byzantine liveness kill / fault amplification).
A single byzantine leader can panic the committer of every honest
replica simultaneously. Combined with Finding 1, the panic restarts the
task or aborts the process depending on tokio's panic handler.

**IMPACT**: Permanent halt of the committer on all honest replicas in
one shot.

**CLASS**: **byzantine**; model-checkable (the height-vs-digest
mismatch is an obvious invariant violation a TLA+ refinement would
catch). Also test-verifiable by feeding a hand-crafted `Commit`.

------------------------------------------------------------------------

## Finding 3 — `get_all_headers_for_proposal` traverses the parent chain without ever syncing it

**CLAIM**: The committer assumes that whenever
`synchronizer::get_proposals` returns non-empty for a Commit, all
ancestors of every proposal up to the lane's `stop_height` are present
in the store. The synchronizer only checks the proposal *tip*; it never
walks the chain. So a Commit whose proposals reference a height-N
header that *is* in the store, but whose height-(N-1) parent is not,
will reach the committer and then either (a) panic on
`get_parent_header(...).expect("should have parent by now")`, or (b)
silently issue a new `SyncParent` and then panic anyway because of the
`expect`.

**EVIDENCE**:

Synchronizer only reads the tip:
```
primary/src/synchronizer.rs:156:    match self.store.read(proposal.header_digest.to_vec()).await? {
primary/src/synchronizer.rs:157:        Some(header) => proposals_vector.push(bincode::deserialize(&header)?),
```

Committer trusts it (committer.rs:141-143):
```
let headers = self.synchronizer.get_all_headers_for_proposal(proposal.clone(), stop_height)
    .await
    .expect("should have ancestors by now");
```

`get_parent_header` has a side effect — it queues a `SyncParent` — and
returns `Ok(None)` when the parent is absent (synchronizer.rs:282-288);
but the immediate caller (`get_all_headers_for_proposal`) does
`.expect("should have parent by now")` (line 266) and panics:
```
header = self.get_parent_header(&header).await?.expect("should have parent by now");
```

How this happens in normal operation:
* Headers do not necessarily arrive in FIFO order over a lossy
  network. The lane's leader can also rotate: after a view-change,
  a new leader's tip may reference a parent that this replica missed
  because the previous leader's broadcast was partial.
* A `Commit` may carry a proposal `(pk, height=5)` for a lane where
  this replica only ever stored heights 0,1,3,4 (height 2 lost to
  packet loss). `SyncProposals` syncs the *tip* (5), not 2. When the
  committer walks from 5 down it eventually calls `get_parent_header`
  on the height-3 header, which references height-2. Store miss
  triggers a `SyncParent` *and* panics in the same await.

**SEVERITY**: High (liveness; panics committer); can be triggered by
adversarial scheduling under partial synchrony or by byzantine actors
deliberately withholding intermediate headers.

**IMPACT**: Committer task dies → no further output even if other
slots are decided. Process exits if panics are not isolated.

**CLASS**: model-checkable (the *invariant* "synchronizer.get_proposals
returning non-empty implies the entire parent chain is stored" is what
the code is silently assuming); also test-verifiable.

------------------------------------------------------------------------

## Finding 4 — Multiple `unwrap()`s on unknown public keys in committer/synchronizer (byzantine node-kill)

**CLAIM**: Both the synchronizer and the committer call `unwrap()` on
maps keyed by `PublicKey` taken straight out of a network-supplied
`HashMap<PublicKey, Proposal>`. A byzantine leader can include a
public key that is *not in the committee* and panic any honest replica
that processes the message.

**EVIDENCE**:

* `primary/src/synchronizer.rs:111` (Prepare), `:134` (Confirm), `:151`
  (Commit):
  ```
  if proposal.header_digest == self.genesis_headers.get(&pk).unwrap().digest() {
  ```
  `self.genesis_headers: HashMap<PublicKey, Header>` is built once from
  `Committee::authorities` (see `Header::genesis_headers`). Any
  `pk` not in the committee makes `.get(&pk)` return `None` and
  `.unwrap()` panics. Note also `.get(&pk)` is followed immediately by
  another `.get(&pk).unwrap()` for the push, so even after the digest
  check returns true the second `unwrap` can race a hypothetical mutate.
* `primary/src/synchronizer.rs:274-275` (`get_parent_header`):
  ```
  if header.parent_cert.header_digest == self.genesis_headers.get(&header.author).unwrap().digest() {
      return Ok(Some(self.genesis_headers.get(&header.author).unwrap().clone()));
  ```
  A received header whose `author` is not in the committee (passed only
  signature verification at `sanitize_header`, but if the attacker can
  bypass that — e.g., during the loopback path that doesn't re-sanitize)
  panics the core task.
* `primary/src/committer.rs:134`:
  ```
  let stop_height = *state.last_executed_heights.get(pk).unwrap();
  ```
  `state.last_executed_heights` is populated only from
  `Certificate::genesis` (committee members). A `Commit` carrying a
  proposal whose `pk` is not a committee member panics the committer.

The chain of trust before these panics:
1. The header is sanitized (`sanitize_header` only verifies the
   header's *author* signature, not every `pk` mentioned in its
   `consensus_messages`).
2. `verify_commit`/`verify_confirm` checks the QC ID and committee
   signatures, but **does not iterate `proposals` to verify that every
   `pk` is in the committee**.

**SEVERITY**: High (byzantine node-kill); cheap to mount.

**IMPACT**: Committer or core task panics on every honest replica when
a single byzantine leader emits a malformed message that nevertheless
has a valid QC structure.

**CLASS**: byzantine; code-review-only (also test-verifiable by
sending hand-built messages).

------------------------------------------------------------------------

## Finding 5 — `proposal_digest` is computed over a `HashMap` and is therefore non-deterministic; HeaderWaiter dedup fails silently

**CLAIM**: `proposal_digest` iterates `proposals: HashMap<PublicKey, Proposal>`
to build a SHA-512. Rust's `std::collections::HashMap` uses a
random-seeded `RandomState`; iteration order depends on the seed and
is recomputed per `HashMap` instance (every clone may get a different
seed because the default `Hasher` initialiser is random). The
HeaderWaiter uses this digest as the *dedup key* for `pending`. So:
* the same logical consensus message can produce different `id`s on
  different replicas (or on the same replica after a `clone`), defeating
  the cross-network dedup invariant that the code seems to assume;
* the local cleanup at line 360
  (`let id = proposal_digest(&deliver.0); self.pending.remove(&id);`)
  works only because `deliver.0` is the same `HashMap` instance whose
  iteration order has been frozen since insertion — but if the
  `consensus_message` was *cloned* between insertion and removal the
  remove can miss.

**EVIDENCE**:

`primary/src/messages.rs:210-228`:
```
pub fn proposal_digest(consensus_message: &ConsensusMessage) -> Digest {
    let mut hasher = Sha512::new();
    match consensus_message {
        ConsensusMessage::Prepare { ..., proposals } => {
            for (_, proposal) in proposals {                // HashMap iteration!
                hasher.update(proposal.header_digest.0);
            }
        },
        ...
```

`primary/src/header_waiter.rs:288-305`:
```
let id = proposal_digest(&consensus_message);
if self.pending.contains_key(&id) {           // dedup by non-deterministic key
    continue;
}
...
self.pending.insert(id, (height, tx_cancel));
let fut = Self::proposal_waiter(wait_for, (consensus_message, header), rx_cancel);
proposal_waiting.push(fut);
```

`primary/src/header_waiter.rs:359-360` (cleanup):
```
let id = proposal_digest(&deliver.0);
let _ = self.pending.remove(&id);
```

Inside `Synchronizer::get_proposals` (called every time a header
carrying the same consensus message is processed), the message is
re-cloned and the HashMap iteration order may change across calls.
Result:
* `pending.contains_key(&id)` may falsely return `false` on a
  retransmission, causing duplicate `proposal_waiting` futures and
  duplicate `SyncProposals` traffic.
* `pending.remove(&id)` at line 360 will then leave stale entries in
  `pending` forever (and `pending` is the only thing GC would have
  trimmed — which it never does, see Finding 1).

**SEVERITY**: Medium (correctness/leak) — combines with Finding 1 to
worsen memory growth. Standalone the consequence is wasted network
bandwidth and duplicated processing.

**IMPACT**: Wasted sync traffic, slow accumulation of dead pending
entries, and (for tests that rely on `proposal_digest`-based
identifiers) cross-node hash mismatches.

**CLASS**: benign-by-default but observable as nondeterminism. Code
review only (the right fix is to switch to a `BTreeMap` or sort
explicitly).

------------------------------------------------------------------------

## Finding 6 — Loopback after sync silently drops a Prepare under `use_ride_share = true` when it originated from an external `ConsensusMessage`

**CLAIM**: When a `ConsensusMessage` (e.g., a forwarded
`Prepare`) is processed via
`Core::process_consensus_message`/`process_consensus_request`, the code
synthesises a *dummy* `Header::default()` with only the author field
set:
```
primary/src/core.rs:1399:    let mut header = Header::default();
primary/src/core.rs:1400:    header.author = author;
```
That dummy header is what gets queued into the `HeaderWaiter` via the
synchronizer's `SyncProposals(missing, consensus_message, header)`
path. When the sync completes, the `HeaderWaiter` loops it back to the
core as `(consensus_message, dummy_header)`. The core dispatches in
`process_loopback`:

```
primary/src/core.rs:1720-1731
ConsensusMessage::Prepare { slot, view, ... } => {
    if self.use_ride_share {
        self.process_header(header, false).await?;        // dummy header!
    } else {
        ...
        self.process_consensus_message(consensus_message, header.author).await?
    }
},
```

`process_header(dummy_header)` immediately fails the very first
`ensure!`:
```
primary/src/core.rs:335-338
ensure!(
    header.parent_cert.height() + 1 == header.height(),
    DagError::MalformedHeader(header.id.clone())
);
```
because `Header::default()` has both `height = 0` and `parent_cert.height = 0`,
so `0 + 1 == 0` is false. The error is logged as `MalformedHeader`,
the result drops, and **the Prepare is never re-processed and never
voted on**.

**EVIDENCE**: see snippets above. The "dummy header" pattern is
clearly load-bearing in `process_consensus_message`; the `use_ride_share`
branch in `process_loopback` blindly trusts that the header is real.

**SEVERITY**: High (liveness) — under `use_ride_share = true`, a Prepare
that triggers an out-of-order sync (e.g., proposals not yet locally
stored) is silently dropped after sync completes. The replica never
votes on it, and the view may not advance.

**IMPACT**: View stalls / repeated view-change timer firings under
loss/asynchrony. Possibly recoverable on subsequent broadcasts but the
local replica is permanently stuck on this exact instance.

**CLASS**: code-review (loopback path must distinguish a real header
from the dummy; minimal fix is to recognise `header.id ==
Header::default().id` and take the `else` branch). Also
test-verifiable with a small concurrent scenario.

------------------------------------------------------------------------

## Finding 7 — `WaiterMessage::SyncHeader` has no waiter, no completion, and no cleanup

**CLAIM**: The `SyncHeader` handler in `HeaderWaiter::run`
(`primary/src/header_waiter.rs:213-238`) records an entry in
`header_requests` keyed by digest with *height = 0* (line 224) and
broadcasts a network request — but it does **not** spawn a waiter,
does **not** participate in `proposal_waiting`/`waiting`, and **never
clears its entry** by ordinary success. The only cleanup path is the
periodic block at lines 427-440, which (a) is dead because of
Finding 1, and (b) even if it ran would discard *all*
`header_requests` because `0 > gc_round` is false the moment GC runs
once.

**EVIDENCE**:
```
primary/src/header_waiter.rs:213-238
WaiterMessage::SyncHeader(missing) => {
    let now = ...;
    let mut requires_sync = Vec::new();
    self.header_requests.entry(missing.clone()).or_insert_with(|| {
        requires_sync.push(missing);
        (0, now)
    });
    if !requires_sync.is_empty() {
        let addresses = ...;
        let message = PrimaryMessage::HeadersRequest(requires_sync, self.name);
        let bytes = bincode::serialize(&message).expect(...);
        self.network.lucky_broadcast(...).await;
    }
}
```
The retry timer in lines 408-419 also only inspects
`self.parent_requests`, not `self.header_requests`:
```
for (digest, (_, timestamp)) in &self.parent_requests {
    if timestamp + (self.sync_retry_delay as u128) < now {
        ...
```

**SEVERITY**: Medium (correctness/leak): each call to
`Synchronizer::fetch_header` (used by `Core::rx_request_header_sync`)
leaks one `header_requests` entry forever. There is also no automatic
retry: the broadcast is fire-and-forget; if all targets miss the
request, the sync silently fails.

**IMPACT**: Slow memory growth, plus a liveness problem under packet
loss — `fetch_header` requests are not retried.

**CLASS**: code-review.

------------------------------------------------------------------------

## Finding 8 — Committer overwrites `state.log[slot]` on re-arrival; no equivocation check

**CLAIM**: `Committer::process_commit_message` (`committer.rs:117-175`)
inserts the incoming `Commit` unconditionally into `state.log` once it
has cleared the `slot <= state.last_executed_slot` gate. If a *second*
`Commit` for the same slot arrives before that slot is executed (e.g.,
the local node was reprocessing a buffered commit while a new commit
arrives via the loopback path), the second insertion silently replaces
the first. The committer does **no** content equality check across the
two commits.

**EVIDENCE**:
```
primary/src/committer.rs:120-128
if slot <= state.last_executed_slot {
    debug!("Already committed slot {}", slot);
    return;
}
state.log.insert(slot, commit_message);             // overwrite, no check
while state.log.contains_key(&(state.last_executed_slot + 1)) {
    let current_commit_message = state.log.get(&(state.last_executed_slot + 1)).unwrap();
    ...
```

If the two `Commit`s differ only in `view` (legitimate, e.g., one
honest and one fast-path), the committer will use whichever arrives
last — which is non-deterministic. If the two `Commit`s differ in
`proposals` (a *real* safety violation produced by a separate bug),
the committer will silently choose one and never alert anyone. This
removes a defence-in-depth check that the rest of the system relies
on.

**SEVERITY**: Medium (safety/observability) — the committer doesn't
introduce a new safety violation, but it would hide one if upstream
voting permitted it.

**IMPACT**: Local safety violations cannot be detected; output to the
application can change non-deterministically across honest replicas
under bug conditions.

**CLASS**: code-review; also model-checkable (the invariant
"`state.log[slot]` is write-once" should be enforced in the model
refinement).

------------------------------------------------------------------------

## Finding 9 — `panic!("ids don't match")` inside `verify_commit` is reachable from network input

**CLAIM**: `messages.rs:158-161` panics in the slow-path branch when
the confirm-id reconstruction doesn't match the supplied QC id. This
is *byzantine-reachable* because:
* `verify_commit` is called from `Core::is_valid(consensus_message)`
  (via `verify_commit(...)` in `messages.rs:121`);
* `is_valid` is invoked while processing arbitrary network messages in
  `process_consensus_messages` (`core.rs:1299`) and
  `process_consensus_request` (`core.rs:1382`).

The fast-path branch (line 134-143) returns `false` cleanly when the
QC verification fails, but the slow-path uses `panic!` first before
the `return false;` (which is consequently dead code).

**EVIDENCE**:
```
primary/src/messages.rs:121-168 (verify_commit)
...
if qc.votes.len() == committee.size() { ... }
else {
    ...
    if confirm_id != qc.id {
        panic!("ids don't match");
        return false;
    }
    qc.verify(committee).is_ok()
}
```

**SEVERITY**: High (byzantine node-kill); reachable by any sender that
delivers a `Commit` with mismatched ids.

**IMPACT**: Core task panics; node halts (modulo tokio's panic policy).

**CLASS**: byzantine; code-review-only.

------------------------------------------------------------------------

## Finding 10 — `PayloadReceiver` writes `Vec::default()` for any (digest, worker_id) pair; no header content binding

**CLAIM**: `PayloadReceiver` blindly writes empty bytes under
`[digest, worker_id]` keys (`payload_receiver.rs:25-31`). The
`Synchronizer::missing_payload` check then just reads the key and
treats existence as evidence the worker has the batch. There is no
binding between the digest in the *header* and the digest the *worker*
actually validated. This is intentional (the worker is trusted), but
combined with `WorkerReceiverHandler` it means the primary cannot
detect a worker that confirms digests it has not actually stored. Not
a sync-layer bug per se, but worth flagging because the comment in
`missing_payload` (`synchronizer.rs:62-71`) explicitly relies on the
worker storage check to *prevent* an attack.

**EVIDENCE**: as cited.

**SEVERITY**: Low (already assumed in the trust model).

**IMPACT**: A compromised local worker can lie about batch availability,
causing the primary to vote for malformed headers.

**CLASS**: code-review; benign within the documented trust model
(trusted worker). Listed for completeness.

------------------------------------------------------------------------

## Finding 11 — Header storage ordering vs is_consensus_ready can stall locally-created Prepares

**CLAIM**: `process_header` (`core.rs:321-481`) only stores the header
*after* `is_consensus_ready` succeeds (line 389 is after the early
return at line 381). For *received* headers this is fine because the
loopback will re-deliver the same header. But `is_consensus_ready`
internally calls `Synchronizer::get_proposals` which has the
delivered-header shortcut at `synchronizer.rs:116-119` only for
`Prepare`; for `Confirm` and `Commit` carried in the same header the
shortcut is missing. So a header `H` that carries both a `Prepare(H)`
and a `Confirm(H')` where `H' == H` will succeed for the Prepare but
issue a spurious `SyncProposals` for the Confirm (because `H` is not
yet in the store). The waiter then loops the consensus message back,
and `process_loopback` for Confirm is a no-op (see core.rs:1733-1736),
so the Confirm vote is never actually emitted.

**EVIDENCE**:

`primary/src/synchronizer.rs:107-129` (Prepare branch — has the
`delivered_header` shortcut):
```
if proposal.header_digest == delivered_header.digest() {
    proposals_vector.push(delivered_header.clone());
    continue;
}
```

`primary/src/synchronizer.rs:131-161` (Confirm and Commit branches —
no such shortcut).

`primary/src/core.rs:1733-1736` (loopback):
```
ConsensusMessage::Confirm { ... } => {
    // Don't need to do anything for the confirm case, since proposals will be
    // sent to the committer once a commit message is received
},
```

**SEVERITY**: Low/Medium (liveness; relies on a header carrying both a
Prepare and a Confirm referencing itself). The current code structure
makes this rare in practice but possible under leader rotation.

**IMPACT**: A Confirm vote may be skipped; quorum has to wait for
another node's Confirm.

**CLASS**: code-review; also model-checkable.

------------------------------------------------------------------------

## Finding 12 — `parent_requests` retry loop never removes entries; can hot-loop until they are externally cleaned

**CLAIM**: The retry block at `header_waiter.rs:408-419` iterates
`self.parent_requests` and, for every entry whose timestamp is older
than `sync_retry_delay`, pushes the digest into `retry` and broadcasts
a `HeadersRequest`. The entry's *timestamp is not updated* (it remains
the original `now` from the initial insertion); therefore on every
timer tick *every* entry that hasn't been cleared by a success
satisfies `timestamp + sync_retry_delay < now` and is re-broadcast.

**EVIDENCE**:
```
primary/src/header_waiter.rs:408-419
let mut retry = Vec::new();
for (digest, (_, timestamp)) in &self.parent_requests {
    if timestamp + (self.sync_retry_delay as u128) < now {
        debug!("Requesting retry sync for parent header {} (retry)", digest);
        retry.push(digest.clone());
    }
}
let addresses = ...;
let message = PrimaryMessage::HeadersRequest(retry, self.name);
let bytes = bincode::serialize(&message).expect(...);
self.network.lucky_broadcast(addresses, Bytes::from(bytes), self.sync_retry_nodes).await;
```
No `self.parent_requests.insert(digest, (h, now))` or similar update
follows. The timer fires every `TIMER_RESOLUTION = 1_000` ms.

**SEVERITY**: Medium (network amplification / DoS) — the volume of
sync traffic grows linearly with the number of un-resolved parents
and is broadcast every second; combined with Finding 1 (no GC) and
Finding 5 (over-insertion via duplicated `SyncProposals`), this can
saturate primary-to-primary bandwidth.

**IMPACT**: Hot network loop after even a short loss window.

**CLASS**: code-review; test-verifiable by simulating packet loss.

------------------------------------------------------------------------

## Finding 13 — `consensus_message.clone()` on a `HashMap` creates a fresh `RandomState`, breaking content equality assumptions

**CLAIM**: `ConsensusMessage` contains `proposals: HashMap<PublicKey, Proposal>`
(`messages.rs:80`). `HashMap::clone` produces a new map with the *same
entries* but a *different* `RandomState` (RandomState is randomised on
default construction; `clone()` uses `Default::default()` for the
hasher). Two clones, even of the same source, may differ in iteration
order. Consequences:
* `proposal_digest(&cm.clone()) != proposal_digest(&cm)` is permitted
  (see Finding 5).
* `Header::digest()` over a header that contains
  `consensus_messages: HashMap<...>` is similarly nondeterministic if
  the digest implementation iterates the HashMap (need to verify in
  `messages.rs`).

**EVIDENCE**: `messages.rs:80`:
```
pub proposals: HashMap<PublicKey, Proposal>,
```
RandomState behaviour is documented; verify via
`assert_ne!(HashMap::new().hasher().build_hasher().finish(), HashMap::new().hasher().build_hasher().finish())`
in a quick test.

**SEVERITY**: Medium (correctness foundation): any logic that assumes
"clone preserves digest" is fragile.

**IMPACT**: subtle inter-node hash mismatches; Finding 5 is a direct
consequence.

**CLASS**: code-review; the fix is to use `BTreeMap` (or to serialize
sorted before hashing).

------------------------------------------------------------------------

## Cross-cutting observations

* The codebase contains many `expect("…")` and `unwrap()` on
  network-derived values. Every one is a potential node-kill primitive.
  A full audit of `unwrap` in `core.rs`, `synchronizer.rs`,
  `committer.rs`, `messages.rs` is recommended (out of scope here).
* Several channels are wired `_`-prefixed (unused on the receiver side):
  `_rx_certificates_loopback` (`primary.rs:100`), `_rx_consensus` in
  tests (e.g. `tests/core_tests.rs:1526`), and the
  `_tx_consensus`/`_tx_committer` parameters in `Primary::spawn`. This
  is a strong signal that significant subsystems are still wired through
  but not active.
* Finding 1 (dead GC) is the root cause that magnifies Findings 5, 7,
  and 12 into outright resource exhaustion.

## Suggested next steps

1. **Reproduce Finding 2 with TLA+**: the existing tla_trace
   instrumentation (`primary/src/tla_trace.rs`) emits the necessary
   events; a refinement check should flag the
   `proposal.height > 0 with header_digest = genesis` case.
2. **Fuzz the message layer**: craft `ConsensusMessage::Commit`s with
   (a) unknown `pk`s, (b) `height > 0` + genesis digest, (c) deliberately
   mismatched `confirm_id`, (d) duplicated slots; observe panics.
3. **Wire `consensus_round`**: either remove the `GarbageCollector`
   plumbing entirely (and the dead retain blocks), or restore an actual
   consensus feedback channel to drive the round update.
4. **Switch `proposals: HashMap` → `BTreeMap` (or sort before hashing)**
   to make `proposal_digest` deterministic.
