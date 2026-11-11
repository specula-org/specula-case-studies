------------------------------ MODULE Timing ------------------------------
\* Timing assumptions of the model, which has no clock. Each assumption is a
\* ledger row (notes/ledger.csv, Timing.TA*) with its code constants and margins.
\* Guards: TimingOK(Faults, escape, holds) allows the ordering if the assumption
\* holds or the priced escape fault is enabled. Pass the variant's own Faults
\* (the pricing instances substitute it); scripts/rarity.py reads the escape
\* name from the call.
EXTENDS Naturals

TimingOK(fs, escape, holds) == escape \in fs \/ holds

\* TA1: a CJ's DS shutdown follows the SJ's (or the SJ is gone). Escape slowSJTeardown.
TA1Holds(sjDsShutdown, sjGone) == sjDsShutdown \/ sjGone
\* TA2: the graceful terminate does not overtake an admin stop in progress. Escape slowAdminStop.
TA2Holds(adminStopping) == ~adminStopping
\* TA3: no new download after the SJ's DS shutdown (late envelope). Escape slowEnvelope.
TA3Holds(sjDsShutdown) == ~sjDsShutdown
\* #18 T5: an SP shutdown's stop_all_runs loop finishes before a stopped job's SJ exits
\* (each iteration is milliseconds while the clients reply). Escape slowShutdownAbort: a
\* registered client does not reply, so each abort_client_run waits its 2 s timeout.
TA5Holds(shutdownLoop) == ~shutdownLoop
\* #17 no 30 s clock tick between the workflow's return and finalize_run. Escape slowFinalize.
TA4Holds(wfReturned) == wfReturned = "none"

TimingGuardEscapes == {"slowSJTeardown", "slowAdminStop", "slowEnvelope", "slowFinalize", "slowShutdownAbort",
                       "gatherRace"}
\* escape events: actions gated by the fault itself (statically priced)
TimingEventEscapes == {"statusLost", "monitorStale", "jobExitRace"}
=============================================================================
