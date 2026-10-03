# Instrumentation specification — etcd Raft V00

This handoff targets the supplied production source unchanged, using public Node/RawNode operations and an observational build adapter. It defines the input of `Trace.tla`, not a completed harness or an accepted implementation trace. Category A uses one globally ordered NDJSON stream. Source paths below are relative to `../../source/`.

## 1. Trace event schema

Store implementation traces at `../traces/<scenario>.ndjson`. `Trace.tla` defaults to `../traces/trace.ndjson`; environment variable `JSON` selects another file. Preserve the pinned `Json.tla`, `IOUtils.tla`, `CommunityModules-deps.jar` and `tla2tools.jar` on the TLA module/Java class paths. `run-checks.sh syntax` shows their run-local paths.

Each noninitial record has exactly this logical envelope:

```json
{"tag":"trace","ts":"2026-09-12T18:00:00.000000001Z","event":"Tick","params":{"tag":"record","value":{"node":{"tag":"atom","value":1},"timeout":{"tag":"atom","value":4}}},"post":{"tag":"record","value":{}}}
```

The empty `post` above is an envelope illustration **and is not a valid trace event**. Every event must carry the complete post-state described below. No field is optional, no missing-field check is treated as true, and no state-changing operation is silently inserted by the validator. Put unrelated diagnostics in a separate file (or a distinct non-`trace` tag). `TraceLog` filters by the tag, never by event name.

The first record is `event: "Init"`, contains `settings` and `post`, and represents all constructors having completed before any core/client events. `settings` is a typed record containing every base constant, with `BootPeers` as an ordered sequence: Server, BootPeers, Joining, RawNodes, PreVoteNodes, CheckQuorumNodes, NoForwardNodes, RequestId, PayloadWeights, EncodedWeights, ElectionTick, HeartbeatTick, MaxInflight, MaxMsgSize, MaxReadySize, MaxUncommitted, SendPolicy, PersistPolicy, EarlyAdvance, ReadFence, CancelChanges, CancelUnknownRemovals, RecoveryMode, BootstrapPayload, BootstrapEncoded, EmptyEncoded. Use numeric, nonzero IDs for actual traces. Request IDs are globally unique integers; zero is the empty/no-context sentinel. Init is the actual bootstrap/join state, not a synthetic preelected leader or arbitrary storage image. A restart is a subsequent `Restart` event.

**Typed value codec.** Ordinary JSON cannot distinguish sequences, sets and functions or encode record-valued bag keys. The recursive codec makes that distinction explicit:

| TLA value | JSON encoding |
|---|---|
| number/string/Boolean | `{"tag":"atom","value":...}` |
| sequence | `{"tag":"seq","value":[encoded element,...]}` |
| finite set | `{"tag":"set","value":[encoded element,...]}`; order is irrelevant |
| record with string fields | `{"tag":"record","value":{"field":encoded value,...}}` |
| function/map, including a bag | `{"tag":"map","value":[{"key":encoded key,"value":encoded value},...]}` |

A bag is a function from a complete abstract message record to a strictly positive multiplicity. Empty bags/maps must use `map`, empty sequences `seq`, and empty sets `set`. No duplicate map keys are allowed. `trace_codec.py` provides a reusable encoder and structural preflight checker. This is a serialization adapter, not an oracle or a substitute for real observations.

**Mandatory post-state.** `post` decodes to the exact `Observed` record in `Trace.tla`: `raft`, `disk`, `ready`, `application`, `requests`, `wire`. Each node-indexed component is a function on all Server IDs. `ObservedRaft` excludes only the accumulated oracle sets `wins`, `grants`, `campaigns`, `commitUses`; the base actions independently recompute them. It includes every other key in the `InitialRaft` record. Equality validates all nested fields, including inactive batches and unaffected nodes. Instrumentation must not populate `post` by evaluating the reference model.

| Component/fields | Capture source and normalization |
|---|---|
| `raft[n].id`, `term`, `vote`, `role`, `lead` | raft.id/Term/Vote/state/lead (`raft.go:252-278`); role names Follower, PreCandidate, Candidate, Leader |
| `config.voters`, `config.outgoing`, `config.learners`, `config.learnersNext`, `config.autoLeave`, `prs` domain | both `r.prs.Voters` halves, both learner maps, AutoLeave, and Progress. Preserve joint membership exactly; never project it to one voter set in instrumentation. |
| `prs[p].match,next,mode,probe,pending,active,inflight` | actual Progress fields and ordered logical Inflights endpoints (`tracker/progress.go:29-76`, `tracker/inflights.go:43-124`). Status omits Inflights; an internal observational hook is required. |
| `prs[p].evidence` | caller/instrumentation shadow prefix from the exact acknowledged message that raised Match; reset it on source progress reset. Self Match is a volatile append witness. Do not infer remote durability from Match. |
| `unstable`, `uoff`, `usnap`, `commit`, `applied` | `raftLog.unstable.entries/offset/snapshot`, committed, applied. `applied` is the Raft instruction cursor, not actual application. |
| `store.hist,cut,snapshot,hs` | Storage adapter's current visibility. Preserve a shadow full prefix below compaction so the actual dummy term and symbolic snapshot history remain comparable. This is distinct from durable completion. |
| `cfgHist` | observational history identifying the constructor/callback/full-restore prefix supplying configuration; reproduce callback observation order, including bootstrap reapplication, without using a property to pick a valid config. |
| `yes`,`no` | the entire tracker Votes map split by true/false, retaining entries outside current configuration; source counting still filters voters |
| `pendingConf`,`quota`,`transfer` | pendingConfIndex, uncommittedSize, leadTransferee; observe quota at core decision and Ready extraction, including rejection bookkeeping |
| `elapsed`,`heartbeat`,`timeout` | electionElapsed, heartbeatElapsed, randomizedElectionTimeout. Record the actual newly chosen timeout for the outer event. No wall-clock inference. |
| `preVote`,`checkQuorum`,`noForward` | Config flags fixed in metadata and checked in every node snapshot |
| `out`,`readQueue`,`readStates` | actual queued messages; ordered pending-read queue with captured index/request/ack map; actual readStates buffer. Keep RawNode's buffer clearing behavior. |
| `prevHS`,`prevSS`,`readySeq`,`nodeLead`,`propcEnabled` | actual wrapper's previous-state snapshot and caller's monotone Ready batch ID. Node advances previous state at emission; RawNode at Advance. nodeLead/propcEnabled capture Node.run leader-cache/channel housekeeping, including re-enabling after a later leader change. |
| `alive`,`incarnation`,`snapAvailable`,`fatal`,`decision` | scheduler lifecycle/incarnation, Storage snapshot availability, observed fatal branch/reason, last core proposal decision. These are observational shadows. Never invent a panic or replace one with a successful transition. |
| `disk[n].hs,log,snapshot,savedApp` | caller durable adapter after completed persistence only. `log` is an index→Entry function and may expose an interrupted-write hole; do not fill holes from the live core. savedApp is a separately completed caller checkpoint. |
| `ready[n]` | immutable captured batch (actual hs/ss plus presence flags, entries, snapshot, committed page, messages, read states, MustSync) and caller stages `started`, `done`, `installed`, `remainingMessages`, `published`, `queued`; `hist`, `fromApplied`, `cursor` are capture-time witnesses |
| `application[n].hist,config,jobs,reads` | real symbolic state-machine history, deterministic configuration result, ordered pending application jobs, delivered ReadState records. These fields never advance merely because Advance was called. |
| `requests[id]` | invocation kind/target/weights/retry parent/context/node, handoff, core outcome, API outcome/cancellation, actual client completion; beforeWrites is a shadow set of write histories completed before invocation |
| `wire` | scheduler's actual outstanding published message multiset, retaining multiplicity and old-incarnation traffic; delivery/drop consumes one occurrence, duplication adds one |

**Entry schema:** `term,index,kind,id,target,changes,transition,weight,encoded`. `kind` is Normal/AddVoter/AddLearner/Remove/Update/V2. Decode ConfChange and ConfChangeV2 bytes observationally; V2 retains the ordered single-change records and Auto/JointImplicit/JointExplicit transition. `id` is the harness's command/request correlation, zero for bootstrap/no-op/automatic leave. `target` is the legacy ConfChange.NodeID and zero for V2/normal entries. `weight` models Data length; `encoded` models Entry.Size independently. See the abstraction rules below; byte serialization is not a modeled mechanism.

**Message schema:** `type,from,to,term,index,logTerm,commit,entries,reject,hint,context,snapshot,request,witness,read,forced`, exactly as `Message` in `base.tla`. Map protobuf Type/From/To/Term/Index/LogTerm/Commit/Entries/Reject/RejectHint/Context/Snapshot. `forced` corresponds only to the real campaign-transfer context. MsgReadIndex/Resp's one context entry is represented by `context`/`request`/`read`, not by normal log entries. The source cannot fabricate malformed such responses through the modeled send path. `request`, `witness`, and `read` are provenance shadows attached to the actual send and carried unchanged across scheduler duplication/delivery. `witness` is the producer's full symbolic log (or acknowledged prefix), not a receiver guess.

**Read witness schema:** `id,rid,requester,index,term,leader,config,acks,hist,confirmConfig,confirmAcks,confirmTerm,singleton`. Capture initiation term/configuration/index and queue order at addRequest, actual ack set and current configuration at release, then correlate through forwarding/Ready. `id` is context, `rid` invocation identity. A completed read additionally observes actual application history. Witnesses describe what happened even if invalid; no instrumentation branch may require ReadBasis to hold.

## 2. Action-to-code mapping

All rows use the common mandatory post-state. `params` lists only additional action inputs. Capture after the named operation completes, under the scheduler's event-serialization boundary. Pure helpers such as Step/MaybeCommit/FillAppend are inside an outer core event, not independent schedulable events.

| Base action = event | Source location / trigger | Required params | Notes |
|---|---|---|---|
| Init | after all `StartNode` / `NewRawNode` constructors (`node.go:198-245`, `rawnode.go:72-116`) and before active scheduling | settings, post | Bootstrap order is real order. Joining uses empty peers. |
| Tick | after actual Tick core call (`raft.go:619-653`; Node run `node.go:384-385`) | node, timeout | Includes the triggered election/check/heartbeat work atomically. |
| Campaign | after public Campaign's MsgHup handling (`rawnode.go:136-140`, `raft.go:859-883`) | node, timeout | Include ignored/pending-conf/fatal outcome. |
| TickQuiesced | after RawNode.TickQuiesced (`rawnode.go:124-134`) | node | Trace premise requires quiescent equal-history group and empty transport. |
| TransferLeader | after local management input (`raft.go:1151-1181,1257-1273`) | node, target, timeout | Preserve ignored/replaced/self/learner outcomes. |
| Invoke | caller API request registration before handoff (`node.go:442-460,473-489`, RawNode corresponding calls) | node,id,kind,target,weight,encoded,parent,context | A Normal/ConfChange invocation is not acceptance. |
| InvokeV2 | caller ConfChangeV2 registration before handoff (`node.go` ProposeConfChange, RawNode ProposeConfChange) | node,id,changes,transition,weight,encoded,parent | Ordered change batch and transition are mandatory; invocation is not acceptance. |
| Propose | after core proposal handling (`node.go:358-365`; `rawnode.go:143-164`; `raft.go:962-994,1199-1201,1235-1244`) | node,id,timeout | Capture original versus rewritten entry, pendingConf, quota and actual return. |
| ReadIndex | after local read input core handling (`raft.go:995-1029,1274-1287`) | node,id,timeout | A handoff can yield no ReadState. |
| ReturnAPI | caller observes API completion (`node.go:473-509`, synchronous RawNode return) | id | RawNode events should be adjacent to core return. Cancellation never undoes handoff. |
| Cancel | caller context cancellation (`node.go:478-481,494-507`) | id | Capture whether handoff already occurred. |
| Receive | after Node.Step/RawNode.Step filtering and complete core Step (`node.go:366-370`, `rawnode.go:174-182`, `raft.go:784-929`) | message,timeout | Use a message actually present in wire. Preserve unknown-response filtering. |
| Lose | scheduler discards one already published message (`README.md:118,126-132`) | message | No protocol/core mutation. |
| Duplicate | scheduler copies one already published valid message | message | Identical payload/provenance; multiplicity grows by one. |
| ReportSnapshot | after public report and source handler (`node.go:178-188`, `raft.go:1122-1143`) | node,message,failed,timeout | Reference the published MsgSnap. Transport status is separate from receiver installation/ACK. |
| ReportUnreachable | after public report (`node.go:176-177`, `raft.go:1144-1150`) | node,message,timeout | Reference a real last published send; preserve late/no-op handling. |
| Ready | after actual Ready receipt (`node.go` run/readyWithoutAccept, `rawnode.go` Ready) | node | Capture before caller persistence/application. Node accepts message/read buffers on delivery; RawNode Ready is read-only. Quota is unchanged until Advance. |
| StartPersist | caller starts logical write (`README.md:114-118`) | node,part | part is All or Entries/HS/Snapshot according to metadata policy. |
| CompletePersist | caller reports actual durability completion | node,part | Update disk only here; success of MemoryStorage.Append is not fsync. |
| StorageApplySnapshot | after Storage.ApplySnapshot (`storage.go:172-185`) | node | Separate visibility from durability and application. Empty-snapshot stage is a caller no-op. |
| StorageAppend | after Storage.Append (`storage.go:239-269`) | node | Preserve suffix truncation and old-snapshot boundary. |
| StorageSetHardState | after Storage.SetHardState (`storage.go:99-104`) | node | Logical whole-record visibility. |
| Publish | after each individual outbound-message publication, or completion of an empty send batch (`README.md:118`) | node | Post-state remainingMessages/wire identifies the actual chosen message. Crash/receive can interleave between messages in a Ready batch. |
| QueueApplication | caller makes persisted batch available to ordered application worker (`node.go:145-157`, `README.md:120-122`) | node | Does not apply data; queue survives Advance. |
| Advance | after actual Node.Advance/RawNode.Advance (`node.go` Advance path, `rawnode.go` commitReady, `raft.go` advance) | node | Acknowledge captured endpoints, release quota, update wrapper cursors, clear RawNode buffers, and preserve any source-appended automatic leave entry. |
| ApplySnapshot | caller completes applying the head job snapshot (`README.md:120`, `node.go:145-157`) | node | No core restore implied at this point. |
| ApplyEntry | after actual next state-machine entry and its required ApplyConfChange callback (`README.md:120`, `raft.go:1403-1494`) | node,timeout | Keep canceled callback as an event. Actual callback uses deterministic application state only. |
| FinishApplication | caller completes the now-empty head batch (`node.go:145-146`) | node | No later batch applies first. |
| SaveApplication | caller durably checkpoints its actual applied state (`node.go:249-252`, `raft.go:373-375`) | node | Explicit custom caller-adapter responsibility. |
| CompleteWrite | caller returns a write after observing its applied entry (`README.md:164-170`) | node,id | Observe actual completion; no exactly-once contract. |
| CompleteRead | caller returns the symbolic state-machine read (`node.go:63-66,168-172`, `read_only.go:19-23`) | node,id,position | position is the 1-based delivered-read witness slot; actual app fence is mandatory. |
| CreateSnapshot | after Storage.CreateSnapshot from real application prefix/config (`storage.go:188-210`) | node,index | Term is from actual Storage; data/config from actual application history. |
| PersistLocalSnapshot | caller durability completion of created snapshot | node | Distinct from MemoryStorage snapshot visibility. |
| Compact | after legal Storage.Compact (`storage.go:213-233`) | node,index | Preserve dummy term and prefix witness; do not compact beyond the documented cursor. |
| SnapshotAvailability | caller Storage begins/ends temporary snapshot unavailability (`storage.go:65-68`, `raft.go:466-471`) | node,available | Only the documented retryable condition; no forged storage result. |
| Crash | scheduler ends process/incarnation and loses unfinished volatile work | node | Preserve successfully completed disk writes and published wire messages. |
| Stop | after public Stop (`node.go:301-311,422-424`) | node | Current model shares crash cleanup; full stopped-method outcome matrix is an explicit gap. |
| Restart | after caller recovery and RestartNode/NewRawNode (`node.go` RestartNode, `rawnode.go` NewRawNode, `raft.go` newRaft/restore) | node,timeout | Read only actual durable image and declared recovery adapter. Capture all persisted ConfState fields before construction and the exact source projection afterward; do not initialize a model-generated “safe” state. |

## 3. Special considerations and harness plan

**Atomicity and observations.** Emit one outer core event for an entire serialized Step/Tick/config callback. Source helper changes within it must be visible in the post-state; do not invent network-visible boundaries between `becomeLeader`, its no-op and its broadcast/refill. Conversely, each caller storage completion, Storage visibility call, per-message publication, application completion and Advance is its own event. The scheduler must obtain a coherent post-state across nodes without modifying protocol decisions. For Node, hook inside its run goroutine at the selected-case completion and coordinate caller completion events; for RawNode serialize public calls as required by `rawnode.go:31-33`.

The reference currently treats Storage reads *inside* a core call as atomic with that call. A harness exposing a concurrent Compact between those separate reads requires a reference extension before acceptance. Do not hide those events or remove post-state fields to get a trace accepted. The chosen reference caller also finishes outgoing publication and queues application before Advance, while allowing early Advance before actual application. Other legal caller orders, asynchronous commit-only MustSync=false completion, and arbitrary internal multi-entry proposals are coverage gaps, not invalid implementation behavior.

**Normalization.** Keep source terms, indexes, exact entry identities and dummy boundaries. Byte payloads may be replaced with symbolic request IDs only with an independently logged weight and encoded-size mapping that preserves every tested comparison, including the oversized-first-entry allowance. The base defaults use unit abstract bootstrap/no-op weights. The real harness overrides BootstrapPayload, BootstrapEncoded and EmptyEncoded with measured protobuf sizes (6, 14 and 6 in the collected bounded domain); select and document compatible harness size limits and prove the mapping for each collected trace. If actual relative sizes cannot satisfy the abstraction, extend the entry/config constants rather than coerce the trace. Do not map all proposal weights to one class. Message order within a map visit is abstracted by a bag; batching boundaries and inflight endpoints remain checked.

**Caller interpretations.** Use Strict+Atomic first, plus the public-interface conservative storage-view ordering (ApplySnapshot, Append, SetHardState). Then collect separately labeled allowed early-application schedules, same-batch sends under the sequential README persistence rule, and Node versus RawNode cases. The Parallel persistence interpretation and absent-removal legality must remain marked unresolved until reviewed. `AppliedAdapter` must really return a coherent recovered ConfState and Config.Applied; MemoryStorage alone does not do it.

**Scenario families.** Implement H1 elections/options; H2 transfer/catch-up/timeout; H3 proposal/commit/ordinary overwrite; H4 small batch/quota, duplicate/reordered valid traffic; H5 learner/add/promote/remove and deterministic cancellation with delayed callbacks; H6 snapshot lifecycle/status/availability; H7 both Ready wrappers with independent rates; H8 join/restart/storage images; H9 actual quorum-read responses including delayed application; H10 rejection/cancellation/retry/quiescence. All use public APIs and actual emitted messages. No direct role/progress injection and no candidate-specific operational reproducer is authorized.

**Negative trace artifacts and nonvacuity.** After genuine normal traces validate, make separate controlled invalid *trace files*: change a returned context/ID; change an applied committed command; claim a mismatched Advance endpoint; drop a completed persistence entry; alter a remote Match witness; count a learner in a read confirmation. Record whether rejection was schema, transition/post-state correspondence, or the named safety property. Schema rejection alone does not validate an oracle. Record branch/antecedent counts for successful election, PreVote continuation, configuration acceptance/rewrite, actual early Advance, conflict repair, quota saturation/refill, full/fast snapshot restore, durable restart, queued/singleton reads and real responses. Do not turn unvisited properties into a passing coverage report.

No harness, implementation trace, general-contract negative implementation-trace execution or post-convergence hunt is claimed delivered by this specification-generation phase. Keep all subsequent logs/artifacts and let the real CI workflow decide its state; never manipulate `current` or verdicts.

The two-event model-derived fixtures under `output/adapter-*-synthetic.ndjson` test only the codec and mandatory post-state gate. Their accepted/rejected outcomes are recorded separately in `validation-results.md`; they are not implementation validation.

## Harness-phase adapter alignment

Every real record now includes `tag: "trace"` and a real UTC `ts`, as required by the pinned harness skill. Flat action names and the typed params/post codec are preserved. `Trace.cfg` also selects the observed initial timeout assignment, with an explicit check that each timeout is in the original legal interval. Full Init post-state equality is retained; because timeout is mandatory in that equality, this is equivalent to enumerating all initial assignments and filtering afterward. The default base/MC initializer still enumerates the original assignment set. See `../harness/CORRESPONDENCE.md` for the byte-size mapping and results.

## Optional small-round decision observers

`QualityTrace` consumes the existing event parameters and complete pre/post states; no new source hook, trace field or public call is required. `QualityEvent` observes incoming vote requests, Hup calls/triggered ticks, leader-local or equal-term transfer decisions, proposal request/entry identity, and committed configuration callbacks. Its separate `quality` variable contains only the latest action's audit records and is not part of `Observed`. Full base actions and full post-state matching remain mandatory. Source contracts, exercised branches and gaps are recorded in `quality-improvement.md`.

`QualityDecisions` inputs and sensitivity mutants are formal decision-context fixtures, not implementation traces. `QualityManagement` uses exact validated trace post-states as explicitly named post-commit starting windows; its alternate callback/Advance schedules are model executions. Future harness work should retain the current complete fields and add real witnesses for the unvisited interactions listed in `remaining-validation-work.md`.

## Integrated Quality observers (no trace-schema change)

Default Trace replay now obtains decision/effect observations from the public base action wrappers. Existing pre/post fields supply vote/campaign/transfer decisions, outgoing vote-message bag deltas and request-correlated configuration effects. Every ordinary Tick is observed before eligibility is evaluated. The quality ghost is never part of production post-state matching and requires no Go instrumentation change. See quality-integration.md for checked paths and the missing real-trace witnesses.

## Incremental instrumentation — revision 16c5274

The same Category-A envelope and full-post comparison now target source revision `16c5274b589aa75c634a1a5f2b05cf66aaf37dcc`. RawNode setup observes `NewRawNode(Config)` separately from the real `Bootstrap(peers)` call. Ready capture reads `rn.prevHardSt`/`rn.prevSoftSt`: RawNode accepts messages, read states, HardState and SoftState only in Advance, while Node accepts its send/read buffers at Ready delivery and commits previous-state cursors at Advance.

Configurations now contain `voters`, `outgoing`, `learners`, `learnersNext`, and `autoLeave`. Entries additionally contain ordered `changes` and `transition`; `InvokeV2` parameters carry those fields, identity, payload size, encoded size, and retry parent. The caller reconstructs its application ConfState by applying every committed V1/V2 callback through the real `confchange.Changer`; it never copies the core result as an application oracle. Empty automatic-leave entries are observed as payload size 2 and encoded Entry size 10.

The fresh affected paths are `RawNode.Bootstrap`, `raft.advance` automatic leave, `applyConfChange`/`confchange.Changer`, joint `tracker.Config`/quorum consumers, snapshot ConfState capture, and `newRaft`/`restore` reconstruction. Three new traces cover explicit enter/read/leave, implicit enter/Advance auto-leave, and persisted joint snapshot plus crash/restart. The restart trace intentionally records the source's loss of `NodesJoint`, `LearnersNext`, and `AutoLeave`; instrumentation does not repair or normalize that post-state.
