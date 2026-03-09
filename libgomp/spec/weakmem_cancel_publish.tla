----------------------------- MODULE weakmem_cancel_publish -----------------------------
EXTENDS Naturals, TLC

\* MODE = "RELAXED" or "RELEASE"
CONSTANT MODE

VARIABLES cgen, visCgen, flag, obs, wWroteCgen, wPublishedFlag, rDone

vars == <<cgen, visCgen, flag, obs, wWroteCgen, wPublishedFlag, rDone>>

Init ==
  /\ cgen = 0
  /\ visCgen = 0
  /\ flag = 0
  /\ obs = "NONE"
  /\ wWroteCgen = FALSE
  /\ wPublishedFlag = FALSE
  /\ rDone = FALSE

WriterWriteCgen ==
  /\ ~wWroteCgen
  /\ cgen' = 1
  /\ wWroteCgen' = TRUE
  /\ UNCHANGED <<visCgen, flag, obs, wPublishedFlag, rDone>>

WriterPublishFlag ==
  /\ wWroteCgen
  /\ ~wPublishedFlag
  /\ flag' = 1
  /\ wPublishedFlag' = TRUE
  /\ IF MODE = "RELEASE"
        THEN visCgen' = 1
        ELSE visCgen' = visCgen
  /\ UNCHANGED <<cgen, obs, wWroteCgen, rDone>>

PropagateCgen ==
  /\ wWroteCgen
  /\ visCgen = 0
  /\ visCgen' = 1
  /\ UNCHANGED <<cgen, flag, obs, wWroteCgen, wPublishedFlag, rDone>>

ReaderObserve ==
  /\ ~rDone
  /\ flag = 1
  /\ rDone' = TRUE
  /\ obs' = IF visCgen = 0 THEN "STALE" ELSE "FRESH"
  /\ UNCHANGED <<cgen, visCgen, flag, wWroteCgen, wPublishedFlag>>

Next ==
  \/ WriterWriteCgen
  \/ WriterPublishFlag
  \/ PropagateCgen
  \/ ReaderObserve

TypeOK ==
  /\ cgen \in {0, 1}
  /\ visCgen \in {0, 1}
  /\ flag \in {0, 1}
  /\ obs \in {"NONE", "STALE", "FRESH"}
  /\ wWroteCgen \in BOOLEAN
  /\ wPublishedFlag \in BOOLEAN
  /\ rDone \in BOOLEAN

NoStale ==
  obs # "STALE"

Spec ==
  Init /\ [][Next]_vars

=============================================================================
