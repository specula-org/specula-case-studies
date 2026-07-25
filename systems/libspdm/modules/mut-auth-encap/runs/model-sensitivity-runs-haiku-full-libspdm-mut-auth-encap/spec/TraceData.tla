---- MODULE TraceData ----
EXTENDS Naturals, Sequences, Integers

TraceLog == <<
    [
        event |-> "responder_get_encap_request_challenge",
        node |-> "responder",
        tag |-> "trace",
        state |-> [
            buffer_reset_status |-> "success",
            opaque_data_size |-> 0,
            protocol_version |-> 13,
            requester_state |-> "uninitialized",
            responder_state |-> "challenge_sent",
            response_buffer_size |-> 0,
            signature_verified |-> FALSE
        ],
        message |-> [
            version |-> 13
        ]
    ],
    [
        event |-> "requester_get_encap_response_challenge_auth",
        node |-> "requester",
        tag |-> "trace",
        state |-> [
            buffer_reset_status |-> "success",
            opaque_data_size |-> 100,
            protocol_version |-> 13,
            requester_state |-> "challenge_auth_response_received",
            responder_state |-> "challenge_sent",
            response_buffer_size |-> 512,
            signature_verified |-> FALSE,
            transcript_complete |-> TRUE
        ]
    ],
    [
        event |-> "process_encap_response_challenge_auth",
        node |-> "responder",
        tag |-> "trace",
        state |-> [
            buffer_reset_status |-> "success",
            opaque_data_size |-> 100,
            protocol_version |-> 13,
            requester_state |-> "challenge_auth_response_received",
            responder_state |-> "challenge_auth_response_received",
            response_buffer_size |-> 512,
            signature_verified |-> TRUE
        ]
    ],
    [
        event |-> "transition_to_authenticated",
        node |-> "responder",
        tag |-> "trace",
        state |-> [
            buffer_reset_status |-> "success",
            opaque_data_size |-> 100,
            protocol_version |-> 13,
            requester_state |-> "authenticated",
            responder_state |-> "authenticated",
            response_buffer_size |-> 512,
            signature_verified |-> TRUE
        ]
    ],
    [
        event |-> "requester_get_encap_response_challenge_auth",
        node |-> "requester",
        tag |-> "trace",
        state |-> [
            buffer_reset_status |-> "success",
            opaque_data_size |-> -412,
            protocol_version |-> 13,
            requester_state |-> "uninitialized",
            responder_state |-> "challenge_sent",
            response_buffer_size |-> 100,
            signature_verified |-> FALSE
        ]
    ]
>>

====
