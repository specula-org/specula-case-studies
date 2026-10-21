# Candidate v6 amendment D9: wait for the requested CPU after sched_setaffinity

Author: lane controller (Claude), 2026-10-10. Trigger: outcome run v6d8-1 (evidence
`20261010T045718Z-1507683-6153758b6f66472c8ef18ab44acb4867`). The kernel built and every guest booted with `WR_GUEST_NPROC 2`. All 21 Linux
controls matched. All 21 guest fixtures then aborted at
`wait_reap_trace.c:74: pin: Assertion 'sched_getcpu() == cpu' failed`, so every guest
outcome is inconclusive.

Cause, by source reading: the pinned Asterinas `sys_sched_setaffinity`
(`kernel/core/src/syscall/sched_affinity.rs:37-61`) only stores the new mask, and
`sys_getcpu` (`kernel/core/src/syscall/getcpu.rs`) reports the CPU the task currently runs on.
The task therefore stays on its old CPU until its next reschedule. Linux migrates the caller
before `sched_setaffinity` returns, and the Linux controls passed the same assertion. This
difference is outside the wait/reap protocol and is recorded as an observation only.

Change (`src/wait_reap_trace.c` and its frozen copy, copied into the source by `apply.sh`):
`pin()` yields until `sched_getcpu()` equals the requested CPU, at most 100,000 yields, and
then keeps the original assertion. On Linux the loop exits immediately. No outcome call,
expected outcome, comparison or grouped-path logic changes. `candidate-v6/hashes.json` was
regenerated.

Pre-review check in a throwaway offline container: both the Linux and `__asterinas__` variants
compile statically, and the Linux variant pinned to CPUs 0,1 ran `nohang 37` in outcome mode
to `WR_OUTCOME_COMPLETE`. The Asterinas behaviour is not checked yet. That needs the guest run.

The author does not approve this change.

## Revision after review-v6e (D9-S1, D9-S2, D9-T1)

`review-v6e.md` did not approve D9. D9-S1 (Medium): yielding cannot migrate the task. The
pinned `sched_setaffinity` documents that migration is unsupported (`sched_affinity.rs:33`),
`yield_now()` requeues on the same CPU, and `select_cpu()` returns `last_cpu` before consulting
affinity. Placement is chosen only at spawn, and POSIX threads start with a full mask
(`process/posix_thread/builder.rs:212`). So the diagnosis above, that the task "moves at its next
reschedule", is wrong. The task never moves.

Revised change: the yield loop is removed and `pin()` is back to its approved form, still used
by the grouped path. The outcome path instead calls a new `outcome_pin(actor, cpu)`. It
requests the CPU with `sched_setaffinity`, does not assert placement, and prints
`WR_OUTCOME_PLACEMENT {"actor","requested_cpu","actual_cpu"}`. It is used for w1, w2 and the
child. `collect_outcome.py` accepts that prefix and records `placement` and
`actors_on_distinct_cpus` in the report. Placement never affects the comparison. On Asterinas
the two waiters may therefore share a CPU, and the report says so per run. Concurrency claims
must use that field. The guest still boots with `-smp 2` and still checks `WR_GUEST_NPROC 2`.

D9-S2 (Low): the earlier range also carried the D8-S2 note in `d8-amendment.md`, which has no
runtime effect. D9-T1 (Low): the semicolon above is replaced.

Pre-review check in a throwaway offline container: both variants compile. The Linux variant
pinned to CPUs 0,1 completed `nohang`, `compete 44` and `overlap i4` in outcome mode and
printed placement records with actual equal to requested.

The author does not approve this change.

## Second revision after review-v6f (D9R-S1, D9R-S2, D9R-S3, D9R-T1)

`review-v6f.md` did not approve the first revision.
- D9R-S1 (Medium): `outcome_invoke()` still called `check_cpu()` before and after each syscall.
  Both calls are removed. The helper and every grouped-path check are unchanged.
- D9R-S2 (Medium): placement validation accepted malformed records. The collector now requires
  one record per expected actor (w1 and child always, w2 only for `compete` and `overlap`),
  dict records with exactly the three fields, integer CPUs, a nonnegative actual CPU, and a
  requested CPU equal to the fixture's selection (w1 to `selected_cpus[0]`, child and w2 to
  `selected_cpus[1]`). `actors_on_distinct_cpus` is computed only after that validation.
  Actual-versus-requested differences stay informational.
- D9R-S3 (Low): `cpu_identity.cpu` now reports `sched_getcpu()`, the CPU w1 actually ran on when
  CPUID was read. The collector no longer requires it to equal the requested CPU.
- D9R-T1 (Low): the stale "two" in the allowlist comment is removed.

Pre-review checks in a throwaway offline container: both variants compile. Linux outcome runs
pinned to CPUs 0,1 for `consumers44-park`, `nohang-37` and `observer-consume4` were collected by
the revised `collect_outcome.collect` (review gate stubbed for the test only). All three were
`match` with no problems and complete placement, with `actors_on_distinct_cpus` true, absent
and true respectively.

The author does not approve this change.

## Third revision after review-v6g (D9R2-S1)

`review-v6g.md` did not approve the second revision. D9R2-S1 (Medium): placement was validated
before the syscall records were parsed. A missing w2 placement, after a setup failure or a
timeout, therefore discarded completed calls that the approved partial-evidence contract keeps.
The placement block now runs after the syscall records and before the CPU, boot and completion
checks. Validated calls survive a placement error, and incomplete placement still makes the
overall result inconclusive.

Pre-review check: a Linux `observer-consume4` outcome log was collected in full (`match`, five
calls matched). A copy truncated just before the w2 placement record (run exit 124) kept its two
completed calls as `match`, and the overall result was `inconclusive` with the problem at
"checking actor placement". The review gate was stubbed for the test only.

The author does not approve this change.

## Fourth revision after review-v6h (D9R3-S1)

`review-v6h.md` did not approve the third revision. D9R3-S1 (Medium): a log cut off at the
fragment `WR_OUTCOME_PLACEMENT` failed the transport allowlist before any syscall record was
parsed, so completed calls were still lost. `boot.py` saves raw serial blocks, so a timeout
can end the log mid-line.

Change (`src/collect_outcome.py` and its frozen copy): when the raw log does not end with a
newline or carriage return, the collector drops the unterminated tail before decoding. That
also covers a cut inside a multi-byte character. It adds the problem
"The truncated final log line was excluded from the outcome transport. The run is incomplete.", which
keeps the overall result inconclusive. Complete foreign `WR_` lines are still rejected as
before. The raw-log hash still covers the full payload.

Pre-review check: from a Linux `observer-consume4` log, these inputs were collected with run
exit 124 (review gate stubbed for the test only):
- the full log;
- a copy truncated before the w2 placement;
- the same copy plus `WR_OUTCOME_PLACEMENT`;
- the same copy plus `WR_OUTCOME_CA` and a partial UTF-8 sequence.

The full log was `match`. Each truncated variant kept its two completed calls as `match` and
was `inconclusive` overall.

The author does not approve this change.

## Fifth (final) revision after review-v6i (D9R4-S1, D9R4-T1)

`review-v6i.md` did not approve the fourth revision. D9R4-S1 (Medium): a newline-terminated
bare `WR_OUTCOME_PLACEMENT` line failed the transport allowlist, which requires a trailing
space, before any syscall record was parsed. The transport stage now admits any line starting
with `WR_OUTCOME_PLACEMENT`. The placement stage, which runs after the syscall records, rejects
any such line that lacks the `WR_OUTCOME_PLACEMENT ` prefix or carries an invalid payload. Other
foreign `WR_` transport lines, such as recorder or clock output, are still rejected at the
transport stage as before. D9R4-T1 (Low): the diagnostic now reads "The truncated final log line
was excluded from the outcome transport. The run is incomplete."

Pre-review check (review gate stubbed for the test only). From a Linux `observer-consume4` log,
these inputs were collected:
- the full log, which was `match`;
- the log truncated before the w2 placement;
- that copy plus `WR_OUTCOME_PLACEMENT\n`;
- that copy plus `WR_OUTCOME_PLACEMENT\r\n`;
- that copy plus `WR_OUTCOME_PLACEMENT {\n`;
- that copy plus a truncated `WR_OUTCOME_CA` with a partial UTF-8 sequence.
Every truncated or malformed variant kept its two completed calls as `match` and was
`inconclusive` overall. A copy with an appended `WR_RAW` recorder line was still rejected at
the transport stage, with no calls kept.

The author does not approve this change. The coordinator capped D9 at this revision.
