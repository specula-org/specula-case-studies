# libspdm

## Scope

Specula analyzed and tested libspdm's SPDM requester-responder protocol across opening negotiation, certificate and PSK authentication, key exchange, mutual authentication, measurements and extension logs, event delivery, chunking, secured messages, and session establishment, update, and teardown.

## Bugs

Specula found 31 new bugs:

- On an unprotected transport, cleartext MEL responses have no integrity protection, allowing an intermediary to substitute equal-length log data undetectably.
- Encapsulated-request error paths restore the normal response state without clearing the current request opcode, leaving partially reset authentication context.
- **Approved:** Encapsulated `SEND_EVENT` handling omits the version and `EVENT_CAP` checks used by the non-encapsulated path, allowing event processing on unsupported connections.
- **Approved:** Event acknowledgments do not verify the session's subscription state, allowing delivery through stale or cross-session subscriptions.
- A subscription is committed to the HAL before its acknowledgment is sent, allowing events to reach a requester that does not yet know the subscription succeeded.
- **Approved:** GET-path chunking never records the large-message capacity, so cleanup zeroes zero bytes and leaves sensitive chunk buffers unscrubbed.
- A failed `GET_CAPABILITIES` response append leaves the request orphaned in `message_a`, corrupting the transcript used by later key exchange.
- **Approved:** Retrying `GET_CERTIFICATE` does not reset `message_b`, so stale certificate transcript data can invalidate a later challenge signature.
- **Approved:** One `GET_MEASUREMENTS` validation failure returns without resetting `message_m`, allowing stale transcript data to corrupt later measurement signatures.
- Failed or abandoned `KEY_EXCHANGE`/`FINISH` handshakes do not free their sessions, allowing incomplete handshakes to occupy every session slot.
- Responder capability flags are sent without the compatibility validation applied to requester flags, leaving the endpoints in inconsistent protocol states.
- **Approved:** Session-key update overwrites the live secret before establishing a valid backup, so a later derivation failure can destroy both the old and recoverable keys.
- Measurement-summary hash sizing ignores `MEL_CAP` when `MEAS_CAP` is absent, preventing a MEL-only responder from binding its log into signed authentication responses.
- **Approved:** Algorithm negotiation writes selections into connection state before validation and does not roll them back on error, contaminating a retry with failed-attempt values.
- Algorithm negotiation sets a nonzero base asymmetric algorithm even when no enabled capability requires one, producing an incoherent negotiated state.
- Challenge handling marks the connection authenticated before encapsulated authentication finishes and does not roll the state back if that flow fails.
- MEL exchanges are absent from the signed transcript and carry no signature, nonce, or requester context, leaving a consumed log unbound to the responder or session.
- `mel_spec` validation is skipped for measurement-only profiles without key-exchange or PSK capability, allowing an unrecognized wire value into negotiated state.
- An out-of-sequence `CHUNK_SEND_ACK` records an error but still copies the chunk into the reassembly buffer before returning it.
- The with-context PSK exchange enters `HANDSHAKING` without arming the watchdog used by the without-context path, leaving incomplete sessions dangling.
- The requester sends `GET_MEASUREMENT_EXTENSION_LOG` without checking for a negotiated nonzero `mel_spec`, provoking an avoidable protocol error.
- **Approved:** Cross-chunk MEL validation detects only a shrinking total, not same-length content changes or an increased total, so inconsistent multi-chunk logs can pass silently.
- The requester reads `mel_entries_len` before confirming that the first accumulated MEL chunk contains the complete 16-byte header.
- **Approved:** The responder activates its new `UPDATE_ALL_KEYS` response key before sending the acknowledgment, so acknowledgment loss permanently desynchronizes the endpoints.
- **Approved:** Retrying `FINISH` does not reset the responder's `message_f`, causing the retry HMAC to include stale transcript data and fail repeatedly.
- **Approved:** The responder performs a full MEL HAL collection for every request instead of caching a per-conversation snapshot, adding avoidable work for expensive HALs.
- **Approved:** The responder regenerates the MEL for each response chunk, so a concurrent log extension can produce a stitched result that never existed as one snapshot.
- **Approved:** Freeing a session does not remove its HAL event subscriptions, allowing a reused session identifier to inherit stale subscriptions.
- **Approved:** `SUBSCRIBE_EVENT_TYPES` does not check requested types against the responder's advertised set, so unsupported subscriptions are accepted.
- **Approved:** The unsigned `GET_MEASUREMENTS` size check omits the nonce length, allowing a short response to trigger a 32-byte heap-buffer over-read.
- **Approved:** If the second half of `UPDATE_ALL_KEYS` creation fails, the first direction is not rolled back, leaving the requester-direction key one generation ahead.

Specula also found 1 previously known bug:

- **Open:** The requester does not validate the chunk handle in `CHUNK_RESPONSE`, allowing a malicious responder to supply wrong-handle data for reassembly (Issue #3598).
