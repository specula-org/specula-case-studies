# vsr-rs

Target: https://github.com/penberg/vsr-rs, Rust, Category A (distributed/message-passing).
References below use revision `3ac0104a567092139534c9022205d02281a2da41`.

## Focus

The requester is helping the maintainer investigate this implementation's correctness. Priorities are committed-data preservation, application execution, client-visible results, and service progress.
Primary scope: fixed-membership VSR in `lib.rs`. Secondary scope: the library integration in `examples/kvstore/main.rs`. Dynamic membership is not implemented (`README.md:74`).

## Relevant assumptions

The library requires the caller to persist the view before delivering outputs (`lib.rs:14`), use a fresh nonce for each recovery (`lib.rs:505`), and give clients distinct identities, a new identity after restart, and at most one outstanding request each (`lib.rs:29`, `lib.rs:274`). Whether the shipped example fulfills these obligations is a separate integration question.
The reference is [VSR Revisited, sections 2-4](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf): crash failures, authentic messages, and deterministic application state machines. Recovering replicas count toward the failure budget; progress requires suitable communication and timing conditions.

## Existing work

- The project already has DST and regression tests. Its accumulator records ordered operations, and the property checks include applied history and replies (`simulator/state_machine.rs:36`, `simulator/properties.rs:38`).
- The retained [Lean branch](https://github.com/penberg/vsr-rs/blob/de1a84376afe1102c197c2e0f4ade41eb4494458/lean/README.md) contains local proofs and implementation/model trace comparison. Global preservation and general liveness remain unfinished; this is a proof-status fact, not an implementation-defect claim.
- The README already cites the recovery correction in [Michael et al.](https://drkp.net/papers/recovery-tr17.pdf) and the state-transfer correction in [Vanlightly's analysis](https://jack-vanlightly.com/analyses/2022/12/28/paper-vr-revisited-state-transfer-part-3).
- [Issue #9](https://github.com/penberg/vsr-rs/issues/9) and [PR #10](https://github.com/penberg/vsr-rs/pull/10) cover known example connection-backoff, disconnect-cleanup, and client-identity-reuse concerns. The maintainer actively discusses example availability in [this comment](https://github.com/penberg/vsr-rs/pull/10#issuecomment-5549729674); the contributor's suggestion that identity concerns are out of scope is not a maintainer ruling.

## Questions of interest

1. Do normal replication, view changes, state transfer, and recovery preserve committed history and its execution order when their responsibilities are considered together? (`lib.rs:379`, `Replica::on_message`, `Replica::recover`)

2. Under the documented client discipline, do application execution and replies remain consistent with the committed request history? How does the guarantee distinguish duplicate logical execution from replay that reconstructs a recovering replica? (`lib.rs:274`, `StateMachine::apply`, `simulator/properties.rs:291`)

3. Once the communication and timing conditions for progress hold and a sufficient non-recovering quorum is available, do pending requests and replica recovery make progress? Which conditions distinguish that service guarantee from the existing DST convergence and Lean liveness statements? (`lib.rs:1217`, `simulator/lib.rs:723`)

4. Do the assumptions embodied in the existing workload, transport, persistence abstraction, and observation cadence match the behaviors permitted by the library's public contract? (`README.md:60`, `simulator/lib.rs:712`, `simulator/lib.rs:929`)

5. Does the shipped example fulfill the library's persistence, identity, timer, and transport obligations, beyond the mechanisms already discussed in issue #9? (`examples/kvstore/main.rs`, `lib.rs:14`, `lib.rs:29`, `lib.rs:505`)

## Additional semantic focus

- **Protocol milestones:** What obligation is established when a request is accepted, replicated, acknowledged by a quorum, applied, and replied to? Do normal-operation and recovery paths agree on those obligations, while allowing an uncommitted suffix to be replaced? (`lib.rs:167`, `lib.rs:1349`, `lib.rs:1362`)

- **Recovery semantics:** With only the view number persisted, which past protocol promises must still hold after recovery, alongside reconstructed log and application contents? How do the guarantees differ between resuming a replica with volatile state retained and rebooting through recovery? (`lib.rs:14`, `lib.rs:505`, `simulator/lib.rs:694`)

- **Historical and client semantics:** Is correctness preserved against the full logical request history across views and replica incarnations, as well as between replicas currently present? How do client/request identities, log positions, and simulator operation IDs relate to the required guarantees? Are application state and returned results consistent with sequential application semantics from compatible initial states? (`simulator/properties.rs:207`, `simulator/properties.rs:250`, `simulator/properties.rs:291`)

- **Independent assurance:** Which assumptions follow from the public service contract and corrected VSR reference, and which are choices of the DST workload, scheduler, or retained Lean model? Could agreement on tested traces leave a required service property unestablished because the implementation and model share the same assumption or abstraction? (`README.md:60`, `simulator/lib.rs:712`, retained Lean README: "How we know the model is the code")
