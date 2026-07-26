# spdm-rs

## Scope

Specula analyzed and tested spdm-rs's SPDM handshake, capability and algorithm negotiation, certificate- and PSK-based authentication, multi-session allocation and teardown, key updates, unexpected-request dispatch, mutual authentication through encapsulated requests, and chunked message reassembly.

## Bugs

Specula found 10 new bugs:

- Chunk reassembly uses one global context without a session ID, allowing chunks from different sessions to enter the same reassembly buffer.
- If requester-side data-secret generation fails after the responder commits FINISH, the responder remains established while the requester tears down, with no recovery notification.
- **Approved:** Heartbeat and key-update handlers process requests without checking whether the corresponding capabilities were negotiated.
- **Approved:** With mandatory mutual authentication enabled, `mut_auth_done` is never set and FINISH silently tears down the session without an error response.
- **Approved:** The requester's post-quantum signature priority table lists the weakest ML-DSA option first, causing negotiation to prefer it.
- **Approved:** The requester accepts an ALGORITHMS response without verifying that the selected algorithm was among those it offered.
- **Approved:** The responder can establish a PSK session without checking whether PSK capability was negotiated.
- **Approved:** The responder discards key-derivation failures during KEY_UPDATE and still sends an acknowledgement, permanently desynchronizing the peers' keys.
- **Approved:** Session setup panics when a slot is occupied, and both responder call sites unwrap the result, allowing a remote request to crash the process.
- **Approved:** Session reset omits transcript hashes and backup-key flags, allowing stale state to survive teardown, slot reuse, and GET_VERSION reset.
