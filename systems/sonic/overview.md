# SONiC

## Scope

Specula analyzed and tested SONiC's DPU active-standby HA manager, FDB and bridge-port orchestration, ICCP and MCLAG synchronization, Dual-ToR mux control, and warm-reboot orchestration, including failover, MAC and FDB learning and aging, peer-state synchronization, mux transitions, and multi-component state restoration.

The August 2026 additions are backed by the reviewed [DASH HA run](modules/dash-ha/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/review/independent-review.md) and [ICCPD run](modules/iccpd/runs/sonic-iccpd-vm-codex-gpt56-sol-max-20260801/review/independent-review.md).

## Bugs

Specula found 32 new bugs:

- `DefaultRoute::Wait` satisfies the active-switch gate before the default route is confirmed healthy, allowing a premature transition to Active.
- Active-Active mux control lacks a transition for `(LPWait, MuxError, LinkUp)`, leaving the state machine idle until another heartbeat arrives.
- An oversized pre-authentication ICCP message can write three bytes past the fixed scheduler buffer, creating a remote denial-of-service risk.
- MAC synchronization checks the never-updated stack copy of `age_flag` instead of the persistent entry, causing unconditional chip deletion and software/hardware divergence.
- Heartbeat timeout logic runs during ICCP handshaking even though heartbeat transmission starts only after the session becomes operational, causing false disconnect loops.
- A debug-log format mismatch passes an integer to `%s`, corrupting subsequent arguments and potentially crashing ICCPD.
- MAC aging during a non-`EXCHANGE` state records the local age but never queues or later catches up the peer deletion, leaving a stale remote MAC.
- Full-information resynchronization unconditionally increments the MCLAG state, so invoking it during `EXCHANGE` moves the FSM into an error state with no recovery until disconnect.
- NAK parsing performs typed-pointer arithmetic and reads the status 256 bytes from the header instead of 16 bytes, producing garbage status codes.
- Peers with equal node identifiers increment them symmetrically on every collision and remain equal, preventing the MCLAG handshake from completing.
- Deleting a DPU does not notify registered vDPU actors, allowing stale DPU state to propagate through vDPU, HA-set, and HA-scope decisions.
- Deleting an HA set does not notify registered HA-scope actors, leaving orphaned actors with stale parent state.
- **Fixed:** `HaSetActorState::new_actor_msg` ignores its `up` argument and reports deletion as `up=true` (PR #145).
- Parent cleanup does not cascade deletion notifications from DPU and HA-set actors to their children, leaving stale actors that continue making HA decisions.
- Syncd applies warm-reboot changes to the ASIC and Redis in separate non-atomic stages, while orchagent cannot observe failure and may declare reconciliation complete.
- Warm-restart components reconcile independently without a global dependency barrier, allowing FDB restoration before VXLAN tunnels and causing a traffic blackhole.
- `warmRestartCheck()` can send `READY` before draining newly arrived ring-buffer events, and the shared ring indices and idle flag are non-atomic, allowing events to be lost across reboot.
- Neighsyncd starts its five-second reconciliation timer before requesting the netlink dump, so a slow dump can delete valid but not-yet-replayed neighbors as stale.
- A failure after syncd's destructive warm-reboot stage has no automatic cold-restart fallback, leaving orchagent in a restart loop until manual recovery.
- A crash after a durable NPU delete but before the queued DPU delete loses the downstream deletion, leaving the DPU HA scope active after restart.
- `DesiredHaState::Unspecified` is enforced as standby on the DPU but persisted as unspecified in `STATE_DB`, exposing inconsistent controller state.
- ICCPD increments its descriptor count for every new socket but never decrements it on disconnect, causing unbounded per-loop stack allocation across reconnects.
- The local-kernel NDISC update path compares the stored IPv6 address with itself and returns before propagating changed neighbor metadata.
- Active-Active initialization can publish Healthy before receiving current hardware-session Up evidence and can consequently authorize a peer Standby command.
- An untagged delayed mux-probe response can overwrite a newer completed intent and temporarily publish an Unhealthy state.
- Canceling a hardware positive-probing timer still runs its callback because the error code is discarded, allowing it to publish Active after the link goes Down.
- Logical HA scope state can redirect traffic before the matching ASIC acknowledgement, installing a vDPU route while the hardware role is still dead.
- A delayed old peer-state request can regress an already accepted HA term and persist the older term to DPU_APPL_DB.
- A delayed former-peer message can contaminate a newly paired HA scope and trigger a vote using foreign state.
- Restart rehydration can create two actionable pending-operation UUIDs for one asserted DPU flag and issue duplicate activation commands.
- A crash after peer socket teardown but before disconnect cleanup can permanently skip failover cleanup, leaving State DB and the CLI reporting the dead peer as up.
- Partial ICCP frames and unsupported APP traffic can block protocol progress in the single scheduler, while mclagsyncd EOF can leave a stale descriptor that suppresses reconnect.

Specula also found 9 previously known bugs:

- **Open:** Peer mux state is not reset across a link Down-to-Up transition, so initialization can treat stale pre-restart state as healthy (Issue #285).
- **Open:** Local health recovery does not re-evaluate stale peer mux state, allowing asymmetric failure handling to leave both ToRs in Standby (Issues #143 and #285).
- **Open:** Non-FIFO `strand::wrap` dispatch can process a stale link-prober Unknown event after a fresh Active event and spuriously switch a healthy mux to Standby (Issues #104 and #254).
- **Open:** VLAN FDB flush does not mark entries as pending, so the completion notification skips them and leaves phantom FDB state (Issue #4428).
- **Open:** Bridge-port removal deletes the OID mapping before asynchronous FDB flush events arrive, causing those events to be dropped and producing a long-lived traffic blackhole.
- **Open:** ICCPD clears the warm-reboot disconnection timestamp immediately after setting it, so the 90-second cleanup timeout never fires (PR #7724).
- **Open:** A stale or canceled warm-restart reconciliation callback can overwrite a newer Active or Manual mux-mode configuration with Auto (Issue #25612).
- **Open:** A late DPU acknowledgement can regress an Active scope's acknowledged ASIC role and republish the stale role to the peer (Issue #171).
- **Open:** Vote completion can reset an in-progress switchover retry budget and allow an extra retry beyond the configured limit (PR #145 review).
