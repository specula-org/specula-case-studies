# Bug: Replica Can Commit Without Local Proposal Visibility (Family 2)

## Summary

A follower can reach `COMMIT` for a slot after learning via `2A/2B` while lacking local proposal visibility required by delivery.

This creates a commit-without-deliver-payload state that can stall execution progress on that replica.

## Impact

- Liveness/availability risk on affected replicas.
- Under single-target client dissemination, committed entries may not become executable locally.

## Affected Code Paths

- Delivery requires local proposal pointer:
  - `artifact/n2paxos/n2paxos/n2paxos.go:301`
- Follower proposal visibility depends on `ProposeChan` path:
  - `artifact/n2paxos/n2paxos/n2paxos.go:165`
  - `artifact/n2paxos/n2paxos/n2paxos.go:167`
- Follower can still learn/commit through `2A/2B`:
  - `artifact/n2paxos/n2paxos/n2paxos.go:226`
  - `artifact/n2paxos/n2paxos/n2paxos.go:258`
  - `artifact/n2paxos/n2paxos/n2paxos.go:271`

## Reproduction (Model Checking)

### Model setup

Focused adversarial checker:

- `spec/MC_Family2.tla`
- `spec/MC_Family2.cfg`

Checked invariant:

- `CommittedHasDeliverPayloadAtFollower`

Meaning:

- If follower slot is `COMMIT` and command is known, then follower should have deliver payload (`HasDeliverPayload`).

### Run

```bash
cd spec
java -cp /home/kewbish/Downloads/dev/specula/lib/tla2tools.jar:/home/kewbish/Downloads/dev/specula/lib/CommunityModules-deps.jar tlc2.TLC -depth 12 -config MC_Family2.cfg MC_Family2.tla
```

### Observed result

- TLC reports `Invariant CommittedHasDeliverPayloadAtFollower is violated`.
- Counterexample artifact:
  - `spec/MC_Family2_TTrace_1771820139.tla`

## Minimal Counterexample Sketch

1. Client visibility is leader-only (single-target dissemination in model).
2. Follower learns command for slot via `Handle2A` (without client-seen/proposal pointer).
3. Follower collects quorum votes (`Handle2B`) and executes `Succeed` -> `COMMIT`.
4. Follower remains without deliver payload for that committed slot.

## Expected vs Actual

- Expected (robust): committed slot at a replica has sufficient local payload visibility to deliver.
- Actual: committed follower slot can lack deliver payload, blocking local delivery path.

## Scope / Assumptions

- This is a model-checked adversarial scenario consistent with Family 2 assumptions.
- In deployments where clients always broadcast proposals to all replicas, this condition may be masked.
- In single-target or partial-visibility environments, risk is exposed.

## Suggested Actions

1. Ensure proposal metadata/payload is propagated alongside learned command path.
2. Decouple delivery eligibility from local client proposal pointer dependency where safe.
3. Add tests for single-target client mode showing follower commit + delivery behavior.

## Notes

This issue corresponds to Family 2 in `docs/modelling_brief.md`.
