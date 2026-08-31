# LiteBox trace harness

Run from `.specula-output/`:

```sh
bash harness/run.sh
```

Set `LITEBOX_SOURCE_ROOT` to use another clean checkout at source head
`49f7231eef1f53836648c88bf9897d116fb73a96`. `apply.sh` copies the feature-gated
trace crate and tests, then applies `patches/instrumentation.patch`. It is
idempotent. `clean.sh` reverses only an exact copy of that patch.

## Trace module

`harness/src/litebox_tla_trace/src/lib.rs` owns the per-thread `BufWriter`,
fenced `rdtsc` timestamps, stable-ID registry, and focused shadow fields. The
event path has no shared writer lock. Resource lookup takes the registry mutex
only on the first encounter and then uses a thread-local cache. The fixed model
shadow uses atomics and is updated at the same real commit point as the source
operation.

To add a field, add it to the appropriate recorder in that file and to the
source call that supplies the observed value. Keep state capture after `end`
and after production guards are dropped. Every emitted field is checked by
`Trace.tla::ValidatePostState`; do not add unvalidated fields.

To add an event, copy an existing `start -> real operation -> end -> recorder`
pattern, add the exact event name to the scenario's enabled list, and add it to
`harness/check_traces.py::EXPECTED`.

## Probe locations after apply

- Namespace: `litebox/src/fs/resolver.rs:226`,
  `litebox/src/fs/in_mem.rs:258,499,539,598`, and
  `litebox_shim_linux/src/syscalls/file.rs:226,1841,1869`.
  The layered filesystem can invoke several backend walks for one logical
  resolution; the recorder retains only the first modeled successful walk.
- FD/OFD: `litebox/src/fd/mod.rs:109` exposes the shared-entry `Arc` identity;
  probes are in `litebox_shim_linux/src/syscalls/file.rs:300,455,836,998,1019,
  2545,2694,2714,2760` and `syscalls/epoll.rs:277`.
- Mapping generation: `litebox_shim_linux/src/syscalls/mm.rs:118,137,287,306,
  449,517,580,630`. CoW records the host and Vmem boundaries separately. The
  memcpy fallback records the real `PageManager::create_*` call as the host
  interval and a post-call publication boundary because the helper owns both
  allocation and Vmem insertion.
- Clone ownership: `litebox_shim_linux/src/syscalls/process.rs:68,89,703,714,
  725,738,769` and the real SNP provider at
  `litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:272-289`.
- Futex: `litebox/src/sync/futex.rs:111,135,139,146,157,195,212,234`.
  Selection markers are buffered while `LoanList` is locked and emitted only
  after extraction. `FutexSetValue` brackets the focused test's real
  `AtomicU32::store` in the trace crate.

## Scenarios and capture levels

- `namespace_identity.ndjson`: specialized identity state derived from real
  `Arc` allocations and successful namespace mutations.
- `fd_ofd_identity.ndjson`: specialized slot-generation state plus real shared
  descriptor-entry identities and real directory offsets.
- `mapping_generation.ndjson`: specialized one-page generation state. The
  focused setup installs a real page-sized static file and real patch-cache
  interval before tracing.
- `clone_*.ndjson`: specialized transaction/ownership state. The success and
  failure tests inject the provider result after the real attach and ownership
  transfer. The production SNP provider is instrumented at its actual host
  syscall edge; host unit tests use the same recorder without executing a VMPL
  hypercall.
- `futex_validation_quota.ndjson`: specialized waiter lifecycle and queue
  length captured at the real insert/compare/select/wake points.
- `futex_overlap.ndjson`: two simultaneous real insertions. Its start barrier is
  enabled only in this quality probe so the compressed trace necessarily
  contains a cross-thread overlap; normal scenario intervals remain tight.

The shadow state is intentionally finite (`t0`--`t2`, `fd0`--`fd1`,
`ofd0`--`ofd1`, `addr0`) to match `Trace.cfg`. A scenario that needs another
resource must expand both the TLA+ constants and the recorder bounds.

## Validation expectations

`trace.ndjson` is the passing namespace smoke trace. Current end-to-end results:

- Passing: namespace, FD/OFD, mapping generation, clone success, and futex
  overlap.
- `TraceSafety` violations by design: clone stack failure, clone provider
  failure, and futex unvalidated-waiter quota. These are implementation traces,
  not hand-authored counterexamples; Phase 3 should inspect the violated
  invariants before changing either the base spec or probes.

After moving a capture point, regenerate the patch, run `cargo fmt --all`, then
run `bash harness/run.sh`. The script validates JSON shape, all 40 event types,
cross-thread overlap, and the passing TLC smoke trace.
