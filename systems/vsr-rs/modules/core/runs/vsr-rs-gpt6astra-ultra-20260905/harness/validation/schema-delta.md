# Mandatory trace tag alignment

The installed harness-generation skill requires every event line to carry
"tag":"trace". The supplied Trace.tla selected "tag":"vsr" instead.

The only changes to the supplied specification are:
- Trace.tla: the Tagged selector now selects e.tag="trace".
- instrumentation-spec.md: its tag description and Init example use "trace".

The flat event string and full required state/applies schema are retained.
No base action, normalization, branch, post-state check, invariant, fairness
assumption, or TraceMatched condition was changed. base.tla and Trace.cfg are
byte-identical to the supplied files.

Old model-generated fixtures under spec/checks retain their original provenance
and old tag. They are not imported, transformed, or treated as implementation
evidence by this harness. New negative controls are copies of actual Rust traces
with explicitly documented corruptions and remain under harness/validation.
