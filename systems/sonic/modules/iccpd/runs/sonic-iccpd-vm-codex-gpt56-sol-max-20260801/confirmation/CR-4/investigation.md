# CR-4 Phase 1 investigation

Evidence record only; no Phase 2 verdict is made here.

## Finding metadata

- Source: Code Review (the supplied finding states that no model-checking violation represents this mechanism).
- Candidate location: `src/iccpd/src/scheduler.c:129` (peer receive callback), with related sites at `src/iccpd/src/iccp_netlink.c:2212-2235`, `src/iccpd/src/app_csm.c:100-151`, `src/iccpd/src/mlacp_link_handler.c:3350-3582`, and `src/iccpd/src/scheduler.c:469-492` in clean commit `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9`.
- Novelty evidence: NEW. The searches and precedent comparison are recorded below.

## Step 1: code audit

### Scheduler and peer receive path

The normal daemon path is:

1. `main()` obtains the singleton `System`, initializes epoll and the listener, then calls `scheduler_init()` and `scheduler_start()` (`src/iccpd/src/iccp_main.c:203-266`; `src/iccpd/src/system.c:38-92`).
2. A domain delivered through the normal mclagsyncd socket is handled by `iccp_mclagsyncd_mclag_domain_cfg_handler()`, which creates the CSM and installs its local address, peer address, and session timeout (`src/iccpd/src/mlacp_link_handler.c:3064-3127`). The static-file configuration path reaches the same setters through `iccp_config_from_file()` (`src/iccpd/src/iccp_cmd.c:75-185`).
3. A peer connection is either made by `session_client_conn_handler()` or accepted by `scheduler_server_accept()`. Both add the TCP fd to the single epoll instance with `EPOLLIN`; neither makes the fd nonblocking nor installs a receive timeout (`src/iccpd/src/scheduler.c:267-354,569-654`).
4. `scheduler_loop()` calls `iccp_handle_events()` and only after it returns calls `scheduler_transit_fsm()` (`src/iccpd/src/scheduler.c:474-492`). The latter performs heartbeat expiry and all ICCP, APP, and mLACP FSM transitions (`src/iccpd/src/scheduler.c:75-127`).
5. `iccp_handle_events()` dispatches a readable peer fd synchronously to `scheduler_csm_read_callback()` on that same thread (`src/iccpd/src/iccp_netlink.c:2169-2245`).

The first read loop requests the eight-byte `LDPHdr` using blocking `recv(..., 0)` until all eight bytes arrive (`src/iccpd/src/scheduler.c:130-169`; `sizeof(LDPHdr) == 8` from `src/iccpd/include/msg_format.h:251-264`). Once any prefix has arrived, a delayed remainder leaves the sole scheduler inside the next `recv()` with no timeout. Consequently, heartbeat expiry, protocol FSMs, the signal pipe, netlink, the control socket, and mclagsyncd events cannot be serviced until more peer bytes arrive or TCP reports an error/EOF.

The body path uses `MSG_DONTWAIT`, but handles `EAGAIN` by sleeping on the same scheduler thread (`src/iccpd/src/scheduler.c:185-238`). Retries 1 through 9 sleep for 0.1 through 0.9 seconds; retry 10 sleeps for `session_timeout - 4.5s`, and retry 11 disconnects. Thus a default session blocks the event loop for roughly its entire timeout. A configured three-second timeout is reachable through the public MCLAG schema (`src/sonic-yang-models/yang-models/sonic-mclag.yang:73-95`, keepalive 1 and timeout 3 satisfy the constraint), but makes the retry-10 expression negative and passes the converted value to `usleep()`, extending the stall far beyond the configured timeout.

Concrete peer trigger: configure a normal MCLAG domain, connect from its configured peer IP, then deliver either (a) one to seven bytes of the header and delay the rest, or (b) a complete header declaring a body followed by only a body prefix. TCP can expose either prefix to the receiver through ordinary stream fragmentation or a network interruption. A normal peer connection and the daemon's real epoll entry point reach the cited loops; no inconsistent in-memory state is required.

Safeguards found: `epoll_wait()` itself has a 100 ms timeout, but that does not apply after the handler begins. The body path eventually disconnects after retries when the timeout arithmetic remains positive; the header path has no corresponding bound. Closing/resetting the peer releases the blocked header read, but no independent timer or thread releases it while the connection remains open.

### Transport activity versus protocol progress

After any complete frame, `iccp_handle_events()` calls `mlacp_fsm_update_heartbeat()` solely on the receive callback's success return, before examining whether the frame advances a protocol FSM (`src/iccpd/src/iccp_netlink.c:2231-2235`). That helper unconditionally assigns the current time (`src/iccpd/src/mlacp_sync_update.c:1330-1337`).

For an ICC RG APP DATA frame with a syntactically encoded but unsupported application parameter, `iccp_csm_enqueue_msg()` delegates to `app_csm_enqueue_msg()`; the latter places parameters outside the mLACP range on `app_msg_list` (`src/iccpd/src/iccp_csm.c:722-769`; `src/iccpd/src/app_csm.c:100-151`). Repository-wide call search found no caller of `app_csm_dequeue_msg()` outside its own definition, so such frames do not advance ICCP/mLACP synchronization and remain queued. Nevertheless, each complete frame refreshes heartbeat time.

Concrete activity trigger: after a configured peer is accepted, send complete ICC RG APP DATA frames containing an unknown parameter with its U-bit set, at intervals below `session_timeout`, without sending the capability/RG-connect/mLACP synchronization sequence. These frames pass the daemon's normal framing path but do not advance the connection or mLACP FSM. Because `csm->sock_fd` remains positive, `scheduler_server_accept()` rejects a replacement peer connection as already connected (`src/iccpd/src/scheduler.c:301-305`). Stopping the traffic permits heartbeat expiry; continuing it can hold the non-progressing connection indefinitely.

Safeguards found: `mclagdctl dump state` reports ICCP keepalive as OK only in `ICCP_OPERATIONAL` and reports sync complete only in `MLACP_STATE_EXCHANGE` (`src/iccpd/src/iccp_cmd_show.c:64-76`), so the status CLI can expose incomplete synchronization. It does not close the socket or stop unsupported traffic from refreshing `heartbeat_update_time`. There is no APP-queue consumer or progress-qualified heartbeat guard.

### mclagsyncd EOF and reconnect path

`scheduler_init()` calls `iccp_connect_syncd()`, which connects to `127.0.0.6:2626`, stores the positive fd in `sys->sync_fd`, and adds it to epoll (`src/iccpd/src/mlacp_link_handler.c:2568-2632`). In the loop, reconnect is attempted only when `sys->sync_fd <= 0` (`src/iccpd/src/scheduler.c:474-487`).

On `EPOLLIN`, `iccp_handle_events()` calls `iccp_mclagsyncd_msg_handler(sys)` and discards its return (`src/iccpd/src/iccp_netlink.c:2212-2216`). The handler explicitly recognizes `recv() == 0` as a closed socket but merely returns `MCLAG_ERROR`; it neither closes the fd nor assigns `-1` (`src/iccpd/src/mlacp_link_handler.c:3350-3376`). `syncd_info_close()` would do both, but is used during finalization rather than this error path (`src/iccpd/src/mlacp_link_handler.c:2635-2649`). The positive stale fd therefore suppresses both the scheduler's reconnect condition and `iccp_connect_syncd()` itself, whose `sync_fd >= 0` guard returns immediately.

Concrete EOF trigger: start iccpd with a normal mclagsyncd listener, accept its connection, terminate that mclagsyncd connection, and bring a listener back on the same address. TCP EOF is a normal process-restart outcome. The old fd remains level-readable at EOF and the replacement listener receives no reconnect.

Safeguards found: the production wrapper starts `mclagsyncd` in the background and `iccpd` in the foreground (`dockers/docker-iccpd/iccpd.sh:5-18`); it does not wait for or restart mclagsyncd independently. Supervisord sets `autorestart=false` for that wrapper (`dockers/docker-iccpd/supervisord.conf:39-49`). Thus the deployment scripts do not automatically restart iccpd when only mclagsyncd exits.

## Step 2: developer-knowledge evidence

- `git blame` assigns the original blocking header loop to the initial MCLAG implementation commit `524cf9e56ad5daa6f5a110dd50fc9af3e3ef0468` (PR #2514).
- Commit `82b6bcfbb3f0306763850fc343ec9f6d100dc4a2` (PR #4819) added the body `MSG_DONTWAIT` retry logic, the mclagsyncd receive handler, and the unconditional post-frame heartbeat update. The comment at `src/iccpd/src/scheduler.c:187-191` says: "When consecutive CCP session flaps happen, recv() call got stuck" and describes waiting one keepalive interval before bringing down the session. This records intent to bound the body read, but the implementation still sleeps on the only scheduler thread and leaves the header blocking.
- The comment at `src/iccpd/src/iccp_netlink.c:2233` says: "consider any msg from peer as heartbeat update, this will be in scenarios of scaled msg sync b/w peers". This is direct evidence that counting all complete transport frames was deliberate to tolerate lengthy legitimate synchronization; it does not state that unsupported traffic should reserve a session forever.
- The EOF branch comment at `src/iccpd/src/mlacp_link_handler.c:3371` recognizes that a zero-byte receive means the socket is closed. No adjacent TODO, design note, or test states that retaining the positive fd is intended.
- PR #4819's review discussion explicitly noted the absence of ICCPd unit tests; the author replied that there was no test component running within the ICCPd container. Repository search found no existing test for fragmented peer frames, progress-qualified heartbeat expiry, or mclagsyncd EOF/reconnect.
- Production scripts provide no downstream restart safeguard for an isolated mclagsyncd exit, as recorded in the Step-1 audit.

References: https://github.com/sonic-net/sonic-buildimage/pull/2514, https://github.com/sonic-net/sonic-buildimage/pull/4819, and https://github.com/sonic-net/sonic-buildimage/pull/4819#issuecomment-813540632.

## Step 3: known-status and precedent search

Search date: 2026-08-01 UTC.

The upstream GitHub issue/PR search covered open issues, open PRs, closed PRs, and recently closed/updated PRs. Queries included the exact function name and combinations of `iccpd`, `recv stuck`, `fragmented header`, `heartbeat timeout`, `mclagsyncd`, `reconnect`, `socket`, and `Connection lost`. Exact-mechanism searches for `scheduler_csm_read_callback`, stuck receive, fragmented header, and heartbeat timeout returned no report. The set of closed ICCPd PRs since 2025 was also enumerated; none concerns these sites or this mechanism.

Two precedents were re-checked and do not meet the same-site/same-mechanism bar:

- PR #4819 introduced the cited logic as part of a broad MCLAG enhancement. A discussion reported mclagsyncd losing its connection while its own receive queue remained nonempty and points to `sonic-swss` PR #1832. That is the opposite endpoint and a different receive site; it does not report iccpd retaining `sys->sync_fd` after EOF, the peer header blocking the scheduler, or unsupported APP traffic refreshing heartbeat.
- Issue #6640 reports initial `ECONNREFUSED` while mclagsyncd is not listening. It does not involve EOF after a successful connection or the stale-positive-fd reconnect suppression.

The current upstream `master` checked by `git ls-remote` was `777500986a7cfc57e48943b803e08b5643af1082`; raw source at that revision still has the blocking peer-header read, unconditional post-frame heartbeat refresh, ignored mclagsyncd-handler return, EOF return without fd reset, and `sync_fd <= 0` reconnect guard. Per-file upstream commit history shows no newer commit touching `scheduler.c` or `iccp_netlink.c` after 2023, and no relevant later change to `mlacp_link_handler.c`.

References: https://github.com/sonic-net/sonic-buildimage/pull/4819, https://github.com/sonic-net/sonic-swss/pull/1832, https://github.com/sonic-net/sonic-buildimage/issues/6640, and the recent PR search result set headed by https://github.com/sonic-net/sonic-buildimage/pulls?q=is%3Apr+iccpd.

Known-status record: `Novelty: NEW` because no tracker entry reports this exact mechanism at these sites. PR #4819 supplies developer-awareness evidence, not an existing exact defect report. The code-review duplicate pre-filter therefore does not apply, and Phase 2 is required.
