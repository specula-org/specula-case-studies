# Instrumentation Spec: arc-swap Debt-Based Reader Tracking

Maps TLA+ spec actions to source code locations for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "thread": "<thread_id>",
  "ts": <monotonic_ns>,
  "state": {
    "rPC": "<reader_program_counter>",
    "rPtr": "<pointer_address_hex>",
    "rHasDebt": <bool>,
    "rSlot": <slot_index>,
    "rPath": "<none|fast|fallback>",
    "wPC": "<writer_program_counter>",
    "wOldPtr": "<pointer_address_hex>",
    "storagePtr": "<pointer_address_hex>"
  },
  "ptr": "<pointer_address_hex>",
  "slot": <slot_index>,
  "target_thread": "<thread_id>"
}
```

### State Fields

| Implementation | TLA+ Variable | Capture Method |
|---|---|---|
| `storage.load(Relaxed)` result | `storagePtr` | Read `AtomicPtr` value |
| `debt.0.load(Relaxed)` per slot | `debtSlot[t][s]` | Read debt slot value |
| Thread ID (`std::thread::current().id()`) | Thread mapping | `thread::current().id()` |
| Pointer address (`T::as_ptr(...)`) | `rPtr` / `wOldPtr` | Cast to `usize`, format as hex |
| Fast slot index | `rSlot` | Index in `Slots` array |
| Reader program counter (enum) | `rPC` | Shadow variable |
| Writer program counter (enum) | `wPC` | Shadow variable |
| `rHasDebt` | `rHasDebt` | Shadow variable |

### Note on Shadow Variables

`rPC`, `wPC`, `rHasDebt`, `rPath` are not directly in the implementation — they
must be tracked via shadow variables (thread-locals or wrapper state) that are
updated at each instrumentation point.

## 2. Action-to-Code Mapping

### ReaderAcquireFast

| Field | Value |
|---|---|
| **Spec action** | `ReaderAcquireFast(t)` |
| **Code location** | `src/strategy/hybrid.rs:42-46` |
| **Trigger point** | After `node.new_fast(ptr as usize)` succeeds (line 46) |
| **Trace event** | `"ReaderAcquireFast"` |
| **Fields** | `thread`, `ptr` (from `storage.load(Relaxed)`), `slot` (fast slot index), `state.rPC = "r_fast_confirm"`, `state.storagePtr` |
| **Notes** | Emit only when `new_fast` returns `Some`. If `None`, no event (falls through to fallback). The `ptr` value comes from line 44 (`storage.load(Relaxed)`). |

### ReaderConfirmFast

| Field | Value |
|---|---|
| **Spec action** | `ReaderConfirmFast(t)` |
| **Code location** | `src/strategy/hybrid.rs:51-57` |
| **Trigger point** | After `storage.load(SeqCst)` at line 51 |
| **Trace event** | `"ReaderConfirmFast"` |
| **Fields** | `thread`, `ptr` (confirm value), `state.rPC` (`"r_holding"` if match, `"r_fast_resolve"` if not), `state.rHasDebt`, `state.storagePtr` |
| **Notes** | The confirm value is from line 51. Record whether `ptr == confirm`. |

### ReaderResolveFast

| Field | Value |
|---|---|
| **Spec action** | `ReaderResolveFast(t)` |
| **Code location** | `src/strategy/hybrid.rs:58-66` |
| **Trigger point** | After `debt.pay::<T>(ptr)` at line 58 |
| **Trace event** | `"ReaderResolveFast"` |
| **Fields** | `thread`, `state.rPC` (`"r_idle"` if pay succeeded, `"r_holding"` if failed), `state.rHasDebt` |
| **Notes** | `debt.pay` return value determines the branch: `true` → retry (r_idle), `false` → writer paid (r_holding, no debt). |

### ReaderFallbackLoad

| Field | Value |
|---|---|
| **Spec action** | `ReaderFallbackLoad(t)` |
| **Code location** | `src/strategy/hybrid.rs:70-84` |
| **Trigger point** | After `node.confirm_helping(gen, candidate)` returns `Ok` (line 82), OR after constructing replacement (line 94) |
| **Trace event** | `"ReaderFallbackLoad"` |
| **Fields** | `thread`, `ptr` (candidate or replacement), `state.rPC = "r_holding"`, `state.rHasDebt`, `state.rPath = "fallback"` |
| **Notes** | The fallback path in the spec is simplified to a single action. Instrument after the full fallback completes (either Ok or Err branch of `confirm_helping`). The `ptr` is the final pointer the reader holds. |

### ReaderDropGuard

| Field | Value |
|---|---|
| **Spec action** | `ReaderDropGuard(t)` |
| **Code location** | `src/strategy/hybrid.rs:105-126` |
| **Trigger point** | At entry of `Drop::drop` for `HybridProtection` (line 107) |
| **Trace event** | `"ReaderDropGuard"` |
| **Fields** | `thread`, `ptr` (the pointer being released), `state.rPC = "r_idle"`, `state.rHasDebt` (before drop) |
| **Notes** | Capture `rHasDebt` BEFORE the drop logic executes (it reflects whether a debt.pay will be attempted). The `ptr` is `T::as_ptr(&self.ptr)`. |

### WriterSwap

| Field | Value |
|---|---|
| **Spec action** | `WriterSwap(t)` |
| **Code location** | `src/lib.rs:477-483` |
| **Trigger point** | After `self.ptr.swap(new, SeqCst)` at line 483 |
| **Trace event** | `"WriterSwap"` |
| **Fields** | `thread`, `ptr` (old pointer from swap return), `state.storagePtr` (new value), `state.wPC = "w_pay_init"`, `state.wOldPtr` |
| **Notes** | The `ptr` field is the OLD pointer returned by `ptr.swap()`. `state.storagePtr` is the NEW pointer. |

### WriterPayInit

| Field | Value |
|---|---|
| **Spec action** | `WriterPayInit(t)` |
| **Code location** | `src/debt/mod.rs:88-90` |
| **Trigger point** | After `T::inc(&val)` at line 90 |
| **Trace event** | `"WriterPayInit"` |
| **Fields** | `thread`, `ptr` (old pointer), `state.wPC = "w_scanning"` |
| **Notes** | This is inside `pay_all`. The `val` is created from `ptr` at line 88, then `T::inc` at line 90. |

### WriterScanSlot

| Field | Value |
|---|---|
| **Spec action** | `WriterScanSlot(t)` |
| **Code location** | `src/debt/mod.rs:101-108` |
| **Trigger point** | After processing each slot in the iterator (line 101-108) |
| **Trace event** | `"WriterScanSlot"` |
| **Fields** | `thread`, `target_thread` (node owner), `slot` (slot index), `ptr` (slot value seen), `state.wPC = "w_scanning"` |
| **Notes** | One event per slot scanned. The `ptr` is the value the writer observed in the slot. If `slot.pay` succeeded, also record that the debt was paid. Record slot index to distinguish fast slots (1..N) from helping slot (N+1). |

### WriterPayDone

| Field | Value |
|---|---|
| **Spec action** | `WriterPayDone(t)` |
| **Code location** | `src/debt/mod.rs:113` |
| **Trigger point** | After `Node::traverse` returns (line 112), before `val` drops |
| **Trace event** | `"WriterPayDone"` |
| **Fields** | `thread`, `state.wPC = "w_returning"` |
| **Notes** | This event fires after the traverse loop completes but before the `LocalNode::with` closure returns (which drops `val`). |

### WriterReturn

| Field | Value |
|---|---|
| **Spec action** | `WriterReturn(t)` |
| **Code location** | `src/lib.rs:486` |
| **Trigger point** | After `T::from_ptr(old)` at line 486 |
| **Trace event** | `"WriterReturn"` |
| **Fields** | `thread`, `ptr` (old pointer), `state.wPC = "w_idle"` |
| **Notes** | The returned Arc will be dropped by the caller (not instrumented separately). |

## 3. Special Considerations

### Thread-Local State

The `LocalNode` and its debt slots are thread-local. Each thread has its own
node with fast slots and a helping slot. The instrumentation must:

1. Track which thread "owns" which node (via `LocalNode::with`).
2. Map slot indices consistently: fast slots are 1..DEBT_SLOT_CNT (8),
   helping slot is DEBT_SLOT_CNT + 1 (9).
3. For model checking with `NumFastSlots = 1`, map real slot indices modulo
   the model's slot count.

### Writer's pay_all Traversal

The writer traverses ALL nodes in the linked list (`Node::traverse`), scanning
each node's fast slots and helping slot. The instrumentation should emit one
`WriterScanSlot` event per slot (not per node). The `target_thread` field
identifies which node/thread the slot belongs to.

The `local.help(node, ...)` call inside the traverse also does work (helping
protocol), but is not separately instrumented — its effects are captured by
the slot state changes.

### Concurrent Threads

Multiple threads may emit events concurrently. The trace is naturally ordered
by the NDJSON line order. When events interleave across threads, the trace
validator uses silent actions to handle gaps.

Key interleaving points:
- Between `ReaderAcquireFast` and `ReaderConfirmFast`: writer may swap
- Between `WriterSwap` and `WriterScanSlot`: reader may acquire debt
- Between `WriterScanSlot` iterations: other readers may acquire/drop debts

### Bootstrap State

The initial state matches the base spec's `Init`:
- `storagePtr = InitPtr` (the first Arc stored in ArcSwap)
- All debt slots are `NullPtr` (NONE)
- `refCount[InitPtr] = 1`, all others = 0
- All readers idle, all writers idle

### Serialization

- Pointer addresses: format as hex strings (e.g., `"0x7f1234567890"`)
- NullPtr sentinel: use `"null"` string
- Thread IDs: use OS thread ID as string
- Boolean values: JSON `true`/`false`
- Slot indices: 1-based integers (matching TLA+ spec)

### Ordering Gap Events

The ordering gap (Family 1) is NOT directly observable in traces — it's an
effect of the memory model. The trace validator should run with
`MaxOrderingGaps = 0` (no gaps allowed) to verify the spec matches the
implementation under sequential consistency. The ordering gap is only enabled
during model checking (MC configs) to search for bugs.

### Refcount Tracking

The implementation's `Arc` refcount is not directly accessible for tracing.
The spec tracks `refCount` abstractly. For trace validation, refcount
invariants are checked but refcount values are not validated against the trace
(they're derived from the spec's state transitions).
