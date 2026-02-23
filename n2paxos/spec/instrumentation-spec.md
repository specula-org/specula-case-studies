# N2Paxos Instrumentation Spec (Code-Level)

## 1. Trace Event Schema

Common envelope:
- `ts`: RFC3339 timestamp
- `event.name`: action/event name
- `event.module`: `"n2paxos_replica"` or `"client"`
- `event.nid`: replica id string for replica events
- `event.cmd.client`, `event.cmd.seq`: command id
- `event.slot`: slot index for per-slot replica events
- `event.state.ballot`, `event.state.cballot`, `event.state.status`, `event.state.phase`

State-to-spec mapping:
- `state.ballot` -> `ballot[nid]`
- `state.cballot` -> `cballot[nid]`
- `state.status` -> `status[nid]`
- `state.phase` -> `PhaseAt(nid, slot)`

Message/context mapping:
- `from` -> sender for `Handle2A` / `Handle2B`
- `to` -> informational only (no direct state update)
- `votes` -> informational count for `Succeed`

## 2. Action-to-Code Mapping

1. Spec action: `HandleClientRequestBatch`
- Code location: `artifact/n2paxos/client/client.go:182`, `artifact/n2paxos/n2paxos/n2paxos.go:165`
- Trigger point: after client request is formed/sent (`ClientRequest`) and before replica delivery lookup uses `r.proposes`
- Trace event: `ClientRequest`
- Fields: `target`, `cmd.client`, `cmd.seq`
- Notes: models follower-side proposal visibility through `r.proposes`.

2. Spec action: `HandlePropose`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:196`
- Trigger point: immediately after `desc.propose = msg`
- Trace event: `Propose`
- Fields: `nid`, `slot`, `cmd.client`, `cmd.seq`, command payload fields (optional)
- Notes: this is leader-local proposal ingestion.

3. Spec action: `SendBeginBallot`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:210`, `artifact/n2paxos/n2paxos/batcher.go:47`
- Trigger point: before/at enqueue to batcher for `M2A`
- Trace event: `SendBeginBallot`
- Fields: `nid`, `slot`, `cmd.client`, `cmd.seq`, `to`
- Notes: batching may coalesce multiple sends.

4. Spec action: `Handle2A`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:226`
- Trigger point: right after `desc.cmd`, `desc.cmdId`, `desc.cmdSlot` assignments
- Trace event: `ReceiveBeginBallot`
- Fields: `nid`, `from`, `slot`, `cmd.client`, `cmd.seq`, `state.ballot`
- Notes: corresponds to `M2A` reception and local slot/cmd binding.

5. Spec action: `SendVoted`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:250`, `artifact/n2paxos/n2paxos/batcher.go:74`
- Trigger point: before/at enqueue of `M2B`
- Trace event: `SendVoted`
- Fields: `nid`, `slot`, `cmd.client`, `cmd.seq`, `to`, `state.ballot`
- Notes: one trace event per logical vote send.

6. Spec action: `Handle2B`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:258`
- Trigger point: right before `desc.twoBs.Add(...)` or immediately after receive
- Trace event: `ReceiveVoted`
- Fields: `nid`, `from`, `slot`, `state.ballot`, `cmd.client`, `cmd.seq`
- Notes: `cmd` may be default (`seq=-42`) if vote races ahead of payload.

7. Spec action: `Succeed`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:271`
- Trigger point: right after `desc.phase = COMMIT`
- Trace event: `Succeed`
- Fields: `nid`, `slot`, `cmd.client`, `cmd.seq`, `votes`, `state.phase`
- Notes: commit transition event.

8. Spec action: `SendSuccess`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:275`
- Trigger point: just before `r.deliver(desc, desc.cmdSlot)` call
- Trace event: `SendSuccess`
- Fields: `nid`, `slot`, `cmd.client`, `cmd.seq`, `to`, `state.phase`
- Notes: this action includes immediate internal deliver attempt in spec.

9. Spec action: `DeliverChainStep`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:308`, `artifact/n2paxos/n2paxos/n2paxos.go:153`
- Trigger point: no dedicated trace event in current instrumentation (silent internal path)
- Trace event: none (modeled as internal)
- Fields: N/A
- Notes: models `deliverChan <- slot+1` and later consumption.

10. Spec action: `ReceiveSuccess`
- Code location: `artifact/n2paxos/n2paxos/n2paxos.go:321`
- Trigger point: after client reply path in deliver (`Proxy && Dreply`)
- Trace event: `ReceiveSuccess`
- Fields: `nid`, `slot`, `client`, `cmd.client`, `cmd.seq`
- Notes: indicates successful client-visible completion at replica.

## 3. Special Considerations

- `M1A/M1B/MPaxosSync` and `RECOVERING` are registered but not consumed in the N2Paxos run loop (`artifact/n2paxos/n2paxos/defs.go:130`, `artifact/n2paxos/n2paxos/n2paxos.go:156`); instrumentation/spec should not assume active recovery transitions.
- Delivery does not have its own event; it is folded into `SendSuccess` semantics in this spec to keep trace replay faithful to current instrumentation granularity.
- `ReceiveVoted` may carry placeholder command id (`seq=-42`) due descriptor race ordering; keep this value in traces instead of filtering it out.
