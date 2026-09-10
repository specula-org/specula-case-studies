# Archived Hook Coverage

[coverage.json](coverage.json) records the final lease-component capture and
replay counts. Paths rooted at the original private run directory are normalized
to run-relative paths. Source/dependency instrumentation copies and build
products are not published in this selected evidence subset.

The canonical traces are [under traces/](../traces/). To replay them, use
[the spec instructions](../spec/README.md). CR-4's independent live-system test
has [separate reproduction instructions](../repro/README.md).

Do not interpret 18/139 model-action occurrence coverage as implementation
coverage. The trace harness does not instrument the operator's quorum decision
or the configuration-change/promotion sequence.
