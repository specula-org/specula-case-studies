# arc-swap Instrumentation Spec (Round 2)

Maps spec actions to source-code instrumentation points. The harness emits
NDJSON events; each event corresponds 1:1 to a spec action. The spec validates
post-state fields (per `Trace.tla` `Validate*` operators).

---

## Section 1 — Trace Event Schema

### Common envelope

Every event JSON object includes:

| Field | Type | Description |
|---|---|---|
| `event` | string | spec action name, e.g. `"ReaderFastLoad"` |
| `thread` | string | thread id matching a `Thread` constant (e.g. `"t1"`) |
| `seq` | int | monotonic logical timestamp from a global atomic counter |
| `state` | object | post-action state snapshot (see below) |

For multi-thread events: `src` and `dst` (e.g. `SendGuard`).

### State snapshot fields (post-action)

The `state` object captures the **post-action** state of fields the action
modifies. Fields are addressed by spec variable name:

| Field | Source | Notes |
|---|---|---|
| `storageAddr` | `&AtomicPtr` value cast to address-id string | always captured |
| `rPC[t]` | per-thread reader phase string | e.g. `"r_fast_after_load"` |
| `wPC[t]` | per-thread writer phase string | e.g. `"w_pay_init"` |
| `rPath[t]` | `"fast"`, `"fallback"`, `"none"`, or `"cas"` | |
| `rOpAddr[t]` | observed addr at the first load | hex addr → string id |
| `rConfirmAddr[t]` | observed addr at SeqCst confirm | |
| `rDebtSlot[t]` | slot index 1..N or `HelpSlotIx` | |
| `nodeState[n]` | `"USED"` / `"COOLDOWN"` / `"UNUSED"` | |
| `activeWriters[n]` | counter | |
| `helpControl[n]` | `"IDLE"` / `"GEN"` / `"REPL"` | |
| `helpGen[n]` | reader-side generation counter | |
| `helpSlot[n]` | helping-slot value | |
| `wCurNode[t]` | writer's current node-of-interest | |
| `casKind[t]` | `"Arc"` / `"Guard"` / `"RawFresh"` / `"RawStale"` | |

### Address normalisation

The harness maps real `*const T` pointer values to short string ids (`"a1"`,
`"a2"`, ...) using a global map shared with the spec config. Re-allocations of
the same numeric address are bumped to a new id when the previous allocation
of that id has been freed (allowing the spec's `addrGen` to track ABA).

The mapping: a `static AtomicPtr<HashMap<usize, String>> ADDR_MAP` and a
`fn addr_id(p: usize) -> String` that allocates a fresh id on first sight, or
returns the cached id; on reuse-after-free the id increments (`a1` → `a1#g2`).

---

## Section 2 — Action-to-Code Mapping

Format: **Spec action** → `file:line` → trigger point → event fields.

### Reader fast path (`strategy/hybrid.rs:42-67`)

| Spec action | Code | Trigger | Event name | Fields beyond envelope |
|---|---|---|---|---|
| `ReaderFastLoad` | `hybrid.rs:44` (`storage.load(Relaxed)`) | **after** load | `ReaderFastLoad` | `state.storageAddr`, `state.rOpAddr`, `state.rPC = "r_fast_after_load"` |
| `ReaderFastSlotAcquire` | `fast.rs:58` (`slot.0.swap(ptr, SeqCst)`) | **after** swap, only when prior `slot.0.load(Relaxed) == NONE` | `ReaderFastSlotAcquire` | `state.rDebtSlot`, `state.rPC = "r_fast_after_slot"` |
| `ReaderFastConfirmLoad` | `hybrid.rs:51` (`storage.load(SeqCst)`) | **after** load | `ReaderFastConfirmLoad` | `state.rConfirmAddr`, `state.rPC = "r_fast_after_confirm"` |
| `ReaderFastBranchHit` | `hybrid.rs:52-57` (returns `Some` with `confirm`) | **after** the `if` taken | `ReaderFastBranchHit` | `state.rPC = "r_idle"` |
| `ReaderFastResolve` | `hybrid.rs:58-66` (`debt.pay::<T>(ptr)`) | **after** the CAS — both legs | `ReaderFastResolve` | `state.rPC = "r_idle"` |

### Reader fallback path (`hybrid.rs:70-98`, `helping.rs:186-333`)

| Spec action | Code | Trigger | Event name | Fields |
|---|---|---|---|---|
| `ReaderFallbackActiveAddr` | `helping.rs:203` (`active_addr.store(ptr, SeqCst)`) | **after** store | `ReaderFallbackActiveAddr` | `state.rPath = "fallback"`, `state.rPC = "r_fb_after_active_addr"` |
| `ReaderFallbackControlSwap` | `helping.rs:209` (`control.swap(gen, SeqCst)`) | **after** swap; capture `gen` and `discard` flag | `ReaderFallbackControlSwap` | `state.helpControl = "GEN"`, `state.helpGen = <gen>`, `state.rPC = "r_fb_after_ctrl_gen"` |
| `ReaderFallbackCandidate` | `hybrid.rs:78` (`storage.load(SeqCst)`) | **after** load | `ReaderFallbackCandidate` | `state.rConfirmAddr`, `state.rPC = "r_fb_after_candidate"` |
| `ReaderFallbackSlotStore` | `helping.rs:312` (`slot.0.swap(ptr, SeqCst)`) | **after** swap | `ReaderFallbackSlotStore` | `state.helpSlot`, `state.rPC = "r_fb_after_slot"` |
| `ReaderFallbackConfirmOK` | `helping.rs:317-320` (`control.swap(IDLE, SeqCst)`, prev == gen) | **after** swap, success branch | `ReaderFallbackConfirmOK` | `state.helpControl = "IDLE"`, `state.rPC = "r_idle"` |
| `ReaderFallbackConfirmHelped` | `helping.rs:317, 321-332` (prev != gen, REPL tag) | **after** swap, helped branch | `ReaderFallbackConfirmHelped` | `state.rPC = "r_drop_paying"` |
| `ReaderFallbackResolveEnvelope` | `hybrid.rs:88-95` (pay back unused debt + use replacement) | **after** the cleanup completes | `ReaderFallbackResolveEnvelope` | `state.rPC = "r_idle"` |

### Guard lifecycle harness (Family C)

| Spec action | Code | Trigger | Event name | Fields |
|---|---|---|---|---|
| `GuardIntoInner` | `lib.rs:191` + `hybrid.rs:138-158` | **before** returning the bare Arc; both pay-success and pay-failure legs trace | `GuardIntoInner` | `state` mirrors final guard slot |
| `DropGuard` | `hybrid.rs:108-126` (`Drop::drop`) | **after** dispatch on `self.debt.take()`, before slot/refcount update returns | `DropGuard` | (state empty — DropGuard is end-of-guard; harness emits final addrAlive flags via `state.addrAlive[a]`) |
| `SendGuard` | application-level (test harness only) | **at** `std::thread::spawn(move || { drop(g) })` boundary | `SendGuard` | `src`, `dst` |

### Writer (`lib.rs:477-488`, `debt/mod.rs:82-115`)

| Spec action | Code | Trigger | Event name | Fields |
|---|---|---|---|---|
| `WriterSwap` | `lib.rs:483` (`self.ptr.swap(new, SeqCst)`) | **after** swap | `WriterSwap` | `state.storageAddr` (new value), `state.wPC = "w_after_swap"` |
| `WriterPayInit` | `debt/mod.rs:90` (`T::inc(&val)`) | **after** inc | `WriterPayInit` | `state.wPC = "w_pay_init"` |
| `WriterTraverseLoad` | `debt/list.rs:101` (`LIST_HEAD.load(SeqCst)`) | **after** load; capture the chain snapshot | `WriterTraverseLoad` | `state.wPC = "w_traverse_loaded"` |
| `WriterReserveNode` | `list.rs:142-144` (`active_writers.fetch_add(1, Acquire)`) | **after** fetch_add (per-node) | `WriterReserveNode` | `state.wCurNode = <node>`, `state.activeWriters[node]`, `state.wPC = "w_node_reserved"` |
| `WriterHelpNode` | `debt/mod.rs:96` + `helping.rs:215-302` | **after** the inner `local.help` returns (per node, even if no-op) | `WriterHelpNode` | `state.helpControl[node]` (CTRL_REPL on success), `state.wPC = "w_after_help"` |
| `WriterScanSlot` | `debt/mod.rs:101-109` (per-slot `if slot.pay::<T>(ptr) { T::inc(&val) }`) | **after** each per-slot CAS | `WriterScanSlot` | include `state.fastSlot[node][slot]` or `state.helpSlot[node]` and `state.refCountInc` (boolean) |
| `WriterReleaseNode` | `list.rs:55-58` (`NodeReservation::drop` → `fetch_sub(1, Release)`) | **after** fetch_sub | `WriterReleaseNode` | `state.activeWriters[node]`, `state.wPC` |
| `WriterPayDone` | `debt/mod.rs:113-114` (val drop; `T::dec`) | **after** dec | `WriterPayDone` | `state.wPC = "w_returning"` |
| `WriterReturn` | `lib.rs:486-487` (`T::from_ptr(old)` returned, caller drops) | **after** the returned Arc is dropped | `WriterReturn` | `state.wPC = "w_idle"` |

### compare_and_swap (Family C — `hybrid.rs:217-237`, `lib.rs:506-513`)

| Spec action | Code | Trigger | Event name | Fields |
|---|---|---|---|---|
| `CASBegin` | `lib.rs:506-513` (entering `compare_and_swap`) | **before** the loop's first `load` | `CASBegin` | `state.casKind`, `state.casCurAddr`, `state.casNewAddr`, `state.rPC = "cas_after_load"` |
| `CASCompareNotEqual` | `hybrid.rs:220-221` (`old.as_ptr() != current.as_raw()`) | **after** the comparison branch returns | `CASCompareNotEqual` | `state.rPC = "r_idle"` |
| `CASExchangeOk` | `hybrid.rs:225-228` (`compare_exchange_weak(...).is_ok()`) | **after** successful exchange | `CASExchangeOk` | `state.storageAddr`, `state.wPC = "w_after_swap"` |
| `CASExchangeFail` | `hybrid.rs:225-228` (failure leg, retry) | **after** failed exchange | `CASExchangeFail` | (no state change; cursor advance only) |

### Node lifecycle (`debt/list.rs:113-194`)

| Spec action | Code | Trigger | Event name | Fields |
|---|---|---|---|---|
| `ClaimNode` | `list.rs:153-166` (`compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)`) | **after** successful CAS | `ClaimNode` | `node`, `state.nodeState = "USED"` |
| `CheckCooldown` | `list.rs:123-138` | **after** the relaxed CAS that drops COOLDOWN→UNUSED | `CheckCooldown` | `node`, `state.nodeState = "UNUSED"` |

### Adversary actions (only emitted by fault-injection harness)

| Spec action | Code | Trigger | Event name | Fields |
|---|---|---|---|---|
| `PickRelaxSite` | (harness — skipped in production) | when an instrumentation patch flips an SC label to a weaker order on test runs | `PickRelaxSite` | `site` (one of `RelaxSites`) |
| `DropArcSwap` | `lib.rs:337-347` (`ArcSwapAny::drop`) | **after** `T::dec(ptr)` finishes | `DropArcSwap` | `state.addrAlive[storageAddr]` |

---

## Section 3 — Special Considerations

### Capturing ordered state across atomic boundaries

The harness's `seq` field provides a totally-ordered logical timestamp.
Implementation: a single `static SEQ: AtomicU64` that every event point
fetch_adds with `Ordering::SeqCst`. Trace-side preprocessing sorts by `seq`
before emitting NDJSON; this gives a faithful interleaving even when events
are emitted from different threads.

### Multi-action implementation functions

`pay_all` (`debt/mod.rs:82-115`) emits multiple events per call:

1. one `WriterPayInit` (after `T::inc(&val)`)
2. one `WriterTraverseLoad` (after `LIST_HEAD.load(SeqCst)`)
3. for each visited node: one `WriterReserveNode`, one `WriterHelpNode`,
   N `WriterScanSlot` (one per slot index), one `WriterReleaseNode`
4. one `WriterPayDone` (after val drop)

`load` (`hybrid.rs::load`) emits either the fast-path 4-event sequence
(`ReaderFastLoad` → `…SlotAcquire` → `…ConfirmLoad` → `…BranchHit` or
`…Resolve`) or the fallback 5-event sequence
(`…ActiveAddr` → `…ControlSwap` → `…Candidate` → `…SlotStore` →
`…ConfirmOK`/`…ConfirmHelped` → `…ResolveEnvelope` if helped).

### Address-identity allocation

`addr_id` keeps a generation counter per *numeric* pointer address. When
allocator reuse occurs, the same numeric address gets a fresh id (e.g.
`a1#g3`). Spec config strings list the expected ids; trace replay will fail
post-state validation if the harness omits the generation bump.

### Nodes are never freed

`debt/list.rs:6-9` documents that nodes live forever. The spec models this
implicitly: we treat thread-id and node-id as 1:1, and `ClaimNode` only
transitions UNUSED→USED. The harness should emit `ClaimNode` whenever a
new thread first calls `LocalNode::with`, and `CheckCooldown` whenever a
node moves COOLDOWN→UNUSED.

### `compare_and_swap` raw-pointer hazard (C3)

The harness flag `casKind = "RawStale"` is only emitted when the test fixture
deliberately constructs a stale `*const T` from a previously-freed Arc. This
is the documented hazard; spec invariant `CASIntendedSemantics` should
*not* fire on this case.

### Bootstrap state

`Init` matches the implementation's startup state: `storageAddr = InitAddr`,
`refCount[InitAddr] = 1`, `addrAlive[InitAddr] = TRUE`. Each thread's
`LocalNode` is treated as already claimed at boot (matches `THREAD_HEAD` lazy
init in `list.rs:336`).

### Field omissions

`refCount`, `addrAlive`, and `addrGen` are *not* emitted on every event
because they are derivable from the action sequence in the spec. They are
captured **only** on `WriterReturn`, `DropGuard`, `DropArcSwap`,
`CASCompareNotEqual` — i.e. events that change refcounts. Other events should
not include these fields to reduce trace size.

### Concurrent threads

Reader and writer events from different threads will interleave; the harness
must not serialise them. The `seq` counter alone provides a total order; the
spec replays in sequence order. Each event's snapshot reflects the state
**just after** the corresponding atomic op — taken via a small read of the
relevant fields, *not* a global lock.
