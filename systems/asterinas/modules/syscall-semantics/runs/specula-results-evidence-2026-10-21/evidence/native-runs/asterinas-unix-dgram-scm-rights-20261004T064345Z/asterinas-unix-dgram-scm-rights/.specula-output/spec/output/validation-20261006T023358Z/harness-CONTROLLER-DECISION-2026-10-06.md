# Receiving-controller decision for the next harness and validation attempt

This note was written by the receiving controller of run
`asterinas-unix-dgram-scm-rights-20261004T064345Z`, not by a phase agent. It
answers the two prerequisites that `spec/validation-report.md` (attempt
`validation-20261005T200356Z`) left for an explicit controller decision. It
does not change the specification, the trace acceptance rule in
`spec/instrumentation-spec.md`, the resource policy, or any review gate.

## Decision 1: cross-CPU ordering must be qualified, not adjusted

The four calibration failures (cases 0, 7, 10 and 21, remote TSC outside the
local interval by 10 to 236 cycles) mean the per-CPU TSC is not a qualified
cross-CPU ordering source in this guest. The validator was right not to apply
offsets, widen intervals or drop failed cases. That rule stays.

The next attempt must deliver a batch in which every accepted fixture has a
qualified cross-CPU order. Either of these is acceptable:

- Replace the cross-CPU ordering source with one that is linearizable across
  CPUs. One option is a single global sequence counter read with a
  sequentially consistent atomic operation at each timebox start and end. It
  must be read without blocking and outside no additional lock, and it must
  not move any user copy, lock acquisition or drop relative to the source.
  Record that source in `INSTRUMENTATION.md` and show the compiled hook
  placement as before.
- Keep the TSC, but establish why it is unsynchronized and remove the cause.
  Then show that every accepted fixture passes the existing calibration.

Rerunning a fixture whose calibration failed is allowed only if every
attempt, including the failed ones, stays in the evidence directory and the
batch summary reports the attempt count per fixture. Calibration failure must
never be converted into an accepted trace by editing timestamps.

## Decision 2: the overlap requirement for this scope

The timebox guide's quality section asks for at least 20% overlapping
cross-thread event pairs. Its own purpose is that concurrent traces actually
exercise the timebox mechanism. The validation report shows that, for
fixtures carrying this protocol's per-entry events with serialized setup and
cleanup, the fraction is structurally bounded near 2 to 3%. For this run the
controller replaces the 20% figure with the following requirements for the
competition fixtures. Single-receiver fault and capacity fixtures are
sequential by design and exempt.

1. Run competition fixtures on a guest with at least two CPUs, with the two
   receivers released from a common barrier.
2. Each competition fixture must have a nonzero number of overlapping
   cross-thread pairs between events of the two receivers inside the receive
   window, from `RecvBegin` through each receiver's final reporting event.
   Zero overlap remains a failure, as the guide says.
3. Across the batch, there must be at least one accepted fixture where an
   ordinary receive and a successful PEEK both select the same message and
   their receive-window events overlap, and at least one where two ordinary
   receivers compete and their receive-window events overlap.
4. For every competition fixture, report the overlap count, the overall
   cross-thread fraction, the structural upper bound for that fixture, and
   the receive-window fraction. Do not widen intervals or omit events to
   change any of these numbers.

Fixtures may be redesigned to increase genuine overlap, for example by
keeping setup out of the receivers' threads, using fewer rights in a
competition fixture, or repeating the competition in one fixture. The
sequential fixtures must still cover all 34 event types.

## Unchanged

Trace validation still uses `Trace.cfg` and, where it applies, the
`TraceSearch.cfg` witness rule. The resource policy in
`/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json`
still applies, including the 10 GiB build reserve and SMP of at least 2 for
concurrency. Linux controls, model checking, convergence and hunting proceed
as the validation workflow specifies.
