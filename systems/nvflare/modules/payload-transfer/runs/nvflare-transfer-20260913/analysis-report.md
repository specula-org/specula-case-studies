# Code Analysis Report: nvflare-transfer

## Result and evidence boundary

The supplied receiver-confirmed, explicit-receiver implementation distinguishes producer serving from receiver success and computes full-payload success/quorum over the declared receivers. No new false-success receipt or phantom quorum was established in that main mode. Three current functional candidates remain after source re-reading and compensation checks:

| ID | Finding and consequence | Strength / next verification |
|---|---|---|
| MC-1 | Executor submission can enqueue settlement and then raise; inline fallback plus queued execution can repeat transaction/outcome callbacks and release attempts. The retained outcome still records once. | Strong, independently source-grounded; model queue/settlement ownership, then local regression |
| MC-2 | Pipelined cancellation can commit receiver FAILED while an admitted EOF serve publishes COMPLETED progress first, permanently suppressing the later FAILED progress event. Strict receipt remains FAILED. | Source-grounded public progress discrepancy; model event publication, then local regression; no demonstrated trainer false success |
| TV-1 | Multi-target fire-and-forget does not propagate target count/identities into its download transaction; default count 1 can retire sources before another receiver acquires them. | Strong source-grounded caller-path candidate; direct local regression, separate from main explicit-receiver model |

These are code-analysis candidates, not model counterexamples, reproduced defects, or confirmed production incidents. Existing test assertions and upstream test reports are identified as such. This phase ran **zero tests, zero TLC jobs, and zero trace validations**. The primary handoff is [modeling-brief.md](modeling-brief.md).

## Step 0: classification, pin, and methodology

- **Category A (Distributed / Message-Passing)**: requests, terminal replies, confirmations and cancellation coordinate producer/receiver state. Threaded ownership, cancellation, callback and reclamation boundaries additionally use the Category B analysis reference. No BFT consensus or adversarial participant model applies.
- Source: `/home/ubuntu/nvflare-runs-20260913/source-transfer`, HEAD `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; clean before and after investigation. Origin is `https://github.com/NVIDIA/NVFlare.git`.
- Methodology read in full: experiment-local `skills/code_analysis/SKILL.md`, `guide.md`, shared deep analysis, distributed analysis, concurrent analysis, bug archaeology, modeling-brief format, and HashiCorp Raft format example. Experiment AGENTS, source AGENTS/CLAUDE and supplied guidance were read. BFT reference does not apply.
- The selected skill explicitly requires parallel agents. Separate agents verified issue batches and commit history, then independently read core source/caller files; the parent re-read candidate paths and synthesized the findings. No external comments, publications, source repairs or unrelated workspace changes occurred.
- Initial shallow history was completed with `git fetch --unshallow --no-tags origin`; checkout HEAD/files remained unchanged. History coverage is complete for reachable local refs after that fetch, not a claim to every deleted remote branch.
- Prior memory was consulted only for the previous pilot's evidence boundary. All source, configuration and finding claims below were established on this checkout; the earlier pilot is not validation evidence.

Source references below are relative to the source root. Short transfer filenames mean `nvflare/fuel/f3/streaming/`; `via_downloader.py` means `nvflare/fuel/utils/fobs/decomposers/via_downloader.py`; `cell.py` means `nvflare/fuel/f3/cellnet/cell.py`; `api.py` means `nvflare/client/cell/api.py`. Short test filenames are under `tests/unit_test/fuel/f3/streaming/`.

## Phase 1: reconnaissance

### Core map and complete reading coverage

| Core file | Lines | Responsibility / relevant atomicity boundary |
|---|---:|---|
| `download_service.py` | 2347 | Transactions, refs, handlers, receiver budgets, monitor, operation gate, receipts/waiters, Consumer download loop |
| `transfer_outcome.py` | 271 | Frozen per-ref/aggregate snapshots; FINISHED vs completed; whole-payload receiver intersection |
| `transfer_progress.py` | 465 | Terminal vocabulary and monotonic progress tracker; progress advancement is distinct from request activity |
| `obj_downloader.py` | 114 | Public constructor forwards receiver/budget/callback options; waiter facade |
| `file_downloader.py` | 221 | Ordinary file producer/Consumer and application-owned file lifetime |
| `shutdown.py` | 40 | DownloadService → active streams → retry scheduler → executors shutdown dependency order |
| `cacheable.py` | 260 | Chunk cache versus base source lifetime; per-object lock; production outside lock; pipeline-capable Consumer |
| `stream_utils.py` | 166 | CheckedExecutor queue/submission/shutdown semantics needed by settlement fallback |
| **Total** | **3884** | All eight read completely; helper histories included in final core census |

Full adjacent reads: `via_downloader.py` (1097), `np_downloader.py` (142), `docs/design/client_api_execution_modes.md` (516). Full test reads include confirmation (995), receiver budgets (472), outcomes (1019), waiters (235), pass-through E2E (293), executor helpers (167), and shared download helpers/confirmation fixture. `download_service_test.py` and tensor lifetime implementation received targeted reads only; no full-file audit is claimed for them.

Selective minimum integrations: Cell dispatch/encoding/broadcast/fire-and-forget; CoreCell FOBS context copying; StreamCell `send_blob` facade; Client API send/wait/resource-clear and receiver-header normalization; auxiliary send; Swarm/local-consumer receiver stamping; managed-executor source tracking; tensor prefetch/release. The delegated read ledger is [deep-callers.md](analysis-evidence/deep-callers.md). Serializer/byte-stream algorithms, trainer process-management state machines and numerical behavior were not expanded into analysis targets.

### Protocol map

1. The caller prepares all Downloadable refs, registers them in a transaction, then sends a reference envelope (`download_service.py:78-85`; `via_downloader.py:712-746,774-826`; `cell.py:480-488`). There is no supported post-completion append lifecycle (`transfer_outcome.py:44-45`).
2. A receiver pull is admitted while `_tx_lock` protects lookup and `begin_op`; production executes outside the table lock. Requests update global transaction activity and that receiver's transaction-wide activity (`download_service.py:1664-1716`).
3. A confirmed-mode terminal serve stores a provisional status and nonce; no final receiver status yet. Consumer success calls `download_completed` before sending SUCCESS confirmation; ordinary finalization exception sends FAILED (`download_service.py:369-423,2273-2283`).
4. Confirmation finalizes one receiver/ref; cancellation finalizes that acquired receiver across all refs. First final status wins. Both leave the operation gate before attempting eager retirement (`download_service.py:313-335,1782-1845`).
5. The monitor enforces receiver budgets outside `_tx_lock` under operation admission, then classifies finished/expired transactions under the table lock (`download_service.py:1848-1907`). FINISHED counts final failures too.
6. A winning terminator unlinks the transaction and refs, installs a termination marker, then settles outside `_tx_lock`. FINISHED adds requester-specific terminal tombstones; deletion/timeout do not (`download_service.py:1398-1454,1525-1541`).
7. Settlement closes/drains admitted operations, snapshots outcome, invokes callbacks, attempts releases, then records an immutable receipt and wakes waiters (`download_service.py:895-1002,1579-1595`). Eager FINISHED settlement adds an executor submission boundary before this sequence.

### Locks and action granularity

| Protected state | Exact boundary | What remains independently scheduled |
|---|---|---|
| Transaction/ref tables and retirement | `_tx_lock`; registration nests `_outcome_lock` (`download_service.py:1349-1374,1420-1423,1525-1541`) | Production, user callbacks, settlement execution |
| Final status, pending confirmation and all-done latch | One `_progress_lock` section (`:313-335`) | Downloaded callbacks, terminal progress construction and delivery |
| Ref progress sequence/counters/terminal latch | `_progress_lock` (`:529-542,566-623`) | User progress callback after event construction |
| Receiver acquisition/latest request and byte totals | `_stats_lock` (`:441-450,777-785,861-863`) | Budget decision → finalization; global `last_active_time` is separately assigned |
| Live operation admission/drain | `_ops_cond` (`:822-851`) | Producer call internals and callbacks of admitted operations; settlement itself is not an admitted operation |
| Outcome owner, retained receipt, registered waiters | `_outcome_lock` (`:1544-1565,1579-1619`) | Earlier outcome callback and source release attempts |
| Chunk cache/base reference | Cacheable lock (`cacheable.py:99-161`) | `produce_item` runs after lock release; running prefetch can retain data |
| Executor submission vs shutdown | CheckedExecutor lifecycle lock plus Python executor locks (`stream_utils.py:49-81`) | Work can already be queued when thread startup raises |

Developer-signal search covered TODO/FIXME/HACK/XXX/BUG/WARN in selected core files. No such markers established a new defect; substantive explanatory comments, existing tests and historical reviews were followed instead. Lock-based Python interleaving is the relevant substrate, not weak-memory/CAS behavior.

### Actual receiver and timeout modes

| Caller / mode | Actual declaration and conclusion |
|---|---|
| Main modeling configuration | Explicit nonempty receiver identities; constructor deduplicates/validates count, derives count when supplied as zero (`download_service.py:703-727`). Both peers advertise/enable confirmation. |
| Direct `Cell.broadcast_request` | Uses target count and exact targets (`cell.py:303-317`). |
| Pass-through broadcast | Uses first-hop target count but omits identities because final materializers differ (`cell.py:303-317`). This is count-only, not explicit identity mode. |
| Managed trainer result | Task header supplies ultimate receiver identities; if absent, actual call uses None/count 1 (`api.py:501,536-537,869,926-933`). Backend monitoring fallback is not proof those identities reached the sender. |
| Attach / local materialization | Attach names CJ (`api.py:498-501`); local consumers stamp CJ; Swarm stamps aggregator (`client_api_executor.py:436-444`; `swarm_client_ctl.py:969-970`). |
| Generic multi-target fire-and-forget | No target-derived receiver declaration at encode; default count 1 is TV-1 (`cell.py:344-379`; `via_downloader.py:779-807`). |
| Unknown count 0 without identities | Cannot become is_finished/COMPLETED; timeout/deletion terminates it (`download_service.py:875-893`; `transfer_outcome.py:185-202,250-259`). |

Receiver confirmation defaults enabled, cached at first use; each request's capability and producer switch jointly decide confirmation. Legacy peers/disabled switch retain producer-served truth, without the stronger consumer-finalization claim (`download_service.py:209-244,1707-1709,1738-1748,2073-2105`). The low-level `request_download_chunk` helper also sends no confirmation capability (`:1963-1987`).

Receiver acquire/idle budgets are optional application-config or per-transaction settings (`download_service.py:247-267,728-731`). ViaDownloader does not explicitly enable them. Its default source inactivity floor is generic `streaming_idle_timeout=600` seconds, with applicable per-type override and requested timeout clamped to that floor (`transfer_progress.py:26-31`; `via_downloader.py:584-610`). Receiver per-request timeout defaults to 600 seconds unless configured (`via_downloader.py:981-985`). These are code defaults, not a claim about a deployed configuration.

Global transaction timeout is sliding inactivity since any receiver activity, not absolute age (`download_service.py:112-117,774-775,1880-1883`). Receiver idle uses that receiver's latest pull on any ref; a busy sibling ref of the same receiver properly satisfies acquisition/idleness (`:441-515,767-772`). Budgets must allow healthy request/backoff/finalization quiet periods; no acquisition deadline can identify an unnamed never-started receiver. The five-second monitor cadence, callback scheduling and drain time add observation delay; none of these is a hard end-to-end lifetime bound.

## Phase 2: exhaustive core history and discussion verification

### Coverage statistics

| Evidence class | Actual coverage |
|---|---|
| Final eight-core history | 33 unique all-ref commits; all classified and core hunks inspected; 21 bug-bearing/mixed commit contexts analyzed, 12 explicit exclusions |
| Keyword/non-keyword coverage | 29/33 match the permissive full-message keyword scan; all 4 nonmatches examined, avoiding placeholder “Fixes” and formatting false positives |
| Core + adjacent history collection | 59 distinct commits including `datum.py` and `via_downloader.py`; 26 outside final core census are discovery/screening, not 26 extra fully analyzed fixes |
| GitHub discovery | 21 keyword/label searches; 176 distinct actual issues after cross-agent deduplication including linked #5099 |
| Full issue discussions | 30 actual issues: full available body and comments, including empty threads; no PR substituted for an issue |
| Issue classifications | 15 confirmed historical/adjacent bug classifications (one security-scope exclusion), 4 design/observability, 5 uncertain/mixed, 6 user-error/disputed/expected-behavior exclusions |
| Current in-scope issue confirmations | 0 new current defects established from issue discussions; #3853 and #5099 provide direct historical/caller context and are fixed at this pin |
| Historical PR discussions | 30 complete PR discussions: body, general comments, reviews, paginated inline comments; branch ports distinguished from ancestors |
| Open PRs | All 15 inventoried by intent/files; both open functional bug-fix PRs (#5191/#5073) fully discussed and excluded by scope; 0 directly fixes selected lifecycle |
| Runtime/formal evidence | 0 local tests, 0 bug reproductions, 0 TLC runs, 0 trace conformance runs |

The 146 discovery issues outside the 30 full reads are not cited as verified findings. Thirty full threads meet the methodology's breadth aim, but do **not** mean thirty relevant DownloadService defects: 28 full reads were excluded as current targets by component/era/evidence boundary. Full text was used; external attachments were not downloaded. One security thread was encountered during broad screening and excluded without follow-on work; another security inventory hit was not deeply read. No vulnerability reproduction or exploit work occurred.

Raw queries, counts, fetched full discussions and classifications are preserved under [issues-a](analysis-evidence/issues-a/issues-report.md) and [issues-b](analysis-evidence/issues-b/review.md). Issue-A independently cross-checked every review against paginated REST review bodies. The aggregate census is [coverage.json](analysis-evidence/coverage.json).

### Hotspots

| File | All-ref commits | Bug-bearing/mixed contexts touching file |
|---|---:|---:|
| download_service.py | 15 | 11 |
| transfer_outcome.py | 2 | 2 |
| transfer_progress.py | 1 | 1 |
| obj_downloader.py | 8 | 3 |
| file_downloader.py | 6 | 1 |
| shutdown.py | 1 | 1 |
| cacheable.py | 10 | 5 |
| stream_utils.py | 13 | 9 |

These overlap and count backports separately. A mixed PR can fix an adjacent caller while touching a core file only for logging/performance; 21 is **not** a count of unique bugs or 21 defective core hunks. The complete per-commit ledger records root cause, affected component, severity context and current disposition: [history-review.md](history-review.md), [expanded scope](analysis-evidence/history/expanded-scope.json), and saved file-scoped patches. This includes every significant core fix, not a sampled set.

### Mechanism groups and known fixes

| Mechanism | Historical evidence and current boundary |
|---|---|
| Premature source release / envelope vs payload | #4247 → main #4327; #4270 removes message-root deletion racing asynchronous secondary downloads. Present behavior keeps sources until transfer termination. |
| Serving vs receiver finalization | #4853 introduces aggregate outcome; #4865 adds confirmation, receiver identities, full-payload quorum, immutable snapshots and release-before-waiter ordering. Their old states are not current MC targets. |
| Last-confirm settlement / cancellation | #4906 retires completed transactions immediately after confirmation end_op and dispatches settlement; #5097 adds cancellation across sibling refs and source-failure interruption. MC-1/MC-2 inspect current compositions, not missing historical guards. |
| Retry and duplicate terminal serving | #4167/main #4328 add same-state TIMEOUT retry; #4708/main #4712 add requester dedup and FINISHED-only terminal tombstones. Current source retains both. |
| Progress clocks / shared locks | #4736 establishes scoped progress, callbacks outside global table lock and atomic object registration. #4865 changes receiver idle to transaction-wide per-receiver activity. |
| Pool ownership / callback dependency | #4171/main #4328 separate stream and callback pools; #3190/#1995 introduce shutdown handling; #5097 explicitly preserves a non-shutdown post-enqueue error. Current DS fallback is separately reviewed in MC-1. |
| Caller count and registration | #4024/#4025 propagate broadcast count; #4973 removes alias-driven duplicate transaction creation. Current fire-and-forget alternative still requires analysis (TV-1). |
| Fixed adjacent representation issues | #4725/#4729 reject incomplete downloaded items; #4707/#4718 repair shared-container mutation. Serializer internals are outside this model and fixes remain intact. |

All referenced PR discussion evidence above is in the archived ledgers. Additional core git-only context is explicitly labeled in the history report; its PR number identifies commit provenance, not proof a full discussion was read. There is no paper to compare against. Reference comparison therefore uses current API documentation, actual callers, and divergent supported implementation paths (confirmed/legacy, direct broadcast/fire-and-forget, normal/shutdown/failed-submission settlement).

### Full-thread classification and false-positive handling

| Full issue threads | Classification and why they do or do not establish this target |
|---|---|
| #3853, #5099 | Direct historical download-timeout and accepted-source caller issues; linked repairs are ancestors of the pin. |
| #5207, #52, #147, #151 | Confirmed logging-stream lifecycle issues; different service or removed feature, not current payload receipt evidence. |
| #3671, #1821 | Confirmed underlying transport/clock issues; byte-transport implementation excluded. |
| #3822, #193, #2427 | Confirmed external process/client teardown issues; whole management lifecycle excluded. |
| #4451, #2166 | Confirmed serialization whitelist/job-metadata memory issues; wrong subsystem for source ownership finding. |
| #2326 | Original report involved resource/config; a separate heartbeat-blocking read-loop defect was acknowledged. Adjacent historical mechanism only. |
| #258 | Security/HCI thread encountered and excluded; no further exploration or reproduction. |
| #3578, #238 | Logging/observability design requests; no transfer correctness evidence. |
| #3730, #2461 | Acknowledged deployment-timeout/GC design limitations; do not imply a present DownloadService defect. |
| #2933, #2165, #145, #266 | Uncertain root cause or empty thread; titles are not accepted as findings. |
| #316 | Original timeout explained as a configured/default AdminAPIRunner bound; later separate report unresolved. |
| #157, #189, #249, #2601, #1336, #203 | Six explicit false-positive/config/expected-behavior exclusions: host OOM capacity, authentication timeout, application memory failure, missing dependency, expected layout/exit logging, and disabled IDE autosave respectively. |

Each issue's full rationale and link appears in the per-agent ledgers. Scope exclusion does not label an acknowledged original bug false. PR-level objections were also checked: #3873 logger concern was compensated by Consumer initialization; #4171 alleged new callback stream retention already existed; unsupported-Python complaints in #4708/#4736 did not apply to the branch's supported versions. Unanswered bot comments are uncertainty, not maintainer confirmation.

Open PR inventory: #5288, #5286, #5285, #5284, #5283, #5274, #5273, #5267, #5266, #5263, #5256, #5240, #5226, #5191 and #5073. The first thirteen are examples/research, presentation, dependencies or provisioning/credentials; #5286's adjacent API change is log severity only. Fully read #5191 concerns scheduler reservation handling and #5073 task filters/empty DXO. None is a pending fix for the selected transfer lifecycle. This is a GitHub snapshot collected on 2026-09-13, not a future-current assertion.

## Phase 3: source verification and findings

### Priority questions: contracts, answers, and remaining gaps

| Question | Source-grounded answer | Remaining verification |
|---|---|---|
| 1. Terminal served before Consumer completion? | Ordinary confirmed mode records only pending status until Consumer finalizes and confirms (`download_service.py:369-423,2273-2283`). Lost confirmation fails closed on applicable budgets/global inactivity. Legacy producer-served status intentionally means less. | MC-2 concerns a source progress notification under cancellation, not a newly successful receipt. No main-mode strict premature-success receipt found. |
| 2. Different receivers finish different refs? | Explicit full success checks every declared identity/ref; `quorum_met` intersects ref success sets and declared identities (`transfer_outcome.py:169-202`). FINISHED includes final failures; completed is stronger. | Count-only fallback differs (TV-3); multi-target caller underdeclaration is TV-1. No explicit-mode phantom quorum found. |
| 3. Confirm/cancel/timeout/delete overlap? | Final status map commits once under ref lock; operation gate drains admitted operations; table retirement and receipt owner each choose one winner (`download_service.py:313-335,822-851,1420-1423,1579-1595`). | MC-1 distinguishes one retirement/receipt from duplicate settlement effects; MC-2 separates final map and event emission. Forced-drain late work is an acknowledged exception. |
| 4. Healthy receiver masks stalled/never-started receiver? | Configured receiver budgets use individual receiver activity across the transaction even without progress callback; acquisition needs identities (`download_service.py:441-515,857-873`). Same receiver's sibling-ref progress correctly counts. | CR-3 warning is wrong about sliding inactivity. Check/write gap alone is linearizable as expiration-before-resumption, not evidence of premature failure. |
| 5. Exceptions/cleanup and waiter ordering? | Ordinary Exceptions are caught; release attempts precede recording; outcome_cb runs before release. Shutdown None is resolved before cleanup. Actual Client API waits for every strict receipt before resource clearing (`download_service.py:645-655,895-1002,1463-1497`; `api.py:624-648`). | MC-1 can repeat effects after first receipt. No unconditional physical-reclamation or globally bounded hung-callback shutdown guarantee exists. |

### MC-1 — partial executor submission can duplicate settlement effects

**Contract:** `transaction_done` documents exactly-once settlement, and a non-None waiter receipt is intended to follow its complete callback chain and release attempts (`download_service.py:895-903`). Public custom callbacks are not required to be idempotent. Built-in Cacheable cleanup is largely idempotent, which limits but does not remove the public callback issue.

**Current entry path:** valid confirmed receiver completion or acquired-receiver cancellation calls `_finish_transaction_if_complete`, which retires the transaction once under `_tx_lock`, then calls `_submit_finished_settlement` (`download_service.py:1411-1446,1805-1811,1838-1844`). There is no unsupported late ref registration or dishonest participant.

**Source-derived interleaving, not an executed reproduction:**

1. Callback executor submission enqueues the settlement work item.
2. Starting an additional executor thread raises an ordinary non-shutdown RuntimeError. The work item remains queued. This behavior is stated by `CheckedExecutor` (`stream_utils.py:71-78`), pinned by the existing test's assertions (`stream_utils_test.py:143-167`), and confirmed by reading the local CPython 3.14.4 implementation.
3. DownloadService's broad RuntimeError handler treats this as a failed submission and executes inline settlement (`download_service.py:1435-1446`).
4. A live worker later becomes available, or a later successful submission starts a worker, and the queued settlement runs too.
5. `_Transaction.transaction_done` has no once-start guard. Each invocation can call the per-ref done callbacks, transaction callback, outcome callback, and each source's release (`download_service.py:895-1002`). They can occur sequentially or concurrently.
6. The owner guard drops the second final receipt recording (`download_service.py:1582-1585`), after those effects. Thus stored receipt/waiter resolution can remain single while public callback effects and release attempts repeat, potentially after the first receipt wakes its observer.

**Compensation checks:** one table retirement does not imply one execution after partial submission; `_ops_closed` excludes serving but not settlement; `_settlement_complete` is assigned at the end and not tested at entry; receipt immutability prevents mutation but not repeated calls; the termination marker guards ID reuse, not settlement entry. Existing `stream_utils_test` intentionally preserves queued work and hence cannot compensate at the caller.

**Impact boundary:** duplicate public notifications/custom cleanup and violated post-wait ordering are plausible functional consequences. Do not claim two retained outcomes, two receiver-map writes, arbitrary corruption, or an observed production failure. MC-1 is not a replay of the old shutdown rejection: it depends on the current live executor preserving a task whose submission raised after enqueue.

**Next:** model enqueue, submit result, fallback, worker execution and per-executor callback/release phases separately. Then run a bounded local regression at this supported runtime boundary, checking callback/release counts and one retained receipt. Local Python version/source excerpt is preserved in [stdlib-executor-source.txt](analysis-evidence/history/stdlib-executor-source.txt); no thread failure was injected during this analysis.

### MC-2 — cancellation status can lose the race to EOF progress

**Contract/observer:** confirmed-mode source progress describes receiver truth (`download_service.py:413-423,1733-1736`); `ObjectDownloader` publicly accepts source per-ref/receiver progress callbacks (`obj_downloader.py:46-50`). The supported observer here is that callback. Current CellClientAPI's source progress callback is a no-op, and the actual send barrier checks strict outcomes (`api.py:485-487,624-648`).

**Entry:** ItemConsumer opts into stable-state pipelining (`cacheable.py:235-252`); the receiver submits the next pull before consuming the current DATA reply. If ordinary consume failure or cancellation occurs, `Future.cancel()` cannot retract a producer request already running; the receiver sends negotiated cancellation (`download_service.py:2300-2331`).

**Source-derived interleaving, not an executed reproduction:**

1. Cancellation finalizes the acquired receiver FAILED on the ref under `_progress_lock` (`download_service.py:313-335,1814-1839`).
2. The lock is released before downloaded callbacks return and before `obj_cancelled` emits FAILED progress (`:337-357,425-429`). Ordinary preemption is enough; no hung callback is required.
3. The already-admitted terminal EOF producer call returns. `obj_served(expect_confirm=True)` sees the final receiver and returns None instead of a new nonce (`:391-395`).
4. The handler's no-nonce branch selects COMPLETED from the produced EOF, despite the existing FAILED status (`:1733-1748`). It does not distinguish “already final” from actual legacy mode.
5. The progress terminal latch accepts this first terminal event and later drops the cancellation's FAILED event (`:587-588,611-612`). The receiver-status map and retained receipt remain FAILED.

**Compensation checks:** final-status dedup and aggregate truth remain correct; drain waits for admitted operations but does not serialize the status/event gap; sequence numbers cannot repair the chosen first terminal state. No assumption that callbacks block is needed. `_downloaded_to_all_called` guards duplicate callback invocation but does not select the correct event state.

**Existing test gap:** cancellation-vs-inflight test (`receiver_confirm_test.py:210-243`) covers a DATA response and no progress callback; pipelined abort test (`:863-907`) uses an inert fake pending request; late duplicate serve test (`:341-353`) calls `obj_served` directly and does not execute the handler's progress branch. They do not cover this combination.

**Next:** MC-2 preserves the unlocked callback gap and already-running EOF request. Local confirmation should observe progress and final maps together on supported handler paths. Result severity remains narrower than incorrect receipt success; whether applications treat progress as advisory deserves review, without deleting the source-grounded discrepancy from the audit.

### TV-1 — multi-target fire-and-forget underdeclares payload receivers

**Supported path:** AuxRunner documents timeout 0 as fire-and-forget, derives every target job FQCN and passes the complete list to `Cell.fire_and_forget` when `bulk_send=False` (`nvflare/private/aux_runner.py:349-422`). Cell dispatch chooses the streaming wrapper for an ordinary non-excluded channel (`cell.py:49-55,246-263`).

**Omission:** `_fire_and_forget` encodes once using only `get_fobs_context()` before looping over targets (`cell.py:344-379`). This context is a copy, not target-derived receiver metadata (`core_cell.py:570-579`). ViaDownloader therefore uses its default count 1/unknown identity (`via_downloader.py:617-622,779-807`). In contrast, `_broadcast_request` supplies the count and exact identities for direct receivers (`cell.py:303-317`).

**Observable possibility:** with an ordinary externalized payload and two cooperative receivers, the first can consume/confirm all refs before the second begins acquisition. Current count-based `_completion_reached_locked` then considers each ref finished, final confirmation retires the transaction, and refs are removed (`download_service.py:359-367,875-893,1411-1425,1782-1811,1525-1539`). The second receiver has no successful tombstone and gets INVALID_REQUEST (`:1687-1697`).

**Compensation checks:** StreamCell `send_blob` sees the already-encoded payload and cannot reconstruct target membership (`nvflare/fuel/f3/stream_cell.py:108-145`); `encode_payload` serializes only once (`nvflare/fuel/f3/cellnet/utils.py:133-165`). Per-receiver budgets cannot repair a count/identity declaration that never named the second receiver. Raw byte payloads with no externalized refs do not exercise this issue.

**Classification:** source-grounded current functional caller candidate; local regression is better than TLA+ because the omission is argument propagation. Confirmation can remain enabled; this is a separate count-only caller path, not evidence against correct explicit receiver declarations. Historical #4025's review raised an alternate-send-path question without establishing a repair; the current source supplies this finding's evidence. No reproduction was run.

### Other findings retained for local testing or review

| ID | Exact evidence | Assessment / next action |
|---|---|---|
| TV-2 | MC-1/MC-2 source paths above | Implementation confirmation remains pending; add local targeted regressions only after the model/contract findings are classified. |
| TV-3 | Count-only `_all_receivers_succeeded` independently checks counts on each ref (`transfer_outcome.py:197-202`), while explicit-k quorum intersects (`:169-179`) | Disjoint successful receiver sets can yield count-only completed but no common receiver; clarify caller's expected identity contract. No main explicit-mode defect claimed. Pure status-matrix/caller test, not an old-fix MC hunt. |
| CR-1 | `get_transfer_waiter` intentionally accepts retained expired receipt (`download_service.py:1554-1558`); `get_transaction_outcome` expires it (`:1604-1608`) | Known #4865 review item; current code comment states intent. Reconcile API consistency/retention documentation; not an old-attempt takeover. |
| CR-2 | `get_acquired_receivers` looks only in live tx table (`download_service.py:1568-1576`), which is removed before callbacks/receipt | Known #4865 review item: query becomes empty while settlement/waiter may be pending. Clarify live-only versus cumulative semantics; no actual Client API misuse found. |
| CR-3 | Budget >= transaction timeout warning says “never fire” / “effectively disabled” (`download_service.py:736-740`) | Known #4865 review item; false diagnostic under sliding global inactivity. Another receiver can keep global clock fresh while this receiver's larger budget expires. Values are still enforced. |
| CR-4 | Cacheable comment declares release/produce race impossible (`cacheable.py:133-140`) | Too strong for documented forced-drain path (`download_service.py:905-909,1711-1722`). Correct explanation; do not infer an independent current source-loss defect merely from intended forced cleanup. |

### Callback, source and waiter obligations in detail

| Observation/path | What it establishes; what remains outside the guarantee |
|---|---|
| `FINISHED` / `downloaded_to_all` | Expected receivers have final statuses, including failures (`download_service.py:329-367,875-893`). The callback name is not an all-success certificate. |
| `outcome.completed` | With explicit identities and supported confirmation, every declared receiver succeeded on every ref. Known DELETED/TIMEOUT can still be completed when successes were already final (`transfer_outcome.py:242-259`). |
| `outcome.quorum_met` | An informational common-receiver subset meets k; it does not cause early source settlement and does not weaken completed (`transfer_outcome.py:137-179`). May be true for a partially failed/aborted transfer. |
| `outcome_cb` | Receives immutable computed verdict after transaction callback, before source release; cannot be used as a release barrier (`download_service.py:966-999`). |
| Non-None waiter outcome | Normal callback chain and each release attempt precede receipt recording. Caller must inspect outcome status; a waiter can return a failed/aborted receipt (`download_service.py:1075-1099`; `api.py:624-648`). MC-1 challenges repeated later effects. |
| Timed wait returns None | May still be in flight. Actual caller checks done and re-reads outcome to close a polling race (`api.py:629-640`). |
| `done()` with None | Unknown/expired-absent ID or shutdown terminally resolved without a receipt; shutdown deliberately resolves this before cleanup (`download_service.py:1463-1497,1559-1563`). Not delivered success. |
| Callback/release raises ordinary Exception | Each hook is attempted safely; raising one hook does not skip siblings/release/recording (`download_service.py:645-655,955-999`). Failed custom cleanup does not change already-proven receiver delivery. |
| Outcome computation raises | Direct fail-closed construction retains metadata and certifies nothing (`download_service.py:803-820,917-933,991-999`). Existing persistent-failure tests are historical test-source evidence, not execution here. |
| Internal recording itself fails | `_invoke_cb_safely` contains it, but no unconditional runtime-resilience theorem follows. Existing recording-failure test explicitly leaves waiters pending until shutdown (`transfer_outcome_test.py:474-500`). Do not label injected arbitrary internal failure as a demonstrated ordinary callback defect. |
| Cache clearing | Clears chunks without dropping base source; later production may regenerate from source (`cacheable.py:92-120,122-161`). |
| Source release | Cacheable drops its infrastructure `base_obj` reference; FileDownloadable inherits a no-op release and caller owns the path (`cacheable.py:109-120`; `file_downloader.py:37-83`; `download_service.py:193-201`). |
| Physical GC | Local `base_objs` remains in the settlement frame until return; application refs and running tensor prefetch tasks may retain data (`download_service.py:953,998-1002`; `tensor_downloader.py:79-106`). Waiter is not an immediate zero-memory certificate. |
| Drain bound | At 60 seconds, settlement may proceed with old operations still running; ID marker prevents reuse until both settlement complete and old operations exit (`download_service.py:257-260,905-909,1349-1359,1500-1522`). |
| Shutdown bound | `shutdown_f3_streaming` orders stages and attempts each after Exceptions (`shutdown.py:20-40`); `stream_shutdown` calls executor shutdown(wait=True) with no timeout (`stream_utils.py:160-163`). The operation bound is not a global bound for hung hooks/workers. |

### Explicitly rejected hypotheses

1. **Serve EOF alone gives confirmed receipt success:** contradicted by pending/nonce/finalization code. Legacy/disabled confirmation is intentionally weaker; no stronger invariant is imposed on it.
2. **Independent success sets produce an explicit-identity quorum:** contradicted by existing intersection. Do not revert that code or substitute independent per-ref counts into the main model.
3. **FINISHED, shutdown None, or RESULT_ACCEPTED means delivered:** actual APIs/callers distinguish all three from a successful receipt.
4. **Global receiver activity masks configured per-receiver budgets:** per-receiver transaction-wide activity is maintained regardless of callback configuration. Missing budgets or identities are a different configuration contract.
5. **Budget freshness-check/write gap proves failure of healthy work:** a budget decision can linearize at its freshness check before concurrent resumption. No observed nonserializable behavior was established. Do not make a later pull unconditionally override a previously selected timeout.
6. **Deletion after success must always be aborted:** documented full receiver truth overrides known termination cause; this is intentional.
7. **Release while any operation exists is always wrong:** documented forced-drain behavior allows it. A model must represent the bound and surviving operation/ID exclusion rather than assume drainage success.
8. **Raising source release must imply FAILED delivery or unresolved waiter:** callback contract requires attempts and continued settlement; custom resource cleanup success is not the delivery verdict.
9. **Arbitrary late object addition, malformed outcomes or dishonest receiver confirmation establish an in-scope bug:** unsupported registration or noncooperative inputs; excluded.
10. **TransferProgressTracker's lack of its own lock proves a production race:** current search found no production instantiation beyond its definition; do not invent one.

These exclusions follow current code and contracts, not assumptions introduced to make a model pass. MC-1 and MC-2 specifically preserve the unprotected action boundaries that can produce an observable discrepancy.

## Existing regression evidence and coverage gaps

| Existing file/path read | What its source exercises | What it does not establish here |
|---|---|---|
| `receiver_confirm_test.py` | Provisional vs confirmed/legacy state, nonce/dedup, cancellation across refs, eager settlement, racing final confirmations, deletion, scripted Consumer errors | Tests not executed; terminal EOF/progress cancellation window not covered; scripted Cell and fake future cases are not real concurrent Cell transport |
| `receiver_budget_test.py` | Per-receiver idle/acquire, missing identities, sibling-ref acquisition/idle, config resolution, shutdown registration and full-payload quorum | Synthetic monitor time and direct state setup; not exhaustive interleaving or deployed configuration evidence |
| `transfer_outcome_test.py` | Strict success mapping, immutable snapshots, callback/release exceptions, recording, ID ownership, forced-drain marker, persistent compute failures | No queue-enqueued-then-raise DownloadService dispatch test; passing assertions in source are not a run result |
| `transfer_waiter_test.py` | Event waiting, receipt/failure/None, linger, callbacks/release before wake | No production runtime or universal liveness proof |
| `stream_utils_test.py:143-167` | Intentional preservation of queued task after thread-start failure | No composed DownloadService fallback check; source read only |
| `download_test_utils.py:82-110,156-181` | Isolated service tables, disabled real monitor, controlled single monitor pass | Cannot be described as full production monitor scheduling |
| `conftest.py:14-18,27-35` | Directory fixture pins confirmation switch ON | Most tests bypass actual ConfigService resolution unless explicitly overridden |

`test_pass_through_e2e.py` has **two real Cells** (source and final subprocess) and a **simulated CJ FOBS load/dump hop**, explicitly described at lines 25-32 and implemented at 92-101/113-130. Two tests materialize data and compare arrays; three inspect lazy representation/no-new-transaction/reference metadata. Source setup supplies only CELL and hence defaults to count 1 without declared identity (`:142,175,207,239,287`; ViaDownloader defaults above). None asserts transfer outcomes, confirmation ordering, waiters, competing receivers, budgets, cancellation or bounded drain. The forwarded-ref check asserts original source FQCN plus a nonempty ref ID, not equality with a captured original ref ID (`:260-270`). It is not evidence of a live three-hop failure-path test, and was not run here.

No test harness or spec files were authored during code analysis. Proposed local checks remain in the modeling brief's Test-Verifiable section. Model counterexamples would still require implementation validation; local test results would still not establish trace conformance or exhaustive formal correctness.

## Phase 4: handoff decisions

Five Scenarios organize the handoff by mechanism: terminal truth/publication; complete-payload receiver declarations; executor/settlement ownership; activity scopes; source/receipt/waiter obligations. Every priority question and required interaction is mapped above and in [modeling-brief.md](modeling-brief.md).

**First model target: MC-1.** Its predicted useful conclusion is duplicate current public settlement effects caused by partial submission success, not a pre-fix replay or a mere diagnostic. A finite queue and two settlement program counters suffice; the core must retain the current receipt-owner guard so the model can distinguish duplicated effects from single retained outcome.

**Second model target: MC-2.** Its predicted useful conclusion is a public source-progress terminal event inconsistent with winning receiver status under ordinary pipeline cancellation. Model the actual observer callback and preserve no-op trainer progress as a caller limit. Do not claim model success/failure says the current trainer accepts a FAILED transfer.

**First direct local regression: TV-1.** Argument propagation needs a real two-target supported caller check with ordinary externalized data and controlled receiver scheduling; main modeling assumptions remain explicit identities/confirmation. TV-3 and CR-1–4 remain separate weaker-mode/design/API questions.

A small model should begin with one producer, two declared receivers, two fixed refs, bounded data steps, one pipeline slot, a monitor, and explicit inline/queued settlement actors. Time is abstract elapsed request inactivity; callback return/ordinary Exception are explicit choices. Liveness requires eventual scheduling and returning callbacks; forced drain/shutdown semantics remain visible. No crash-recovery, malicious participant, serializer details or byte-transport implementation should be added merely from historical keywords.

The modeling brief contains the required system category, Scenario evidence, model/do-not-model rationale, concrete extensions, safety/liveness properties, verification-method tables and reference pointers. Complete raw evidence remains in `analysis-evidence/`; no historical test/PR claim has been promoted to current execution. Source hashes and cleanliness are in [source-manifest.json](analysis-evidence/source-manifest.json).
