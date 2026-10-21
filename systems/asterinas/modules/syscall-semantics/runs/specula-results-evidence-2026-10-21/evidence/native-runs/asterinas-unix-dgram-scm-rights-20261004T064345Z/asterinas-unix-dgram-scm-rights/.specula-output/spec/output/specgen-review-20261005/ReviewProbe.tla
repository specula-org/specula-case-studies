---- MODULE ReviewProbe ----
EXTENDS Trace
ValidFile == "valid.ndjson"
BadSourceFile == "bad-source.ndjson"
UnknownEventFile == "unknown-event.ndjson"
TruncatedFile == "truncated.ndjson"
CorruptedPostFile == "corrupted-post.ndjson"
OverlapFile == "overlap.ndjson"
CompleteMatchExists == ~(ThreadsWithEvents = {})
====
