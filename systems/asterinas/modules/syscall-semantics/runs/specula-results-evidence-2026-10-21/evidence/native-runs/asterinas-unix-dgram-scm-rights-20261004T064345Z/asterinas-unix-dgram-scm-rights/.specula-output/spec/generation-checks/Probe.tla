---- MODULE Probe ----
EXTENDS Trace
ValidFile == "generation-checks/valid.ndjson"
BadSourceFile == "generation-checks/bad-source.ndjson"
UnknownEventFile == "generation-checks/unknown-event.ndjson"
TruncatedFile == "generation-checks/truncated.ndjson"
CorruptedPostFile == "generation-checks/corrupted-post.ndjson"
MalformedMetadataFile == "generation-checks/malformed-metadata.ndjson"
NonmonotonicFile == "generation-checks/nonmonotonic.ndjson"
====
