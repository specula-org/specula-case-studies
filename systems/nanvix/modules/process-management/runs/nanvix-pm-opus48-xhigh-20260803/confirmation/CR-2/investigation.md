# CR-2 Investigation — fork CoW rollback & best-effort mmap rollback

Source: **Code Review** (MC found NO counterexample for the memory-side rollback; only the
exec-admission slice was flagged and is deduped onto MC-9).

## Step 1 — Code audit

### Gap 1: parent CoW not restored on a failed fork
- `link_user_pages` (mm/virt/manager.rs:278) links parent's pages into the child CoW. On any
  failure it calls `rollback_linked_pages` (manager.rs:455) which:
  - unmaps every child page it linked (releasing the shared refcount) — child fully reclaimed;
  - **intentionally leaves the parent's CoW marks** (documented manager.rs:443-453): PTE/refcount
    state cannot reliably distinguish a page this call marked from one already-CoW from an earlier
    fork; wrongly unmarking a page a *live* sharer relies on would break its CoW, whereas leaving a
    page CoW that could be writable "merely costs one extra copy-on-write fault on the next write."
- Consequence of a left-behind mark: parent page is CoW pointing at a frame now at refcount 1
  (child unmapped). On the parent's next write, `resolve_cow_at` (vmem.rs:1051) takes the
  **sole-owner fast path** (vmem.rs:1074, `refcount()==1`): it just clears the CoW bit in place —
  **no allocation, no copy, no free, no data change** — one extra minor fault. Parent data intact,
  no leak, no accounting error.
- Caller `duplicate_process` (mod.rs:1576/1587) additionally `clear_user_space()`s the child on
  failure, so the child address space leaks nothing.
- **Developer intent**: comment manager.rs:443-453 states leaving the mark is the deliberately safe
  choice; unit test `test_link_user_pages_rolls_back_on_partial_failure` (pm/test.rs:647) ASSERTS
  the post-rollback parent PTE is "read-only + CoW, still pointing at frame_a" and the child has no
  mapping — i.e. the current behavior is the specified, tested contract.

### Gap 2: best-effort mmap rollback
- `ProcessManager::mmap` (mod.rs:3523) maps in 16-page batches. On a failed batch it calls
  `rollback_mmap` (mod.rs:3580), a loop of `try_unmap_upage` over `[base, current_vaddr)`; unmap
  failures are logged and skipped ("best-effort").
- The partially-mapped failing batch is already cleaned by `alloc_upages`' own internal rollback
  (manager.rs:680-697) before it returns Err, so `rollback_mmap` only needs to unmap the fully
  successful prior batches — pages it just mapped, which are present, valid user pages.
- `try_unmap_upage` -> `vmem.unmap` (vmem.rs:1649) succeeds for a present page; the only late error
  path (pgdir.unmap on an emptied page table) does not arise for a well-formed contiguous batch.
- Even if a page were left mapped, `clear_user_space()` at process exit (harvest_zombies
  mod.rs:3489) reclaims ALL remaining user frames — no permanent leak. `rollback_mmap` also only
  unmaps pages this call mapped (the range was verified free before mmap started), so no over-unmap
  / double-free.

## Step 2 — Developer-knowledge search
- `git log` on the cited sites: commits are implementation/feature work (`F: Add duplicate() kcall`,
  `E: Add npages parameter to mmap kcall`, `B: Handle already-CoW parent pages`). No issue/PR/commit
  reports "earlier mmap batch left mapped" or "parent CoW not restored" as a bug.
- The CoW-left-in-place behavior is explicitly documented and covered by an asserting unit test
  (evidence the developers consider it correct, not a defect).

## Step 3 — Known-status / precedent
- No public issue / PR / CVE / prior Specula entry reports THIS mechanism at THIS site as a bug
  (git-history search only). Not a code-review × known duplicate → proceed to Phase 2. Novelty: NEW.

## Reachability & trigger
- Gap 1 trigger: fork whose `link_user_pages` fails partway (reachable via allocation/refcount
  failure). Gap 2 trigger: `mmap(npages>16)` where a later batch fails (reachable via a page already
  mapped in the range, or OOM). Both trigger paths are reachable through normal PM operation.

## Assessment (pre-verdict)
Both flagged mechanisms are documented, intended designs whose worst-case consequence is benign
(one extra fast-path CoW fault; frames reclaimed at exit). The rollback IS complete for everything
that matters (child fully reclaimed = no leak; parent data intact; no accounting error). No
reachable safety consequence. Verdict decided in Phase 2 after reproduction.
