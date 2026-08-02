# MC-2 Phase 1 investigation

Evidence only; no Phase 1 verdict is made.

## Step 1: code audit

### Cited sites and behavior

- `src/iccpd/src/mlacp_fsm.c:1544-1576`: `mlacp_exchange_handler()` processes any received RG Application Data and, independently, sends a full synchronization request whenever `need_to_sync` is nonzero. It clears only `need_to_sync`; it neither tests nor sets `wait_for_sync_data`, and it records no outstanding request.
- `src/iccpd/src/mlacp_sync_prepare.c:49-99`: every `mlacp_prepare_for_sync_request_tlv()` call writes `tlv->req_num = 0` and also resets `MLACP(csm).sync_req_num = 0`.
- `src/iccpd/src/mlacp_sync_prepare.c:105-147`: Sync Start/End creation copies the single mutable `MLACP(csm).sync_req_num` into the response.
- `src/iccpd/src/mlacp_fsm.c:538-555`: Sync Start/End receipt checks only `flags`; it never reads or validates `syncdata->req_num`. Any End clears `wait_for_sync_data`.
- `src/iccpd/src/mlacp_fsm.c:557-572`: receipt of any Sync Request overwrites the same `sync_req_num` field and immediately calls the full-response sender.
- `src/iccpd/src/mlacp_fsm.c:1438-1463`: the response is emitted synchronously as Start, data TLVs, and End. The helper also increments `current_state`; when called from established `EXCHANGE`, this moves the responder to `MLACP_STATE_ERROR`. This is a separate production behavior that reproduction must not mistake for MC-2's correlation defect.
- `src/iccpd/src/mlacp_fsm.c:1497-1517`: initial Stage 1/2 synchronization does serialize on `wait_for_sync_data`. The established resync path above does not reuse that guard.
- `src/iccpd/include/mlacp_fsm.h:151-160`: there is only one `sync_req_num`, one `wait_for_sync_data`, and one edge-triggered `need_to_sync`; there is no per-request/envelope state.

### Real call chain and reachability

The normal daemon scheduler calls `scheduler_transit_fsm()` (`src/iccpd/src/scheduler.c:103-118`), then `mlacp_fsm_transit()` (`src/iccpd/src/mlacp_fsm.c:921-1041`), which dequeues normally received mLACP messages and calls `mlacp_exchange_handler()` in `MLACP_STATE_EXCHANGE`.

Two ordinary incoming NAKs can produce the counterexample precondition. `app_csm_enqueue_msg()` routes a NAK for an mLACP application message into the mLACP queue (`src/iccpd/src/app_csm.c:129-145`); `mlacp_sync_recv_nak_handler()` sets `need_to_sync = 1` for rejected non-System-Config TLVs (`src/iccpd/src/mlacp_fsm.c:1246-1287`). One scheduler pass sends request 1. A second NAK before response 1 arrives sets the bit again, and the next pass sends request 2 because the established path has no outstanding-request guard. A received purge for an unknown Aggregator is another normal producer at `src/iccpd/src/mlacp_sync_update.c:103-123`.

The supplied real counterexample follows the same admissible ordering in `spec/output/MC_hunt_scenario2_bfs_validated.out`: State 2 (line 177) prepares n1 resync epoch 1; State 4 (line 465) prepares n1 resync epoch 2 while epoch 1 remains in flight; State 9 (line 1212) delivers the epoch-1 Sync Start to n1; State 10 (line 1363) records `outstanding |-> 2`, `activeEnvelope |-> 1`, and `envelopeViolation |-> TRUE`. TLC reports `MCSyncEnvelopeOrdering` violated at line 38.

### Consumers and safeguards to exercise in Phase 2

- A System Config response is consumed by `mlacp_fsm_update_system_conf()` (`src/iccpd/src/mlacp_sync_update.c:45-79`), which overwrites `remote_system`; on a standby, an ID change is sent to the real `mclagsyncd` consumer by `mlacp_link_set_iccp_system_id()` at line 76.
- TCP preserves byte order in each direction, and `mlacp_sync_send_all_info_handler()` emits a response synchronously. If both requests are processed, the first full response must precede the second full response and the latter can overwrite the former. Phase 2 must prove whether that downstream replay occurs rather than assume it.
- The established responder's `current_state++` noted above may instead prevent request 2 from being serviced. Because that failure is independently present with a single established resync, Phase 2 must identify it separately when matching the MC-2 root cause.
- A changed responder System ID used by the consequence control is reachable without fabrication: `scheduler.c:519-535` observes the normal port-channel MAC, copies a changed value to `MLACP(csm).system_id`, and raises `system_config_changed`. The test must retain that flag when injecting the corresponding post-response snapshot state.
- The receiver does not implement an envelope guard: data TLVs are accepted whether they occur before Start, between a matching Start/End, or under a mismatched request number.

## Step 2: developer-knowledge search

### Protocol/design evidence

The source structures cite RFC 7275 sections 7.2.9 and 7.2.10 (`src/iccpd/include/mlacp_tlv.h:246-304`). RFC 7275 says in section 7.2.9 that the request number uniquely identifies a solicited request, that zero is reserved for unsolicited synchronization, and that zero must not appear in a Synchronization Request. Section 7.2.10 says Start/End delimit a response and associate it with the request through that number. Section 9.2.2.3 requires the Start, data, End ordering and discusses pending synchronization requests. Source: https://www.rfc-editor.org/rfc/rfc7275.html#section-7.2.9 and https://www.rfc-editor.org/rfc/rfc7275.html#section-7.2.10.

`git blame` attributes the request-number assignments, response preparation, Sync Data receiver, and established exchange path to commit `524cf9e56ad5daa6f5a110dd50fc9af3e3ef0468` (2020-04-05), the original "MCLAG feature for SONIC" import in PR #2514. The PR says only that the feature was implemented according to the MCLAG HLD and compiled/tested in a lab; it does not describe request-number reuse, concurrent resync, or tolerance of uncorrelated envelopes. Source: https://github.com/sonic-net/sonic-buildimage/pull/2514.

There are no nearby TODO/FIXME/by-design comments about request correlation. The only comments label request creation, response Start/End, and waiting during initial staging. No existing `src/iccpd` test tree or assertion covering two established resyncs was found.

### History and tracker searches performed

- `git log -S'tlv->req_num = 0'` and `git log -S'need_to_sync != 0'` find only the 2020 MCLAG import for the relevant mechanism.
- The GitHub issue/PR search API was queried across all states and comments for `sync_req_num`, `mlacp_prepare_for_sync_request_tlv`, `iccpd resync`, `iccpd "sync request"`, and `mLACP synchronization` in `sonic-net/sonic-buildimage`; each exact-mechanism query returned `total_count=0` on 2026-08-01.
- The broader closed/open PR search for `iccpd sync` returned seven PRs. The potentially relevant initial import #2514 contains no report of this mechanism. PR #8794 is an unrelated standby interface admin-state bug; PR #26567 is an unrelated bounds-validation fix. The remaining titles concern telemetry, Podman, mclagdctl peer-link display, a standby interface state bug, and LACP transmission.
- To include recent merged work, `origin/master` was refreshed to `777500986a7cfc57e48943b803e08b5643af1082`. No commit after the checkout's `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9` touches `src/iccpd`; the last commit touching either target file is unrelated PR #26567 on 2026-04-21, and it changes bounds checks rather than synchronization correlation.

## Step 3: known-status / precedent

**Novelty evidence: NEW.** The required open/closed issue and PR searches, recent upstream refresh, target-file history, and original import PR reveal no prior report of the same uncorrelated, non-serialized synchronization transaction at these sites. Same-area PRs found by the broader search concern different mechanisms.

This finding is MC-sourced because the supplied TLC output contains an actual `MCSyncEnvelopeOrdering` violation trace. It therefore proceeds to Phase 2 regardless of known status.
