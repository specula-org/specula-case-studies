# LiteBox

## Scope

Specula analyzed LiteBox's Rust runtime and Linux-shim behavior, with emphasis on filesystem namespace identity, file-descriptor and open-file-description semantics, memory mapping and executable patching, thread creation failure atomicity, epoll retention, and futex wait/wake ordering.

The reviewed record is the [known-aware LiteBox rerun](modules/core/runs/litebox-known-aware-rerun-20260830/README.md). The run used target-specific guidance to avoid spending confirmation effort on issues already clearly known to LiteBox maintainers unless it could demonstrate a new harmful consequence, a new live consumer, or a stronger trigger scenario.

## Bugs

The reviewed run records **9 reproduced bugs**: 3 `Critical`, 5 `High`, and 1 `Medium`. The list below is ordered by expected maintainer value rather than by severity alone.

- **Critical:** a stale ELF patch plan can rewrite bytes in a newer `MAP_FIXED` mapping after `mprotect(PROT_EXEC)`, permanently corrupting executable contents until the mapping is replaced or unmapped.
- **Critical:** an unvalidated futex waiter can consume a `wake(1)` quota while a validated waiter remains blocked, creating a lost-wake liveness failure for callers without a timeout.
- **High:** one `readv` syscall can read different iovec chunks from different open-file descriptions after raw-fd reuse in a shared fd table.
- **High:** a failed public `clone3` call can return `EINVAL` while still writing a newly allocated child TID into parent memory.
- **High:** `open(O_CREAT)` racing with `rmdir` can return a writable fd for a file inserted into an already detached parent directory.
- **High:** a task whose current working directory pathname is removed and recreated can have later relative operations silently redirected to the replacement directory.
- **High:** duplicated directory file descriptors do not share `getdents64` directory position, so the duplicate can repeat entries that should have been consumed through the original fd.
- **Critical, caveated:** SNP host-spawn failure after child attachment can leak a phantom thread and block process quiescence; the reproducer uses fault injection corresponding to the model-checking counterexample because normal userland execution cannot force that host failure path.
- **Medium:** epoll interests retained after last close can accumulate across raw-fd reuse; wrong readiness delivery is masked by weak-entry skipping, so the demonstrated consequence is persistent internal resource retention.

The run directory preserves the pipeline reports, specifications, traces, and reproduction scripts used to support these summaries.

## Related prior observation

A previous LiteBox confirmation pass mostly rediscovered maintainer-aware or already tracked issues. One item still added useful evidence: the fixed-address CoW/vmem-tracker race was already acknowledged as a race, but the reproduction showed a concrete harmful consequence. An interleaving can leave the host mapping writable while LiteBox records the range as read-only, after which `mprotect(PROT_READ)` may return success without issuing a host permission change and a write can still succeed.
