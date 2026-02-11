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
