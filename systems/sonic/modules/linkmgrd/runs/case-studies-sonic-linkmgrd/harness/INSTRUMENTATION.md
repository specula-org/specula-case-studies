# Instrumentation Guide: sonic-linkmgrd

## Trace Module

`harness/src/tla_trace.h` — header-only, guarded by `#ifdef LINKMGRD_TRACE`.

Singleton `tla_trace::TraceWriter` writes mutex-protected NDJSON to the file specified by `LINKMGRD_TRACE_FILE` env var. ToR IDs are auto-assigned (`t1`, `t2`) based on port name order.

## Instrumentation Points

| Event | File (after apply) | Location | Capture Level |
|-------|-------------------|----------|---------------|
| HeartbeatActive | `src/link_prober/LinkProberStateMachineBase.cpp` | Inside `processEvent<T>`, after self-transition check (line ~203) | sub_lp_state only |
| HeartbeatUnknown | same | same (detected by new state label) | sub_lp_state only |
| PeerHeartbeatActive | same | same (detected by new state = PeerActive) | sub_lp_state only |
| PeerHeartbeatUnknown | same | same (detected by new state = PeerUnknown) | sub_lp_state only |
| MuxNotification (toggle) | `src/link_manager/LinkManagerStateMachineActiveActive.cpp` | `handleMuxStateNotification`, after `mLastMuxStateNotification = label` (~line 211) | sub_mux_state, last_mux_notification |
| MuxNotification (probe) | same | `handleProbeMuxStateNotification`, after timer cancel (~line 320) | sub_mux_state, last_mux_notification |
| LinkChange | `src/MuxPort.cpp` | `handleLinkState`, after label conversion (~line 165) | sub_link_state |
| ProcessEvent (LP) | `LinkManagerStateMachineActiveActive.cpp` | `handleStateChange(LinkProberEvent)`, after `mCompositeState = nextState` (~line 553) | Full composite + peer + backoff |
| ProcessEvent (Mux) | same | `handleStateChange(MuxStateEvent)`, after `mCompositeState = nextState` (~line 583) | Full composite + peer + backoff |
| ProcessEvent (Link) | same | `handleStateChange(LinkStateEvent)`, after `mCompositeState = nextState` (~line 620) | Full composite + peer + backoff |
| ProcessEvent (PeerLP) | same | `handlePeerStateChange`, after switch/case block (~line 661) | Full composite + peer + backoff |
| MuxProbeTimeout | same | `handleMuxProbeTimeout`, after errorCode check (~line 1263) | mux_probe_backoff |
| MuxWaitTimeout | same | `handleMuxWaitTimeout`, after errorCode check (~line 1310) | wait_cause |
| PeerWaitTimeout | same | `handlePeerMuxWaitTimeout`, at entry (~line 1346) | last_set_peer_mux_state |
| ResyncTimeout | same | `handleAdminForwardingStateSyncUp`, at entry (~line 477) | wait_mux |
| DefaultRouteChange | same | `handleDefaultRouteStateNotification`, after state update (~line 1374) | default_route |
| ModeChange | same | `handleMuxConfigNotification`, before `setMode` (~line 273) | mode |
| SoCRestart | same | `startAdminForwardingStateSyncUpTimer`, at entry (~line 462) | peer_mux_state, peer_lp_state |

## How to Add a New Field to an Event

1. Open `harness/src/tla_trace.h`
2. Find the `emit*` function for that event
3. Add a parameter and include it in the `snprintf` JSON template
4. Update the corresponding `TLA_TRACE_*` macro to pass the new field
5. Update the instrumentation point in the source file to supply the value

## How to Add a New Event Type

1. In `tla_trace.h`, add a new `emit*` function following the existing pattern
2. Add a corresponding `TLA_TRACE_*` macro (and a no-op `#else` version)
3. Insert `TLA_TRACE_*()` at the desired source code location
4. Re-apply: `bash harness/apply.sh`
5. Add a `Trace*` wrapper in `Trace.tla`

## How to Move a Capture Point

To move instrumentation from before to after an operation (or vice versa):
1. Edit the patch file `harness/patches/instrumentation.patch` — move the `TLA_TRACE_*` line
2. Or: re-apply, manually edit the source, re-generate the patch:
   ```bash
   bash harness/apply.sh
   # edit source files
   cd artifact/sonic-linkmgrd && git diff > ../../harness/patches/instrumentation.patch
   ```

## How to Rebuild and Re-run

```bash
cd .specula-output
bash harness/apply.sh          # re-apply instrumentation
cd artifact/sonic-linkmgrd
make clean-targets 2>/dev/null; make -j$(nproc) test-targets \
  CPP_FLAGS="-O0 -Wall -c -fmessage-length=0 -fPIC -fprofile-arcs -ftest-coverage -DLINKMGRD_TRACE"
LINKMGRD_TRACE_FILE=../../traces/test.ndjson \
  ./linkmgrd-test --gtest_filter="LinkManagerStateMachineActiveActiveTest.*"
```

## Known Limitations

- **SoCRestart** is emitted at `startAdminForwardingStateSyncUpTimer()` which is called during initialization too, not just on actual SoC restart. The Trace.tla `SilentTimerExpiry` handles the extra emissions.
- **eventQueue** is not directly observable — the spec's unordered set models the boost::asio strand queue implicitly via stimulus + ProcessEvent event pairs.
- Timer pending state is inferred from start/expiry event sequences, not directly captured.
