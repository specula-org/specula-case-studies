# MC-4 investigation evidence

## Artifact and checkout provenance

- The supplied model-checking output is `spec/output/MC_hunt_scenario5_bfs.out`. It reports `Error: Invariant IdentityMapBijective is violated` at line 36, so this is MC-sourced from a real violation trace.
- The buildimage checkout is `d5a2f4d1df9fdf71e48777905cd3f032b3d78a94`; its `src/sonic-sairedis` submodule is `9bd6103824e4590b24fbce2bc014d8902b51eccb`, and `src/sonic-swss-common` is `c544c90acc862dddacdb454a2ad8d5eb1a68e105`.
- The relevant unmodified `syncd`, `syncd_tests`, `libSyncd.a`, `libsairedis`, metadata, and VS SAI artifacts were rebuilt from that checkout with `./configure --with-sai=vs --disable-python2 --with-swss-common-inc=/usr/local/include --with-swss-common-lib=/usr/local/lib` and `make -j4` under an outer timeout. The reproduction runner checks the sairedis SHA before using them.

## Step 1: code audit

### Publication site

- `syncd/Syncd.cpp:5921-5980` replaces the current ASIC view, derives `allVid2Rid` from each temporary view's `m_ridToVid`, and invokes `m_client->setVidAndRidMap(allVid2Rid)` at line 5978.
- `syncd/RedisClient.cpp:664-680` implements that replacement as independent synchronous Redis commands: `DEL VIDTORID` (line 669), `DEL RIDTOVID` (line 670), then one `HSET VIDTORID` and one `HSET RIDTOVID` per pair (lines 677-678). There is no Redis transaction, Lua script, generation key, or post-write reciprocity check in this function.
- The input map is injective, but that property does not make the two authority hashes atomic to readers or process failure.

### Public call chain and reachability

The site is reached through the normal sairedis control interface:

1. An orchagent-style client sets `SAI_REDIS_SWITCH_ATTR_NOTIFY_SYNCD` to `INIT_VIEW`, creates the switch/view through SAI, and sets the notification to `APPLY_VIEW` (`lib/RedisRemoteSaiInterface.cpp:2391-2457`).
2. syncd consumes that Redis request in `Syncd::processEvent` (`syncd/Syncd.cpp:404-425`) and dispatches it through `processSingleEvent` (`:460`) to `processNotifySyncd` (`:5410`).
3. The APPLY branch invokes `applyView` at `syncd/Syncd.cpp:5567`; `applyView` performs comparison and ASIC operations, then calls `updateRedisDatabase` at line 5849.
4. `updateRedisDatabase` reaches the map replacement at line 5978.

This chain needs no private call, malformed input, or pre-populated inconsistent state. A process exit after the first `DEL`, or an external Redis consumer while the command sequence is running, can observe the cut naturally.

### Concrete trigger scenario

1. Cold-start syncd and create/apply a normal SAI switch view, producing reciprocal non-empty maps.
2. Start a subsequent `INIT_VIEW`, create the deterministic switch VID, and issue `APPLY_VIEW` through sairedis.
3. syncd reconciles the view and enters `RedisClient::setVidAndRidMap` with the complete matching.
4. After `DEL VIDTORID` returns and before `DEL RIDTOVID`, either an external reader runs or syncd exits.
5. Redis contains no forward map and the entire old reverse map. If syncd exited, no remaining writer finishes the replacement.
6. A subsequent translation or syncd restart reads the split authority state.

### Counterexample correspondence

- State 24 begins `MCNextApply`'s `delete-v2r` stage (`spec/output/MC_hunt_scenario5_bfs.out:1786,1830,1835`) with reciprocal old maps (`:1841,1848`).
- State 25 advances to `delete-r2v` (`:1862,1906,1911`): all VIDs have `"no-rid"` (`:1917`) while `ridToVid` still contains the old three mappings (`:1924`).
- This is the same command boundary as production `RedisClient.cpp:669-670` and the same violated property (`IdentityMapBijective`).

### Consumers and safeguards

- A forward lookup is a real production operation: `VirtualOidTranslator::translateVidToRid` reads `VIDTORID` through `getRidForVid` and throws `unable to get RID for VID` when absent (`syncd/VirtualOidTranslator.cpp:361-409`). The warm-restart caller performs this exact lookup for the switch at `syncd/Syncd.cpp:6257`.
- Cold/hard reinitialization independently reads both hashes (`syncd/HardReiniter.cpp:42-43`), builds per-switch maps, and indexes the missing forward per-switch map at line 100. With ASIC state and reverse entries but no forward entries, this takes the init exception path.
- `Syncd::processEvent` holds `m_mutex` (`Syncd.cpp:409`), which serializes syncd's own event processing but does not lock external Redis clients and cannot make Redis durable commands atomic.
- On a successful APPLY, later HSETs finish both maps, the reply is sent, and the local translator cache is cleared (`Syncd.cpp:5583-5602`). That repairs the transient database snapshot only if the publishing process survives.
- No periodic reconciliation, loopback, restart-time map validation, resend, or generation switch was found. A new process also has no old translator cache. `HardReiniter` can rewrite both maps at line 145 only after reinitialization succeeds; the missing forward per-switch map prevents reaching that write.

## Step 2: developer-knowledge evidence

### Comments and design intent

- Immediately above publication, `Syncd.cpp:5926` suggests a Lua script and line 5966 says `TODO check if those 2 maps are consistent`.
- The hard-reinit path comments that the clear/recreate/post-action sequence “must be ATOMIC” (`syncd/HardReiniter.cpp:138-143`). These comments do not supply an atomic implementation or a tolerated-reader contract.
- The successful-APPLY path separately acknowledges a possible notification/cache race (`Syncd.cpp:5594-5599`) and clears the cache only after publication.

### History and tests

- `git blame` attributes the setter to `edcc25135` (2020-02-14) and the current Redis `DEL`/`HSET` calls to `40439b460` (2020-10-23, PR #681). `git log -S` found no later atomic-publication change.
- The recent merged change `eebc7951` / PR #1819 (“Enable async ASIC_DB writes for Southbound-ZMQ”, merged 2026-07-17) is present in this checkout but does not alter `RedisClient::setVidAndRidMap` or add a commit point for these hashes.
- The only test reference found for `setVidAndRidMap` is `syncd/tests/TestDisabledRedisClient.cpp:202`, which asserts a disabled client does not throw. No existing test asserts reciprocal visibility, a crash cut, or restart validation for the real Redis client.

### Filed reports

- Open upstream PR [#1784](https://github.com/sonic-net/sonic-sairedis/pull/1784), “Fix flex counter SAI errors during warm reboot by deferring until APPLY_VIEW,” reports that flex-counter events arrive while `VIDTORID` is not fully populated, receive RID 0, and repeatedly fail SAI calls. Its description explicitly identifies `applyView()` and `setVidAndRidMap()` as the publication boundary. This is the same fragmented map-publication mechanism at the same site, with a live concurrent consumer.
- Open upstream PR [#1767](https://github.com/sonic-net/sonic-sairedis/pull/1767), “Skip FlexCounters Poll with RID 0x0,” reports the same warm-reconciliation symptom on a device with 600+ ACLs and proposes a consumer-side retry/skip.

## Step 3: known-status / precedent

- Searches covered open and closed sonic-sairedis issues/PRs for `VIDTORID`, `RIDTOVID`, and `setVidAndRidMap`; organization-wide combinations of both hash names and APPLY/view/atomic terms; and recently merged/closed PRs updated since 2026-06-01. Local history and the current master tree were rechecked for landed fixes.
- PR #1784 is an exact same-site report of non-atomic/partial `setVidAndRidMap` publication to a real reader. It remains open and unmerged, while the checked-out current implementation remains fragmented. Evidence therefore supports `Novelty: KNOWN (cite: https://github.com/sonic-net/sonic-sairedis/pull/1784; fix-status: unfixed)`.
- PR #1819 was the only recent merged search hit involving these names, but inspection showed it is unrelated to reciprocal publication and did not fix this setter.
- Because the supplied trace is a real MC violation, known status does not activate the code-review-only drop pre-filter; Phase 2 is required.
