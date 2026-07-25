---- MODULE TraceData ----

\* Baseline trace for libspdm-events trace validation

Trace_baseline_json ==
<<
  [tag |-> "trace", event |-> "INIT_SESSION", timestamp |-> 1, sid |-> 1, state |-> [session_state |-> "ESTABLISHED"], body |-> [empty |-> TRUE]],
  [tag |-> "trace", event |-> "SUBSCRIBE_EVENT_TYPES", timestamp |-> 2, sid |-> 1, state |-> [session_state |-> "ESTABLISHED"], body |-> [event_types |-> <<1,2,3>>]],
  [tag |-> "trace", event |-> "SUBSCRIBE_EVENT_TYPES_ACK", timestamp |-> 3, sid |-> 1, state |-> [session_state |-> "ESTABLISHED"], body |-> [empty |-> TRUE]],
  [tag |-> "trace", event |-> "SEND_EVENT_ACK", timestamp |-> 4, sid |-> 1, state |-> [session_state |-> "ESTABLISHED", events_sequential |-> TRUE, msg_size_accum |-> 100, event_validated_count |-> 2], body |-> [is_sequential |-> TRUE, event_list |-> <<[detail_len |-> 50]>>]],
  [tag |-> "trace", event |-> "SEND_EVENT_ACK", timestamp |-> 5, sid |-> 1, state |-> [session_state |-> "ESTABLISHED", events_sequential |-> FALSE, msg_size_accum |-> 150, event_validated_count |-> 3], body |-> [is_sequential |-> FALSE, event_list |-> <<[detail_len |-> 50], [detail_len |-> 100]>>]],
  [tag |-> "trace", event |-> "HANDLE_EVENT_ACK", timestamp |-> 6, sid |-> 1, state |-> [session_state |-> "ESTABLISHED"], body |-> [event_count |-> 3]]
>>

====
