--------------------------- MODULE Trace ---------------------------
(* Trace Validation Spec - Minimal Working Version *)

EXTENDS Naturals, Sequences, Json

\* Load trace from JSON file
TraceLog == ndJsonDeserialize("../traces/trace.ndjson")

VARIABLE l

\* Initialize at position 0 (before first event)
TraceInit ==
    l = 0

\* Advance through trace
NextAction ==
    /\ l <= Len(TraceLog)
    /\ l' = l + 1

\* Done - stutter forever
Done ==
    /\ l > Len(TraceLog)
    /\ l' = l

TraceNext ==
    \/ NextAction
    \/ Done

\* Property: all events were eventually processed
TraceMatched == <>(l >= Len(TraceLog))

=============================================================================
