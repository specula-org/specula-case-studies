------------------------------ MODULE Timing ------------------------------
\* Timing assumptions of the model, which has no clock. Row numbers (#n) refer
\* to notes/timing-inventory.md, which holds the code constants and margins.
\* Guards: TimingOK(Faults, escape, holds) allows the ordering if the assumption
\* holds or the priced escape fault is enabled. Pass the variant's own Faults
\* (the pricing instances substitute it); scripts/rarity.py reads the escape
\* name from the call.
EXTENDS Naturals

TimingOK(fs, escape, holds) == escape \in fs \/ holds

\* #1 T1: a CJ's DS shutdown follows the SJ's (or the SJ is gone). Escape slowSJTeardown.
T1Holds(sjDsShutdown, sjGone) == sjDsShutdown \/ sjGone
\* #2 T2: the graceful terminate does not overtake an admin stop in progress. Escape slowAdminStop.
T2Holds(adminStopping) == ~adminStopping
\* #3 T3: no new download after the SJ's DS shutdown (late envelope). Escape slowEnvelope.
T3Holds(sjDsShutdown) == ~sjDsShutdown
\* #18 T5: an SP shutdown's stop_all_runs loop finishes before a stopped job's SJ exits
\* (each iteration is milliseconds while the clients reply). Escape slowShutdownAbort: a
\* registered client does not reply, so each abort_client_run waits its 2 s timeout.
T5Holds(shutdownLoop) == ~shutdownLoop
\* #17 T4: no 30 s clock tick between the workflow's return and finalize_run. Escape slowFinalize.
T4Holds(wfReturned) == wfReturned = "none"

TimingGuardEscapes == {"slowSJTeardown", "slowAdminStop", "slowEnvelope", "slowFinalize", "slowShutdownAbort"}
\* escape events: actions gated by the fault itself (statically priced)
TimingEventEscapes == {"statusLost", "monitorStale", "jobExitRace"}
=============================================================================
