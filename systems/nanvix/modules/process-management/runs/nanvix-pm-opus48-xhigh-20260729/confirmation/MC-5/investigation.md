# MC-5 Investigation — Spurious OutOfMemory: process admission rejected before reclaimable zombies are reaped

Source: MC (real counterexample `spec/output/MC_hunt_MC-5.out`, invariant `MCNoSpuriousOOM`).
Ground truth: the Rust implementation and its call graph (per scope).

## Step 1 — Code audit (facts)

### Cited sites (all in `src/kernel/src/pm/process/manager/mod.rs`)
- `:1129 create_process` — process-cap gate `:1139`: `if self.live_count >= MAX_PROCESSES { return Err(OutOfMemory) }`. No zombie reap before the check. Thread reservation `:1164` uses **plain** `self.tm.try_next_tid()?` (not the reaping variant).
- `:1485 duplicate_process` (fork) — identical process-cap gate `:1530`. Its **thread** reservation `:1558` DOES use `try_next_tid_reaping(mm)`, but the **process-cap** gate `:1530` does NOT reap.
- `:1973 do_execv` — thread reservation `:2023` uses **plain** `self.tm.try_next_tid()?` (no reap-then-retry).
- `live_count` incremented at `:1206` (create commit); decremented ONLY at `:2458` inside `pop_zombie_process` (burial during harvest).

### The sibling FIX that exists (developer intent)
- `try_next_tid_reaping` (`:3410`): on thread-cap `OutOfMemory`, calls `reap_pending_zombies(mm)` then retries `try_next_tid()` once. Doc `:3396-3399`: "makes thread admission self-healing … not spuriously refused while reclaimable thread slots are merely awaiting harvest."
- `reap_pending_zombies` (`:3284`) doc `:3255-3256`: "Draining them here turns a spurious `ErrorCode::OutOfMemory` into successful admission."
- Wired into `create_thread` (`:421`) and `duplicate_process`'s thread reservation (`:1558`) — NOT the process-cap gates (`:1139`, `:1530`) nor `do_execv` (`:2023`).

### Zombie lifecycle / harvest timing
- Terminate a ready child: `terminate` `:2295-2304` pushes a `ZombieProcess` to `self.zombies`; `live_count` unchanged.
- Child exits: `do_exit` `:2141` pushes zombie; then `:2147 take_earliest_ready()` switches DIRECTLY to the next ready user process — NOT the kernel idle loop.
- Process zombies are harvested ONLY by `harvest_zombies` in the idle loop `kcall/handler.rs:81,168` (kernel-process context). User-kcall entry points only call `reap_deferred()` (detached-thread zombies), never `harvest_zombies`.
- ⇒ In the window (child exit/terminate → scheduler picks parent → parent forks), NO process-zombie harvest occurs. The stale `live_count` is observed by the next fork.

### Reachability (user interface)
- Fork is user-reachable: `KcallNumber::Duplicate` → `pm::duplicate` (`kcall/duplicate.rs:56`) → `duplicate_process` → returns the OOM to userspace as `KcallResult::Error`.
- execv: `KcallNumber::Execv` → `pm::execv` → `do_execv` (`:2023`).
- create_process itself is boot-only (`kmain.rs:308`, spawns init/daemons); its gate can spuriously fail at boot if a daemon becomes a zombie before the next spawn.

### Trigger scenario (maps to CE states 1→4)
1. System at the live-process cap (CE uses MAX_PROCESSES=2; real value 255 — mechanism identical): kernel p1 running + child p2 created (`MCCreateProcess`, live_count=MAX).
2. Child p2 terminated/exits → `zombie`; `live_count` unchanged (`MCRunnableTerminate`; terminate `:2304`).
3. Parent forks again (`duplicate_process`) → gate `:1530` sees `live_count>=MAX` → `OutOfMemory`, though zombie p2 is reclaimable (`MCCreateProcessSpuriousOOM`; `spuriousOOM=TRUE`).

## Step 2 — Developer-knowledge search
- Commit `a85226542` "[kernel] E: Reap zombies on demand" (PR #2500): message explicitly names the "spurious OutOfMemory" problem and fixes it ONLY for the **thread** cap (wires `create_thread`/`duplicate_process` thread reservation to `try_next_tid_reaping`). It does not touch the process-cap `live_count` gate or `do_execv`.
- The `live_count` gate was introduced by `12c32a436` "[config] E: Introduce MAX_PROCESSES constant" and has never been given reap-then-retry.
- No TODO/FIXME/issue/PR reports the process-cap gap specifically.

## Step 3 — Known-status / precedent
- The THREAD-cap spurious OOM is KNOWN + FIXED (PR #2500). The PROCESS-cap gate and `do_execv` reservation are the UNADDRESSED SIBLINGS — a same-shape precedent at a DIFFERENT site. Per the skill, a same-shape precedent at a different site is NOT the same bug; re-verified prerequisites hold at the new site.
- No existing report for THIS site ⇒ Novelty: NEW. (Finding's "#2495" label is off-by-one; the real fix is PR #2500 / a85226542; mechanism matches exactly.)
- Source is MC (real CE) ⇒ proceeds to Phase 2 regardless.

## Reproduction feasibility
- `ProcessManager::create_process`/`duplicate_process` require `&mut VirtMemoryManager`, ELF images, and forged x86 contexts; the cap requires 255 real processes. Not host-unit-testable. Existing PM tests (`manager/test.rs`) only cover pure static methods. No prebuilt kernel image; a full Nanvix microkernel + multiprocess-userspace QEMU boot is impractical in this batch harness.
- Repro: faithful transcription of the exact gate + `live_count` accounting + the sibling `try_next_tid_reaping` pattern, driven by the real-API-equivalent sequence, with a positive control.
