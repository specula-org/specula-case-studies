# Specula Case Studies

Case studies with [Specula](https://github.com/specula-org/Specula): TLA+ specifications synthesized from real-world systems.

## Case Studies

| Case study                                                                  | Spec folder                                                                    | Language | Family |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------- | ------ |
| [Etcd Raft](https://github.com/etcd-io/raft)                                | [`etcd-raft/scenarios/`](./etcd-raft/scenarios/)                               | Go       | Raft   |
| [Hashicorp Raft](https://github.com/hashicorp/raft)                         | [`hashicorp-raft/scenarios/base/spec/`](./hashicorp-raft/scenarios/base/spec/) | Go       | Raft   |
| [SwiftPaxos](https://github.com/imdea-software/swiftpaxos)                  | [`swiftpaxos/spec/`](./swiftpaxos/spec/)                                       | Go       | Paxos  |
| [EPaxos](https://github.com/imdea-software/swiftpaxos/tree/master/epaxos)   | [`epaxos/spec/`](./epaxos/spec/)                                               | Go       | Paxos  |
| [N2Paxos](https://github.com/imdea-software/swiftpaxos/tree/master/n2paxos) | [`n2paxos/spec/`](./n2paxos/spec/)                                             | Go       | Paxos  |

## Structure

The case studies follow this structure:

- `artifact/` - a Git submodule of the system implementation.
- `harness/` - if not already included in base repo, trace extraction or replay driver code used for trace validation.
- `spec/` - TLA+ specs and configs.
- `patches/` - instrumentation and other local modifications (usually LLM-generated).
- `invariants/` - a copy of the original paper, or plain-text natural-language invariants to guide spec generation.

Traces are usually found in `harness/traces/` or as untracked files inside the `artifact` folder itself.

<details>
<summary>Etcd Raft Scenarios</summary>

We have specified multiple scenarios for Etcd Raft, focusing on different submodules. Each is available in its own `scenarios` folder within the `etcd-raft` case study.

| Scenario             | Description                                               |
| -------------------- | --------------------------------------------------------- |
| `snapshot`           | Core Raft protocol with snapshot and configuration change |
| `progress_inflights` | Progress tracking and in-flight message management        |
| `leaseRead`          | Lease-based read optimization                             |

Each scenario contains its own `harness/traces/` for the extracted execution traces and its own `patches/` for source code instrumentation.

We've added some modifications to Raft, so we use the submodule at [specula-org/raft](https://github.com/specula-org/raft) instead of the Etcd base repo.

</details>
