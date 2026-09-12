--------------------- MODULE SyntheticTraceControls ---------------------
EXTENDS Trace
SyntheticEvidence(e) ==
  /\ EnvelopeFields \subseteq DOMAIN e
  /\ e.schemaVersion = 1 /\ e.tag = "trace"
  /\ {"sourceRevision","basis","complete","ordering","artifact"} \subseteq DOMAIN e.evidence
  /\ e.evidence.sourceRevision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
  /\ e.evidence.basis = "synthetic-specification-control" /\ e.evidence.complete = TRUE
  /\ e.evidence.ordering = "lease-and-transaction"
  /\ e.evidence.artifact \in STRING /\ e.evidence.artifact # ""
=============================================================================
