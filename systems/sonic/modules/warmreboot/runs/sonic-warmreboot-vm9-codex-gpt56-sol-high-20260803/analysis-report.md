# Code Analysis Report: SONiC Warm Reboot

## Audit Identity and Scope

| Field | Value |
|---|---|
| System | `warmreboot` in `sonic-net/sonic-buildimage` |
| Repository | `/users/Pial/targets/sonic-buildimage-warmreboot-high` |
| Analyzed commit | `9914efc028c3835c564eb0c6028a019991b5c422` |
| Primary language | C++ with Python/shell orchestration dependencies |
| Analysis date | 2026-08-03 UTC |
| Method | Specula code-analysis, Phases 1–4 |
| Classification | Category A: distributed/message-passing; not Byzantine |
| Primary deliverable | `modeling-brief.md` |

The primary source scope is the complete C++ `src/sonic-sysmgr/rebootbackend` implementation and tests. The end-to-end correctness boundary necessarily also includes the warmboot finalizer, the pinned `fast-reboot` script, the pinned host reboot service, persistent Redis/snapshot state, systemd service ordering, and per-ASIC namespaces. Generated artifacts, build glue, platform implementations, and SAI internals were inspected only where tracker or code evidence made them relevant.

The target checkout remained unmodified. The two report files are outside that repository in the requested Specula output directory.

## Executive Findings

The C++ backend is not the owner of an atomic reboot transaction. It records request ownership only in memory, hands the request to a host service that keeps a second volatile record, and infers successful cold/warm completion from its own process disappearing. Backend crash/recovery and local timeout are therefore distinct from host-side command completion, but the implementation has no durable correlation ID or reconciliation protocol between them.

The warm-reboot script then coordinates a distributed cut across service processes and Redis namespaces. Before its commit point it has some rollback cleanup; after that point it disables traps, enables `set +e`, and proceeds through service stop, snapshot, kernel, and reboot operations even if individual commands fail. The database backup is also multi-step: selected state is pruned before the Redis file is copied.

Restoration and finalization use persistent warm flags without a reboot epoch. The finalizer waits for a dynamically assembled component set, but on deadline it logs the incomplete state, clears warm state, and saves the database anyway. Tracker history confirms that late consumers, asynchronous database propagation, stale flags, and incomplete reconciliation have crossed these boundaries in real systems.

The highest-value formal questions are consequently distributed ownership, epoch consistency, causal quiescence, finalization safety, and multi-namespace snapshot coherence. Concrete local C++ defects—thread-launch wedging, transport/rejection conflation, a blocking D-Bus phase outside the timer, and path-specific delay behavior—belong primarily in deterministic and fault-injection tests.

## Phase 1 — Repository Reconnaissance

### Repository and instruction state

- Git status was clean at the beginning of analysis.
- No applicable `AGENTS.md` or target-specific `.prompt-extra.md` was present.
- Relevant submodules were recorded but uninitialized in this checkout:
  - `sonic-host-services@233cd591c324d4090a077f87da0eaaad7d12cabc`
  - `sonic-utilities@b17c48270c15fc6d5c81a23d97e2946cd7059dcd`
  - `sonic-swss-common@6acbb00…`
  - `gnoi-system@2b6ff72de5769839fc68bd019f345a184e3b0bf1`
- Exact pinned host/utility/API sources were therefore read from their public raw GitHub revisions without mutating or initializing the checkout.

### Primary source inventory

The complete production C++ implementation contains 1,093 lines:

| File group | Lines read | Role |
|---|---:|---|
| `interfaces.cpp` | 71 | D-Bus adapter and error conversion |
| `reboot_thread.cpp` | 315 | Request validation, worker, timer, status transitions |
| `rebootbackend.cpp` | 10 | Process entry point |
| C++ headers | 377 | State, synchronization, interfaces, event wiring |
| `rebootbe.cpp` | 320 | Redis/gNOI request loop and manager state |

All 953 C++ test lines were read:

| Test | Lines read | Coverage role |
|---|---:|---|
| `reboot_thread_test.cpp` | 391 | Thread status, start/stop/join, timeout paths |
| `rebootbe_test.cpp` | 562 | Request/status event-loop behavior and mocked D-Bus |

Supporting end-to-end sources read in full:

- `files/image_config/warmboot-finalizer/finalize-warmboot.sh` — 310 lines.
- `sonic-host-services@233cd591…/host_modules/reboot.py` — 255 lines.
- `sonic-utilities@b17c4827…/scripts/fast-reboot` — 1,290 lines.
- Relevant warmboot service-order manifests and `check_system_warm_boot` logic.

### Category decision

This is Category A. The correctness boundary consists of independently failing components communicating through D-Bus, Redis, snapshot files, selectable events, systemd, and process death. Messages and state propagation can be delayed or lost; services can restart independently; state spans volatile memory and persistence. Threads exist inside `rebootbackend`, but treating this as only a concurrent-library problem would omit the dominant failures. There are no Byzantine nodes, quorum rules, terms, or consensus-log semantics.

## Phase 2 — Deep Implementation Analysis

### Component and ownership map

| Component | State owned | Communication | Recovery behavior |
|---|---|---|---|
| `RebootBE` | Volatile manager mode: IDLE/COLD/HALT/WARM | Redis request/status consumers; selectable events | Reinitializes IDLE |
| `RebootThread` | Volatile active flag, method, count, timestamp, status | Worker thread, D-Bus, timer, stop/finished events | Reinitializes default/unknown |
| Host `reboot.py` | Separate volatile active/count/status/request | D-Bus and async Python worker | Reinitializes default/unknown |
| `fast-reboot` | Shell phase and cleanup traps | systemd, Redis, docker, files, processes | Rollback only before commit point |
| Redis and `dump.rdb` | Flags, restored control-plane state, snapshots | CLI/table operations and file copy | Per namespace, non-transactional across operations |
| SWSS/syncd/other services | Queued work, warm state, object reconciliation | Redis notifications, process lifecycle | Component-specific |
| warmboot finalizer | Required component set and wait progress | Redis flags and extension files | Clears flags/saves DB after success or deadline |

### C++ execution path

The main event loop handles one of three selectable sources: a reboot request, worker completion, or process shutdown. A normal request follows this sequence:

```text
validate request
→ copy request into worker object
→ set active/count/start status
→ construct worker thread
→ synchronously call host D-Bus method
→ classify D-Bus response
→ start the platform timer
→ observe stop or timer expiry
→ set failure or remain UNKNOWN
→ notify worker-finished event
→ join worker
→ clear active
→ reset manager state to IDLE
```

These are separate atomic steps. No durable write makes admission, host acceptance, and platform completion one transaction.

`ThreadStatus` protects protobuf state with a mutex. Thread creation establishes a happens-before edge for the copied request. The single `RebootBE` select loop satisfies the documented rule that `Start`, `Stop`, and `Join` be called from one thread. No actionable race was found in the ordinary `m_request` or protobuf paths.

### Distributed request lifecycle

`Start` marks the C++ request active before constructing the worker (`reboot_thread.cpp:267-295`). The worker calls D-Bus synchronously, and only after that call returns successfully does it start a 260-second timer (`:88-103,144-152,194-203`). Stop notification is observed only in the subsequent select, so a hung D-Bus call is outside both the local timer and cancellation path.

The host service repeats admission and status tracking in Python (`reboot.py:83-113,140-251`). It validates all nonzero delays, marks itself active, spawns a worker, and can record an immediate command failure. For COLD/WARM, however, the C++ backend does not poll that host status. It may therefore wait its full local timeout after the host has already reported failure. HALT alone delegates later status reads to the host, and only while the volatile C++ manager still says HALT is in progress.

Both sides use independent timers and neither carries a shared durable request epoch. The C++ object constructs a `STATE_DB` handle but performs no read or write with it. Startup warm-check calls do not restore request ownership, status, method, timestamp, or count.

### Warm-reboot orchestration phases

The pinned `fast-reboot` implementation has the following important phase boundaries:

1. Namespace commands are executed in parallel and can be continued under force (`fast-reboot:101-148`).
2. Cleanup traps disable warm flags and rotate dumps before the commit point (`:341-385`).
3. Pre-shutdown is requested and waited on for 60 seconds; failure is logged but does not abort (`:387-449`).
4. Redis backup prunes selected `STATE_DB` content, then copies `dump.rdb` from the container (`:452-506`).
5. Warm state is enabled for every namespace (`:883-992`).
6. LAG keepalive/CPA is started and orchagent is frozen (`:1075-1156`).
7. The script declares recovery impossible, disables error exit, and ignores traps (`:1163-1180`).
8. Timers are stopped, the generated service order is executed, syncd pre-shutdown is invoked, Redis is backed up, and kernel/platform/reboot steps follow (`:1187-1290`).

After step 7, a missing generated order, service stop failure, pre-shutdown failure, snapshot error, or failed terminal reboot can leave a partially stopped live system. The script intentionally favors reaching reboot, but there is no protocol-level terminal-state guarantee.

### Service ordering and causal drain

The manifests encode a partial order: sflow, lldp, mux, pmon, bgp, nat, radv, stp, and p4rt precede SWSS; teamd and dash-ha follow SWSS but precede syncd; orchagent precedes syncd. This is necessary but not sufficient. A service can have an outstanding timer, a write in transit between CONFIG_DB and APPL_DB, or a retry scheduled after its nominal stop. The relevant correctness condition is a causally closed cut, not merely completion of ordered `systemctl stop` calls.

This distinction is observed in tracker evidence: #12257 describes neighbor-advertiser state still propagating when orchagent's restart check/freeze happens; fixed #2750 showed a delayed SNMP timer starting SWSS during shutdown; #26758 shows keepalive behavior after its retry guard; #27910 shows orchagent blocking after syncd is already down.

### Persistence, snapshot, and finalization

Warm state is persistent but not epoch-scoped. `check_system_warm_boot` treats `STATE_DB` as authoritative when reachable and falls back to kernel command line only during boot. This makes stale flags capable of affecting later service restarts or config reloads.

Snapshot preparation is not atomic: state is destructively pruned before the Redis file copy. Across ASIC namespaces, individual operations may succeed or fail while the eventual physical reboot is global. A valid design therefore needs either globally coherent warm readiness or an explicit cold-recovery protocol that prevents stale producers/snapshots from being consumed.

The finalizer builds its required set from built-in and extension-file components (`finalize-warmboot.sh:12-31`). Its initial Redis/CONFIG_DB readiness loops are unbounded (`:121-135`). Component completion is bounded to five minutes (`:237-258`), including parallel per-namespace waits (`:268-300`). On timeout it logs the incomplete state but still finalizes global warm state and saves Redis (`:302-310`). A missing or late component is therefore converted from a visible incomplete restore into apparent completion.

### Concrete C++ findings and disposition

#### CA-1: backend recovery forgets host-pending ownership

- **Trigger:** Host accepts a request; `rebootbackend` crashes/restarts before the target reboots.
- **Observed state:** New C++ instance is idle with active false and count/status reset, while the host action may remain pending.
- **Consequence:** A second request can be accepted; status continuity is lost.
- **Compensation checked:** No DB persistence or startup reconciliation; HALT host polling depends on volatile manager state.
- **Disposition:** High-priority model-checking scenario.

#### CA-2: local timeout can precede late host completion

- **Trigger:** Host accepts, physical completion takes longer than the C++ post-D-Bus timer.
- **Observed state:** Worker records failure, joins, clears active, and manager returns IDLE without canceling/querying the host.
- **Consequence:** A later COLD/HALT can overlap the first action or race its late completion.
- **Compensation checked:** Long duration reduces likelihood but is not a protocol acknowledgement; no generation identifier exists.
- **Disposition:** High-priority model-checking scenario.

#### CA-3: thread-construction failure wedges active state

- **Trigger:** `std::thread` construction throws after `active=true`.
- **Observed state:** Catch stores `RETRIABLE_FAILURE` and signals finished. `Join` sees a non-joinable thread, returns false, and never clears active; `RebootBE` ignores false and sets its manager IDLE.
- **Consequence:** Future requests are rejected forever and externally visible status remains UNKNOWN because active masks the stored result.
- **Disposition:** Confirmed code path; deterministic injected-failure test and code review. Low formal-model value unless refining the handoff.

#### CA-4: transport failure and host rejection are conflated

- **Trigger:** Either a D-Bus exception or a nonzero host result.
- **Observed state:** `interfaces.cpp:35-48` converts both to `DBUS_FAIL`; `reboot_thread.cpp:145-151` maps both to non-retriable failure; a later WARM is prohibited by `:234-241`.
- **Consequence:** A transient communication failure can permanently disable WARM until a cold recovery.
- **Disposition:** Confirmed design/code issue; targeted test and review of retry semantics.

#### CA-5: D-Bus phase is outside timer and cancellation

- **Trigger:** Synchronous host method call blocks.
- **Observed state:** Timer has not started; Stop only queues an event that the worker cannot observe; shutdown blocks in Join.
- **Consequence:** The advertised timeout is not an end-to-end bound and graceful stop may hang.
- **Disposition:** Liveness test; include abstractly in the ownership model.

#### CA-6: delayed WARM validation is path-inconsistent

- **Trigger:** Supported WARM request with nonzero delay.
- **Observed state:** C++ WARM-specific branch bypasses its following unsupported-delay check, marks the request active, and sends D-Bus. The pinned host service then rejects all nonzero delay.
- **Consequence:** The platform does not immediately reboot, so the isolated-C++ claim of immediate execution is false. The real issue is asynchronous rejection and inconsistent behavior: COLD/HALT are rejected before activation, while WARM is accepted locally and later fails through the host.
- **Disposition:** Integration test and validation cleanup, not a principal state-space scenario.

#### CA-7: success/status is intentionally process-death based but not recoverable

- Production paths assign failure statuses; successful COLD/WARM is expected to kill the process first. Recreated objects default to UNKNOWN. Tests that manually store SUCCESS validate protobuf formatting, not a reachable persisted completion path.
- **Disposition:** Folded into CA-1 rather than treated as a separate defect.

### Lower-confidence observations

- `platform_reboot_select` logs `swss::Select::ERROR` and loops. Persistent-error reachability could not be proven because the exact pinned `sonic-swss-common` source was uninitialized; retain as fault-injection coverage.
- No worker exception boundary surrounds unexpected JSON/D-Bus/logging exceptions. Ordinary D-Bus errors are caught, so only unexpected exception injection is useful.
- WARM retry policy checks the last status rather than the last method, which can conservatively block WARM after a failed COLD/HALT. Intent is not documented; review before classifying.
- The public `GetCurrentStatus` helper is unlocked. Production use appears single-threaded, while tests call across threads; TSAN coverage is appropriate.

### Explicit false-positive exclusions

- No `m_request` race: it is written before worker construction and no later Start is allowed until Join.
- No protobuf status race in normal accessors: all accesses copy or mutate under the status mutex.
- Active-status masking is consistent with the gNOI response rule; CA-3 is that active never clears.
- Immediate Stop was not treated as a lost notification; an existing test exercises Start/Stop/Join and the selectable event is queueing.
- The plain global `sigterm_requested` has only test writers in this repository; no production cross-thread writer was found.
- A fixed timeout and its CONFIG_DB configurability TODO are limitations, not standalone correctness defects.
- OOM exception safety around manual mutex locking is not a useful target.

## Phase 3 — History, Tracker, and Test Archaeology

### Git history coverage

All six commits returned for the selected current C++ core paths were inspected, and every diff was read:

| Commit | Date | Result |
|---|---|---|
| `0bf6100879` / PR #22305 | 2025-04-23 | Path rename/import; no logic change |
| `170f70d7b8` / PR #22634 | 2025-06-03 | HALT-status behavior/comment lineage |
| `9ad94b04…` / PR #22851 | 2025 | HALT-status D-Bus support lineage |
| `0a5f37c49…` / PR #22404 | 2025 | Fix second WARM reboot blocked by untransitioned wait state |
| `3b4082ca…` / PR #22576 | 2025 | Diagnostic wording |
| `c9c56356…` / PR #23597 | 2025-08-07 | Diagnostic wording |

The current `reboot_thread` lineage begins with `46eb26ee1f` (initial functional implementation, PR #20786), moves through the directory rename, and has only a HALT comment change afterward. No functional fix or test addition has touched the worker logic since its introduction. `git log -S` confirmed that the delayed-start branch, thread-launch catch, and in-memory status approach have not been revised.

All 21 commits in `finalize-warmboot.sh` history were read from initial introduction through the multi-ASIC implementation. Important changes include waiting only for enabled components, extension-file component registration, correcting the `CONFIG_DB_INITIALIZED` comparison, and parallel namespace finalization. The foundational behavior—log incomplete restore at the deadline and then finalize—remains.

A broad path/keyword archaeology pass screened 95 commits across finalizer, config setup, SWSS, syncd, teamd, and BGP-related areas. Twenty-seven core/support diffs (the six C++ commits and 21 finalizer commits) were reviewed in full. Remaining matches were screened by subject/path and excluded as build, feature, or platform churn outside the selected mechanism.

Hotspots by selected-path history were the finalizer (21 commits), `rebootbe` (6), and current-lineage `reboot_thread` (3). The density supports focusing the model on lifecycle boundaries rather than C++ data structure detail.

### Tracker search and reading coverage

Public GitHub searches used these overlapping queries:

- `"warm reboot" is:issue` — 272 results.
- `"warm restart" is:issue` — 81 results.
- `rebootbackend is:issue` — 3 results.
- `reboot timeout is:issue` — 90 results.
- `reboot service is:issue` — 286 results.

This is 732 raw overlapping hits, not 732 unique relevant bugs. The first 100 results per broad query were screened where available. Thirty unique high-relevance issues were deep-read, including the complete body and 99 comments. At the time of analysis, `gh` was installed but unauthenticated; public API quota was subsequently exhausted. The audit continued through GitHub's public issue/PR HTML embedded data, including timeline and review content. This limitation prevented private data access but did not truncate the listed public threads.

Deep-read disposition: approximately 23 confirmed bugs, 4 acknowledged/design defects, and 3 disputed or root-cause-uncertain reports. No outright false-positive tracker report was used as positive evidence. Disputed/uncertain items were explicitly excluded from confirmed premises.

### Issue evidence matrix

| Issue | State at review | Classification and modeled disposition |
|---|---|---|
| [#22204](https://github.com/sonic-net/sonic-buildimage/issues/22204) | Open, fix landed | Second WARM blocked by `WARM_INIT_WAIT`; fixed by #22404/`0a5f37c49`. Historical reference only. |
| [#17943](https://github.com/sonic-net/sonic-buildimage/issues/17943) | Open | pmon/xcvrd begins after finalizer clears flags; live finalization/registration evidence. |
| [#12257](https://github.com/sonic-net/sonic-buildimage/issues/12257) | Open | CONFIG-to-APPL propagation races restart-check/freeze; live causal-barrier evidence. |
| [#14964](https://github.com/sonic-net/sonic-buildimage/issues/14964) | Closed/fixed | healthd stop delay caused LAG flap; timeout-budget history only. |
| [#2750](https://github.com/sonic-net/sonic-buildimage/issues/2750) | Closed/fixed | Delayed SNMP timer resurrected SWSS during shutdown; historical ordering evidence. |
| [#6212](https://github.com/sonic-net/sonic-buildimage/issues/6212) | Open | Operator changes warm mode between stop/restart; disputed/unsupported sequence. Excluded from confirmed premises. |
| [#2566](https://github.com/sonic-net/sonic-buildimage/issues/2566) | Closed/fixed | syncd ASIC_DB flush raced orchagent INIT_VIEW; historical cleanup-order evidence. |
| [#2729](https://github.com/sonic-net/sonic-buildimage/issues/2729) | Closed | Stale warm flag could affect config reload; acknowledged design concern, generalized as epoch risk. |
| [#2435](https://github.com/sonic-net/sonic-buildimage/issues/2435) | Closed/fixed | Stale flag after WARM affected later config reload; fixed by #2715. Historical only. |
| [#6072](https://github.com/sonic-net/sonic-buildimage/issues/6072) | Open/fixed for platform | Platform packaging issue; excluded as non-generic. |
| [#7072](https://github.com/sonic-net/sonic-buildimage/issues/7072) | Open | APPLY_VIEW object-in-use failure and repeated INIT_VIEW/cold fallback; live recovery evidence, literal title treated cautiously. |
| [#8722](https://github.com/sonic-net/sonic-buildimage/issues/8722) | Closed/fixed | VID without RID during buffer-watermark reconciliation; historical only. |
| [#3008](https://github.com/sonic-net/sonic-buildimage/issues/3008) | Open | Redis Lua `BUSY` at route scale; real performance mechanism, explicitly not modeled. |
| [#6569](https://github.com/sonic-net/sonic-buildimage/issues/6569) | Closed/fixed | Bad port config left pending work; restart check correctly blocked. Reference only. |
| [#4049](https://github.com/sonic-net/sonic-buildimage/issues/4049) | Closed/fixed | Stale loopback/pending tasks; gate behaved as designed. Reference only. |
| [#12361](https://github.com/sonic-net/sonic-buildimage/issues/12361) | Open | Remote VNI precedes NVO/VTEP and leaves pending work; live preflight-order evidence. |
| [#7488](https://github.com/sonic-net/sonic-buildimage/issues/7488) | Closed/fixed | BGP EoR/reconcile timer deleted routes; historical independent-timer evidence. |
| [#11824](https://github.com/sonic-net/sonic-buildimage/issues/11824) | Open | Persisted DB version migration chain missing across releases; live schema/epoch design defect. |
| [#15675](https://github.com/sonic-net/sonic-buildimage/issues/15675) | Open | Config reload leaves warm-restart state/flags; acknowledged epoch-lifecycle defect. |
| [#27412](https://github.com/sonic-net/sonic-buildimage/issues/27412) | Open | Reconcile timer may precede GR convergence; root cause/config interpretation disputed. Hypothesis only. |
| [#23383](https://github.com/sonic-net/sonic-buildimage/issues/23383) | Open | sysmgr adds control-plane/LACP recovery latency; performance, not modeled. |
| [#22438](https://github.com/sonic-net/sonic-buildimage/issues/22438) | Closed/fixed | cfggen boot latency exceeded LACP budget; performance reference only. |
| [#19682](https://github.com/sonic-net/sonic-buildimage/issues/19682) | Open | hostcfgd SIGTERM could hang 90 seconds; historical confirmed symptom, current applicability uncertain. |
| [#7094](https://github.com/sonic-net/sonic-buildimage/issues/7094) | Closed/duplicate | Platform/SAI hang with incomplete independent evidence; excluded. |
| [#6772](https://github.com/sonic-net/sonic-buildimage/issues/6772) | Closed/fixed | Finalizer continued after unreconciled orchagent, harming next WARM check. Strong historical generalization evidence. |
| [#11416](https://github.com/sonic-net/sonic-buildimage/issues/11416) | Open | Repeated missing warm flag/cold restart, suspected DB startup race; symptom confirmed, root cause uncertain. |
| [#27910](https://github.com/sonic-net/sonic-buildimage/issues/27910) | Open | syncd down before orchagent; periodic ZMQ path can block shutdown. Live order/liveness evidence, platform scope noted. |
| [#27131](https://github.com/sonic-net/sonic-buildimage/issues/27131) | Closed/fixed | Persistent config-initialization state deadlocked multi-ASIC boots; historical persistence evidence. |
| [#26758](https://github.com/sonic-net/sonic-buildimage/issues/26758) | Open | LAG keepalive sends after retry-count guard; live independent-timer evidence. |
| [#28787](https://github.com/sonic-net/sonic-buildimage/issues/28787) | Open | APPLY_VIEW took 88 seconds against a 60-second orchagent bound; live timeout-policy evidence. |

### Open pull-request audit

Searches for open PRs matching warm reboot, warm restart, and rebootbackend yielded 22 bug-fix-intent or correctness-adjacent PRs after feature-only gNOI additions were excluded. All 22 bodies and their public discussion/review content were read. The following first batch contributed these dispositions:

| PR | Review result |
|---|---|
| [#15453](https://github.com/sonic-net/sonic-buildimage/pull/15453) | Observable key deletion during non-warm cleanup; legitimate but outside warm scope. |
| [#20235](https://github.com/sonic-net/sonic-buildimage/pull/20235) | Stale branch timeout workaround for Redis Lua `BUSY`; untested and not root fix. Performance reference only. |
| [#21413](https://github.com/sonic-net/sonic-buildimage/pull/21413) | Platform warm enablement and SAI file/temp-view prerequisites; reference, not generic defect. |
| [#22526](https://github.com/sonic-net/sonic-buildimage/pull/22526) | Config/YANG boolean serialization; unrelated. |
| [#23217](https://github.com/sonic-net/sonic-buildimage/pull/23217) | Draft integration wrapper for an already merged SWSS C++ initialization-order fix; historical test evidence only. |
| [#25465](https://github.com/sonic-net/sonic-buildimage/pull/25465) | Unresolved restart-epoch/order design; review requests simultaneous SWSS/syncd quiescence and identifies flush/repopulation crash windows. High-value live evidence. |
| [#26446](https://github.com/sonic-net/sonic-buildimage/pull/26446) | VS health metadata/general boot readiness; warm merely in test matrix. Excluded. |
| [#26911](https://github.com/sonic-net/sonic-buildimage/pull/26911) | Proposed bounded Redis/finalizer waits; requested changes identify that nil/non-numeric data may be misread as ready. Hypothesis, not accepted fix. |
| [#27027](https://github.com/sonic-net/sonic-buildimage/pull/27027) | Cold-only environment-cache invalidation; excluded. |
| [#27342](https://github.com/sonic-net/sonic-buildimage/pull/27342) | Platform-specific module teardown under CPU-punt traffic; lower-priority ordering evidence. |
| [#25840](https://github.com/sonic-net/sonic-buildimage/pull/25840) | Polluted duplicate platform bundle; feature enablement, excluded. |
| [#25841](https://github.com/sonic-net/sonic-buildimage/pull/25841) | Canonical one-commit Z9100 platform parity proposal; no diagnosed warm defect. Excluded. |
| [#27474](https://github.com/sonic-net/sonic-buildimage/pull/27474) | Broad NH-4210 platform update with warm-reboot validation but no orchestration defect. Excluded. |
| [#28656](https://github.com/sonic-net/sonic-buildimage/pull/28656) | Live confirmed platform preservation defects: absent SAI read/write file keys and an unconditional post-stop ASIC reset. High-value current evidence for shutdown monotonicity and artifact durability. |
| [#28658](https://github.com/sonic-net/sonic-buildimage/pull/28658) | Live platform restore-order defect: warm APPLY_VIEW fatally repeats resource failure tolerated on cold boot; fix incomplete for one profile and first transition must be cold. Scoped ordering evidence. |
| [#28752](https://github.com/sonic-net/sonic-buildimage/pull/28752) | Current counter snapshot save/restore path mismatch. Clear persistence-layout bug but low forwarding-safety/model value; no submitted test evidence. |
| [#28759](https://github.com/sonic-net/sonic-buildimage/pull/28759) | Current teamd cleanup dereferences absent partially initialized LACP state. Strong warm-recovery relevance, but local implementation/test target. |
| [#28796](https://github.com/sonic-net/sonic-buildimage/pull/28796) | Stable scache capacity failure is ordinary platform initialization despite terminology; excluded as non-warm-specific. |
| [#4008](https://github.com/sonic-net/sonic-buildimage/pull/4008) | Stale proposal for fast-mode propagation to syncd stop; underlying mechanism later merged in #9419/`4e32f85a3`. Historical reference only. |
| [#4131](https://github.com/sonic-net/sonic-buildimage/pull/4131) | Stale/superseded cfggen missing-key robustness patch with rejected broad exception handling. Excluded. |
| [#5842](https://github.com/sonic-net/sonic-buildimage/pull/5842) | Rejected coarse process-readiness workaround; review correctly notes running is not application-level registration. Later fixed in sonic-swss #1498. Historical causal-barrier evidence. |
| [#8007](https://github.com/sonic-net/sonic-buildimage/pull/8007) | Broad `pkill` matched auxiliary teamd process during shutdown; superseded by #8856/`5b74f5dcc`. Historical signaling/order evidence. |

For the first batch, ten bodies and 124 rendered body/timeline/review entries were read; eight PRs were open and two were draft at review time. Six were warm/restart-related, but only #25465, #26911, and #27342 supplied live actionable mechanism evidence, with requested changes recorded on the first two.

Across this second batch, four PRs contain live warm/fast-reboot correctness fixes (#28656, #28658, #28752, #28759), three are platform feature/enablement, one is non-warm-specific, and four are stale, rejected, or superseded. The 12 bodies, 110 visible timeline/review-summary entries, and seven inline review comments were read. All 12 were open and none was currently a draft at review time.

### Test coverage audit

The 14 `reboot_thread_test.cpp` cases cover status initialization/manual completion, immediate Stop, timeout, Join without Start, duplicate Start before Join, unsupported dispatch, prior WARM failure, and startup SIGTERM. `rebootbe_test.cpp` covers event-loop admission/status and mocked D-Bus outcomes.

Material gaps:

- No delayed WARM request or method-by-method delay validation.
- No injectable thread factory or construction-failure case.
- No backend destroy/recreate while the host retains a pending request.
- No successful platform reboot followed by restored status/count/method.
- No distinction between D-Bus transport failure and host rejection.
- No WARM retry after transient IPC loss.
- No blocking D-Bus mock or Stop-during-D-Bus case.
- No end-to-end timeout that includes transport time.
- No host completion after local timeout followed by a second request.
- No persistent `Select::ERROR` or unexpected worker exception injection.
- No namespace-by-namespace snapshot failure matrix.
- No delayed CONFIG-to-APPL propagation or late component-registration test.

Tests were not executed. Required submodules are uninitialized and no built test binary was present. `Makefile.am` shows intended normal, ASAN, TSAN, and UBSAN variants; the findings above are source-path proofs, not dynamic results.

## Phase 4 — Model Boundary and Handoff Decisions

### Mechanisms selected for formal modeling

1. **Backend/host split ownership:** the key message-passing protocol has no durable correlation across backend failure or timeout.
2. **Epoch-scoped warm state:** persistent flags, snapshots, restore acknowledgements, and finalization must not cross reboot attempts.
3. **Causal drain and irreversible commit:** service order must account for in-flight writes, timers, and resurrection, and post-commit execution must reach a terminal state.
4. **Multi-ASIC snapshot coherence:** local partial outcomes feed a single global reboot and require a coherent fallback decision.

### Findings deliberately routed away from TLC

- Thread-construction failure, delay validation, D-Bus classification, unlocked helper access, and unexpected exceptions are smaller and more decisively covered by tests/code review.
- Redis Lua run time, cfggen overhead, platform boot duration, and exact seconds are performance/configuration topics; the model uses nondeterministic deadline events instead.
- Fixed historical incidents are not encoded as regression adversaries. Their common mechanisms justify current general transitions only.
- SAI object IDs, vendor driver behavior, exact service inventories, logging, metrics, JSON, and shell syntax are below the selected abstraction boundary.

### Proposed abstraction

The model should use two backend/host state machines, a finite dependency graph, two ASIC namespaces, and an epoch identifier. Required state includes:

```text
backendAlive, backendActive, managerState, requestEpoch,
dbusPhase, hostPending, hostStatus, platformPhase,
warmFlagEpoch, snapshotEpoch[asic], snapshotValidity[asic],
producerState[role,asic], inFlight[channel,asic],
consumerState[role,asic], required[role,asic], restored[role,asic],
deadlineExpired, commitCrossed, finalizedEpoch, recoveryMode
```

Key actions are admission, D-Bus delivery/loss, host acceptance/rejection, backend crash/recovery, local timeout, late platform completion, producer quiescence, message delivery, consumer drain/freeze, warm enablement, prune/copy, namespace failure, commit, finalizer deadline, and explicit cold recovery.

### Principal invariants

- At most one platform reboot is pending.
- Recovery cannot forget a pending host action and admit another.
- Persistent state combined in one restore/finalization belongs to one epoch.
- Finalization never claims success while required restoration or causal input remains incomplete.
- Freeze occurs only after producers are quiescent and prior updates are visible/discarded.
- After the irreversible commit, execution is monotonic toward reboot or explicit recovery.
- A valid snapshot is complete, compatible, and captured from quiescent state.
- Global reboot never consumes an undefined mixture of namespace warm/cold state.
- Timeout, nil, or malformed readiness is never treated as successful readiness.

## Audit Limitations

- Public GitHub evidence was available, but authenticated `gh` operations were not. Open/closed state and public discussion were captured at analysis time; later tracker changes are naturally outside the audit.
- Search result totals overlap heavily and public search caps broad result sets. The audit claims exhaustive reading only for the 30 enumerated issues and 22 enumerated open PR candidates, not every raw search hit.
- Uninitialized pinned submodules prevented compiling/running the C++ suite and locally inspecting `swss::Select` internals. Exact pinned public source was used for host, utility, and API boundary analysis.
- Platform-specific shell/plugin implementations were not exhaustively enumerated. They are abstracted as dependency roles and failure actions.

## Reference Map

### Local sources

- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp`
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp`
- `src/sonic-sysmgr/rebootbackend/interfaces.cpp`
- Corresponding headers and `tests/`
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh`
- Warmboot service dependency manifests and config-setup warm-boot checks

### Pinned external sources

- `https://raw.githubusercontent.com/sonic-net/sonic-host-services/233cd591c324d4090a077f87da0eaaad7d12cabc/host_modules/reboot.py`
- `https://raw.githubusercontent.com/sonic-net/sonic-utilities/b17c48270c15fc6d5c81a23d97e2946cd7059dcd/scripts/fast-reboot`
- `gnoi-system@2b6ff72de5769839fc68bd019f345a184e3b0bf1/system/system.proto`

### Deliverable relationship

`modeling-brief.md` is the constrained handoff to Spec Generation. This report preserves implementation reasoning, archaeological evidence, exclusions, test gaps, and audit limitations that should not expand the formal model unless a future counterexample or trace requires refinement.
