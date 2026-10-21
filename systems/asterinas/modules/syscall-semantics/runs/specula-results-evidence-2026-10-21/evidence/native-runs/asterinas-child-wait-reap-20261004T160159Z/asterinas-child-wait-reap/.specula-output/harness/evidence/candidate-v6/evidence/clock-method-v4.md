# Candidate v4 clock method and its limits

This note is for the independent reviewer and controller of the child wait/reap lane. Candidate v4 provides execution-ordered local timestamps and a measurable, conditional cross-CPU offset interval. It does **not** close R2 for TraceSpec acceptance. Two obligations remain: several event ends do not bound global store visibility, and finite calibration samples do not bound cross-vCPU offset or drift throughout the run. The collector therefore has no grouped-trace output path, even with an approved receipt. The current receipt remains `INCOMPLETE`.

The pinned source is `0c60537098f4c2949ad2d382aaf499de72263d76`. Source references below use the already instrumented v3 checkout specified in the task. [v4-inputs.json](v4-inputs.json) binds that installation and the protected model inputs. No v4 source installation, binary, runtime measurement or independent v4 review exists. The 41-event mapping, hook locations, source patch, cases and expected results are unchanged.

## Instructions and environment contract

Both `src/wr_trace.rs::stamp()` and `src/wait_reap_trace.c::stamp()` use exactly:

```asm
lfence
rdtsc
lfence
```

The result is `(EDX << 32) | EAX`. Rust uses one `asm!` block without `nomem`, `readonly` or `pure`. C uses one volatile assembly block with a `memory` clobber. Those choices prevent compiler memory motion across the stamps. They do not introduce a hardware store-buffer drain. Unsafe access stays inside OSTD. The emitted binary still needs independent disassembly after the controller builds it.

The instruction contract is deliberately limited to Intel execution semantics. Intel specifies that LFENCE waits for earlier instructions to complete locally and prevents later execution until it completes, while an earlier store can still await global visibility. The leading fence keeps the read after the preceding operation's local completion. The trailing fence keeps the next operation after the timestamp. [Intel SDM, Volume 3A, sections 8.2.5 and 8.3](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf).

Before registration, all three fixture actors check `GenuineIntel`, TSC, SSE2/LFENCE and CPUID leaf availability on their pinned CPU. The invariant-TSC test is `CPUID.80000007H:EDX[8]`. [Intel SDM, Volume 1, CPUID leaf 80000007H](https://cdrdv2-public.intel.com/874240/325462-090-sdm-vol-1-2abcd-3abcd-4.pdf). Other vendors are refused because this candidate supplies no separate LFENCE execution contract for them. A virtual vendor string states the guest interface, not proof of the hypervisor's implementation.

`w1` uses the first CPU in the allowed affinity mask. `w2` and `child` use the second. `check_cpu()` requires a singleton mask and the expected `sched_getcpu()` value. It runs around each user syscall interval and calibration phase, and before child exit. Calibration and CPUID use the same guest CPUs, or the same Linux control CPUs, as that fixture invocation. CPUID is outside the measured operations and the ping-pong samples. These checks do not observe every kernel instruction's CPU. Scheduler compliance with affinity remains an environment assumption. They also do not pin QEMU's vCPU threads to physical host CPUs or prevent migration of an outer VM.

## Per-operation soundness analysis

These conclusions assume that the compiler emits the expected x86 instructions, that the Intel execution contract holds and that timestamps are comparable. They are source analysis, not disassembly or runtime results. “Contained” means that the relevant operation has its linearization/read point inside the interval, not that unrelated buffered stores have drained.

| Operation kind and existing hooks | What the interval establishes | Remaining global-effect obligation |
| --- | --- | --- |
| Plain Relaxed exit-code store, `ProcessStoreExitCode`, `process/status.rs:82-85`. | The store executes locally after the start and before the end. | The write may remain buffered after the end. It is not a publication interval. |
| Plain Release zombie store, `ProcessPublishZombie`, `process/status.rs:55-58`. | The Release store executes locally within the interval. | Release does not make the end a visibility bound. A different CPU may still read `false` after this end. |
| Locked RMW, including queue `fetch_add(1, Acquire)` / `fetch_sub(1, Release)` and token `swap`, `ostd/src/sync/wait.rs:126,149,286,302,317`. | With `lock xadd` / an equivalent locked operation, or the implicitly locked memory `xchg`, the atomic read-modify-write point is contained. Its own ordering comes from the protocol instruction. | Check actual code generation. The whole enclosing event can also include a later plain unlock, which this conclusion does not cover. |
| Zero-add queue-count read, `WaitQueueWakeAllCheck`, `wait.rs:114` and the explanation at `136-140`. | The source explicitly permits `mfence; mov` for `fetch_add(0, Release)`. In that form the read point is contained and the protocol's own MFENCE drains prior stores. A locked lowering also supplies its own ordering. | Do not label every Rust RMW a locked instruction. Verify this particular lowering in the approved binary. |
| Acquire zombie/token load, `process/status.rs:45-46`, `wait.rs:308`, scheduler false check at `scheduler/mod.rs:457-460`. | The actual load and its saved result are execution-bracketed. The false check still ends beside the load while holding the runqueue guard. | A read of `false` need not observe a preceding buffered store. An Acquire read that observes a Release publication supplies the protocol's visibility relation. LFENCE does not supply the missing publication. |
| Mutex/spinlock acquisition, `mutex.rs:62-65`, `spin.rs:110-114`, `TryWaitChildrenLock`. | A successful locked compare-exchange has its acquisition point inside the interval. Waiting before success is included. | This does not move the visibility of an earlier owner's plain unlock inside that owner's timestamp interval. |
| Mutex release, `TryWaitChildrenUnlock`, `mutex.rs:56-69`. | The release store and the existing `wake_one()` execute before the end. | The release store alone is insufficient. On this pin `wake_one()` reaches the queue's zero-add Release RMW, so an `mfence; mov` or locked lowering can supply an existing drain before the end. This is conditional on generated code and that path, not a generic property of mutex release or LFENCE. |
| Spinlock release and composite scheduler/signal events, `spin.rs:117-118`, true `ParkCurrentCheck`, `ParkCurrentDequeue`, `SchedulerUnparkTarget`, signal `WakerWakeFinish`. | The original release/return boundary is preserved. The true park interval still includes guard drop after `reschedule`, and the false branch remains distinct. | A plain spinlock Release store has no general end-of-interval visibility guarantee. A later incidental locked operation on some paths is not a guarantee for all these events. |
| Protected map/queue/slot mutation, retained Arc and output events. | Saved operands, results and snapshots retain their approved local meanings under the existing guards. The C helper brackets syscall execution and return on its pinned CPU. | Protected data becomes available to another owner through the source lock protocol. Do not infer that every data store or guard release is globally visible at its local end. Composite projections still require their existing source justification. |

V4 adds no MFENCE, SFENCE, CPUID, locked RMW or remote acknowledgement to a measured kernel bridge. LFENCE delays execution but allows an earlier store to remain buffered while a later independent load executes. It therefore does not add the StoreLoad visibility ordering supplied by the queue-count operations. Nor does it replace the exit-code/Release-zombie/Acquire-zombie publication relation. Release and Acquire by themselves must not be described as a full fence between unrelated stores and loads. Calibration synchronization occurs before the first modeled operation and after notifier/call completion, with no modeled lock held. Existing v3 recorder atomics are unchanged. Extra instruction latency and compiler barriers can still perturb schedules and hide failures. These traces cannot prove weak-memory correctness.

## Calibration derivation and refusal rules

Each invocation records 64 fenced request/reply samples before the scenario and 64 after notifier completion. The Linux variant executes on the Linux control host through its container and performs the same checks and measurements without the private instrumentation syscall. The guest performs its own independent calibration. Neither measurement calibrates the other environment.

A row contains `a0, b0, b1, a1`: reference CPU A stamps before publishing a request, CPU B stamps twice after observing it and before publishing its reply, and A stamps after observing the reply. Release/acquire communication plus the stamp execution fences establish this causal sequence. Raw mixed-CPU numbers are **not** required to be sorted.

Assuming one constant offset `delta = B(t) - A(t)` and the same tick rate during a calibration epoch:

```text
b1 - a1 <= delta <= b0 - a0
L_phase = max(b1 - a1 over the phase's samples)
U_phase = min(b0 - a0 over the phase's samples)
B_sampled = max(abs(L_pre), abs(U_pre), abs(L_post), abs(U_post))
```

The diagnostic report records all samples, CPU/CPUID records, both intervals and `sampled_abs_bound_cycles`. The fixed admission threshold is **100,000 TSC ticks**. It is an operational cutoff for imprecise samples, not a hardware drift bound or an assumption that smaller offsets are zero. `run_wide_bound_cycles` stays `null`. No measured value is supplied for v4 because execution is `NOT_RUN`.

The collector refuses unsupported/missing CPUID evidence, missing pre/post phases or samples, duplicate or reordered sample indices, same-CPU regressions, inconsistent offset intersections, disjoint pre/post intervals, or a sampled bound above the threshold. It also checks that each event and user syscall lies between the pre/post endpoints on its own CPU. Drops, truncated queues, local event overlap, return-count mismatch and kernel/user inversion retain their prior refusals. The review gate runs first. Even in-bound, complete calibration cannot enable grouped output. There is no override flag.

Invariant TSC indicates rate stability under the processor's documented conditions, not a system-wide synchronization contract. A finite handshake constrains its sampling epochs under the constant-offset assumption. It supplies no worst-case bound for an unseen offset excursion, rate difference or hypervisor TSC adjustment between epochs. Matching pre/post intervals cannot exclude a jump that returns to its previous value. KVM documents CPU-local clocks, drift, virtual offsets and migration concerns. [Linux KVM timekeeping documentation, sections 3.1, 3.3, 3.7-3.9 and 4.4](https://docs.kernel.org/virt/kvm/x86/timekeeping.html). The current `boot.py` uses `-cpu host` and two vCPUs without a run-wide clock contract. Linux `uname`/CPUID and guest CPUID alone cannot supply that contract.

## Consequences for acceptance and rejection

An early store end can falsely order a zombie publication before a different CPU's stale read, causing rejection of a valid implementation history. Under otherwise sound starts, clocks and fixed actor order, shortening only ends **adds** precedence edges. If a sound end is less than another start, the premature end is also less. Thus, at the partial-order level, every match of the shortened intervals is also a match after their sound enlargement. A premature store end alone cannot turn an existential rejection of those sound intervals into acceptance. It still cannot establish that the matched model order was the actual global visibility order.

This one-sided argument does not rescue the original method: an unsound start or a cross-CPU clock error can remove a real precedence edge and permit a false existential acceptance. An admitted numerical witness would prove consistency with the supplied intervals only. V4 therefore produces neither an acceptance nor a rejection of an implementation trace.

The unchanged `Trace.tla:143-146` permits competing actors when their intervals overlap or touch. It only forbids an actor when another pending event has `end < start`. Per-actor arrays also impose local order, and `TraceShapeOK` requires `previous.end <= next.start`. Numeric endpoint compression itself preserves overlap when the input intervals are sound. V3's defect was the unjustified endpoint comparisons, not sorting event arrays, which it did not do.

V4 removes the compression and grouped serialization. With later approval, `--diagnostic` writes JSON containing local ticks, observed events, user outputs and the conditional calibration report, labelled `INELIGIBLE` and `LOCAL_STREAM_ORDER_ONLY`. Event records use `tag: diagnostic` and `local_start_tsc`/`local_end_tsc`. They have no TraceData envelope. Cross-actor overlap quality is not computed from unproved comparable clocks.

No interval is widened from model order. A future method with a justified run-wide bound could widen endpoints conservatively, preserving equalities and overlaps before compression. It would also have to handle the unchanged local non-overlap requirement: reject widened input that violates it, rather than clipping uncertainty to make the model initialize. A small measured offset cannot simply be ignored.

## Why the alternatives do not close this candidate

`RDTSCP; LFENCE` could improve sampling order on an admitted CPU with the required feature, but it still does not drain prior stores. An AUX value would additionally need an established CPU-ID mapping. MFENCE or CPUID around every event would solve a different observation problem by adding store visibility ordering across the bridge being investigated. That would alter this experiment.

A later existing protocol drain could sometimes provide an honest upper bound for an earlier store. The current immediate hook ends do not record such a bound for every event. Extending an earlier event through subsequent same-actor events also conflicts with `TraceShapeOK`'s non-overlap rule. A separate acknowledgement would add new synchronization. Switching to one CPU would abandon the concurrent lane. None is implemented here.

Closing R2 needs both a reviewed source-derived containment/projection for every event and an independently supported clock bound covering the entire run, including virtualization and migration. This is a limitation of this candidate and available evidence, not a claim that all nonintrusive observation methods are impossible.

## Independent review obligations

The reviewer should check the assembly contracts and compiler barriers, every row of the source analysis above, the ping-pong inequalities and lifecycle, CPU identity coverage, the threshold and report fields, and all refusal paths. They should check that no default or diagnostic path emits TraceData, and that an approved receipt alone cannot enable it. They should independently confirm the unchanged 41 mappings, hooks, scenarios and protected inputs against v3.

Any later build must retain disassembly of both stamps and protocol RMW/unlock paths. Any diagnostic execution must retain actual CPUID, samples, measured bounds, affinity evidence, kernel/fixture/image identities and all raw logs. None has been run for v4. The author does not approve this method or close R2.
