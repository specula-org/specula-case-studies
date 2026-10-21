# Harness execution record

The harness instruments the real Asterinas kernel at
`0c60537098f4c2949ad2d382aaf499de72263d76`. Acceptance is incomplete. The final ordered-clock revision was not rebuilt
or executed because host MemAvailable remained below the required 10 GiB.
The pre-build waiters were stopped after approximately 12 minutes of waiting
across the two attempts. No final build, guest or TLC job remains active. The final ELF and its
compiled destructor-hook placement have not been inspected because that
revision could not be built.
`status.json` and `evidence/latest` identify the final attempt and measured
resource value. Do not treat older accepted replays as execution of the final patch.

The earlier batch `evidence/20261005T193639Z` contains 23 production traces,
1,117 events, all 34 action types, and 23 successful unchanged `Trace.cfg`
replays. Each replay had a nonzero initial state count. No witness fallback
was needed. That batch's exact trace bytes are retained in its `normalized/`
directory. A later repeated run rejected two cross-CPU clock samples before
those fixtures entered the protocol. The final revision adds LFENCE before
RDTSC and must pass its own complete run before these runtime results can be
attributed to it.

The complete timebox coverage ratio remains a quality gap. The earlier
competition traces had 4 of 936 and 8 of 2,384 overlapping cross-thread event
pairs, respectively. These are real overlaps, but both are below the timebox
guide's 20% criterion. The denominator includes all sender, receive and cleanup
event pairs. Sender and cleanup events are intentionally outside receive
execution, and each thread's tightly measured events are ordered and disjoint.
No intervals are widened or events discarded to improve that percentage.
This criterion is not marked satisfied.

The known AST-32 and AST-36 behaviors remain visible. First-number faults
leave one installed FD in Asterinas and none in the Linux control. Later-number
faults leave three installed entries in Asterinas, including two complete
numbers, while Linux retains those two completed entries. Asterinas reports
control length zero in both integer-fault layouts. Linux reports 24 bytes for
the two-entry prefix. A normal payload fault leaves the Asterinas message
available to the valid retry, while the Linux normal retry returns EAGAIN.
Both PEEK payload-fault retries succeed. These are bounded observations from
existing leads, not new defect candidates or Phase 4 dispositions.

The Linux control kernel is 7.2.8. Its booted NixOS derivation and matching local
source were inspected. The source comparison in
`evidence/20261005T194207Z/linux-source/RECONCILIATION.md` explains why the
6.16.5 reference's scoped contract still applies despite a newer FD cleanup
helper. The Linux traces are not inputs to the Asterinas transition relation.

No confirmation, classification, repair, upstream submission or shared catalog
update was performed. The receiving controller owns subsequent phase gates.

To resume, let the receiving controller hold the shared heavy-stage lock and
run `bash harness/run.sh` from `.specula-output`. The script waits for 10 GiB
MemAvailable, then requires all 128 clock comparisons for every fixture,
observed distinct receiver CPUs, complete traces and the unchanged model
checks. Record the 20% overlap criterion separately. Preserve the existing
`evidence/` directories. Do not advance to confirmation or classification on
the basis of this incomplete Phase 2.5 result.
