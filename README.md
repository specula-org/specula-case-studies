# Specula Case Studies

Case studies for [Specula](https://github.com/specula-org/Specula): TLA+ specifications synthesized from real-world systems.

## Cases

### etcd-raft

TLA+ specifications for [etcd/raft](https://github.com/etcd-io/raft), synthesized and validated using Specula.

**Scenarios:**

| Scenario | Description |
|---|---|
| `snapshot` | Core Raft protocol with snapshot and configuration change |
| `progress_inflights` | Progress tracking and in-flight message management |
| `leaseRead` | Lease-based read optimization |

Each scenario contains:
- `spec/` - TLA+ specifications (main spec, model checking config, trace validation config)
- `harness/` - Go instrumentation harness for trace extraction
- `harness/traces/` - Extracted execution traces (.ndjson)
- `patches/` - Source code instrumentation patches (if applicable)

**Artifact:**
- `artifact/raft/` - Instrumented etcd/raft source (submodule from [specula-org/raft](https://github.com/specula-org/raft))


### swiftpaxos

TLA+ specifications for [SwiftPaxos](https://github.com/imdea-software/swiftpaxos), created by Specula.

- `spec/` - TLA+ specifications (model checking and trace validation specs, configs).
- `patches/` - Instrumentation patch.
- `artifact/swiftpaxos` - A submodule of the upstream repo. Trace files are collected locally in `artifact/swiftpaxos/traces`; these are not tracked in Git. These traces are the result of `./swiftpaxos` runs with variations of `local.conf` from the instrumentation patch.
