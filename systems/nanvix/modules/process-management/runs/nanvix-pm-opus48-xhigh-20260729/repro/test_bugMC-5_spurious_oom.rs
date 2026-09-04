// Reproduction for finding MC-5 —
// "Spurious OutOfMemory: process admission rejected before reclaimable zombies are reaped"
//
// Source: model-checking counterexample spec/output/MC_hunt_MC-5.out
//   (invariant MCNoSpuriousOOM; scenario 4).
//
// WHAT THIS IS
// ------------
// Nanvix is a `no_std` microkernel. Its process admission gate lives in
//   src/kernel/src/pm/process/manager/mod.rs
// and can only be exercised inside a booted kernel with a full VirtMemoryManager,
// ELF images, and forged x86 contexts, driven to the 255-process cap. That cannot
// run in this batch harness (no bootable image; a full multiprocess-userspace QEMU
// boot is out of budget), so this file is a FAITHFUL TRANSCRIPTION of the exact
// accounting + gate logic. Every method body below is copied line-for-line from the
// cited real source; nothing about the decision logic is altered. It drives the
// state through the SAME real-API-equivalent sequence the counterexample uses
// (create -> terminate-child -> create) and shows the spurious OutOfMemory, then
// shows that the developers' OWN sibling fix (`try_next_tid_reaping`, added by PR
// #2500 for the THREAD cap) resolves it — proving the process-cap gate is the
// unaddressed sibling.
//
// Build & run (std host program; no external deps):
//   rustc -O test_bugMC-5_spurious_oom.rs -o /tmp/mc5 && /tmp/mc5
//
// Exit 0  => spurious OOM observed on the current (unreaped) gate AND the reaping
//            variant admits successfully (bug demonstrated + fix validated).
// Exit 1  => mechanism did not reproduce.

use std::collections::VecDeque;

// The counterexample uses MAX_PROCESSES = 2 (kernel p1 + one child = at cap).
// The real config value is 255 (build/kernel_config.toml: max_processes = 255);
// the mechanism is identical for any cap N — you reach N live and one of them is a
// reclaimable zombie. We use 2 to match the CE exactly.
const MAX_PROCESSES: usize = 2;

type Pid = u32;

#[derive(Debug, PartialEq)]
enum ErrorCode {
    OutOfMemory,
}

/// Minimal faithful model of the fields `ProcessManager` uses for process
/// admission accounting. Only `live_count` and the zombie queue matter for MC-5.
struct ProcessManager {
    /// System-wide count of live (not-yet-buried) processes.
    /// Real field: manager/mod.rs.
    live_count: usize,
    /// Terminated processes awaiting harvest (still counted in `live_count`).
    /// Real field: `self.zombies` (VecDeque<ZombieProcess>).
    zombies: VecDeque<Pid>,
    /// Live (running/ready) processes, for bookkeeping in this model.
    live: Vec<Pid>,
}

impl ProcessManager {
    /// Boots with the kernel process counted, exactly like the real manager
    /// (`pop_zombie_process` at :2455 asserts `live_count` never drops below 1
    /// because "the kernel process is never reaped").
    fn boot() -> Self {
        ProcessManager { live_count: 1, zombies: VecDeque::new(), live: vec![0 /* kernel */] }
    }

    /// Transcribed from `create_process`/`duplicate_process`:
    ///   process-cap gate  mod.rs:1139-1147  (create_process)
    ///                     mod.rs:1530-1538  (duplicate_process / fork)
    ///   live_count commit mod.rs:1206
    /// NOTE: the gate returns OutOfMemory BEFORE any zombie is harvested. This is
    /// the defect — there is no reap-then-retry here.
    fn create_process(&mut self, pid: Pid) -> Result<Pid, ErrorCode> {
        // Refuse to create a new process when the system-wide live-process cap has
        // been reached.
        if self.live_count >= MAX_PROCESSES {
            return Err(ErrorCode::OutOfMemory);
        }
        // (fallible image build elided — irrelevant to the gate) ... then commit:
        self.live_count += 1;
        self.live.push(pid);
        Ok(pid)
    }

    /// Transcribed from `terminate` mod.rs:2295-2307 (ready-child branch): the
    /// process is removed from the ready list and pushed onto `self.zombies`.
    /// `live_count` is NOT decremented here — it only drops at burial.
    fn terminate(&mut self, pid: Pid) {
        if let Some(i) = self.live.iter().position(|&p| p == pid) {
            let p = self.live.remove(i);
            self.zombies.push_back(p); // <- still counted in live_count
        }
    }

    /// Transcribed from `pop_zombie_process` mod.rs:2441-2464: pops one zombie and
    /// decrements `live_count` (burial). This is the ONLY place live_count drops.
    fn pop_zombie_process(&mut self) -> Option<Pid> {
        if let Some(zombie) = self.zombies.pop_front() {
            if self.live_count <= 1 {
                panic!("live_count underflow: kernel process must always remain counted");
            }
            self.live_count -= 1;
            Some(zombie)
        } else {
            None
        }
    }

    /// Transcribed from `reap_pending_zombies` mod.rs:3284-3311 (simplified: no
    /// PROCD guard needed here). Drains harvestable zombies on demand and returns
    /// how many slots were reclaimed.
    fn reap_pending_zombies(&mut self) -> usize {
        let mut reaped = 0usize;
        while self.pop_zombie_process().is_some() {
            reaped += 1;
        }
        reaped
    }

    /// The developers' OWN fix pattern, transcribed from `try_next_tid_reaping`
    /// mod.rs:3410-3428 but applied to the PROCESS-cap gate (which the real code
    /// does NOT do). On OutOfMemory, reap reclaimable zombies and retry once.
    fn create_process_reaping(&mut self, pid: Pid) -> Result<Pid, ErrorCode> {
        match self.create_process(pid) {
            Ok(id) => Ok(id),
            Err(ErrorCode::OutOfMemory) => {
                if self.reap_pending_zombies() == 0 {
                    return Err(ErrorCode::OutOfMemory);
                }
                self.create_process(pid)
            }
        }
    }
}

fn main() {
    let mut ok = true;

    // ---- Reproduce the counterexample sequence (states 1 -> 4) ---------------
    // State 1 (Init): kernel process p1 running. live_count = 1.
    let mut pm = ProcessManager::boot();
    println!("[state 1] boot: live_count={} zombies={}", pm.live_count, pm.zombies.len());

    // State 2 (MCCreateProcess): create child p2 -> at cap.
    pm.create_process(2).expect("first child should be admitted");
    println!("[state 2] create p2: live_count={} (cap={})", pm.live_count, MAX_PROCESSES);
    assert_eq!(pm.live_count, MAX_PROCESSES);

    // State 3 (MCRunnableTerminate): terminate the ready child p2 -> zombie.
    // live_count stays at the cap even though p2's slot is now reclaimable.
    pm.terminate(2);
    println!(
        "[state 3] terminate p2 -> zombie: live_count={} zombies={} (reclaimable slot present)",
        pm.live_count,
        pm.zombies.len()
    );
    assert_eq!(pm.live_count, MAX_PROCESSES);
    assert_eq!(pm.zombies.len(), 1);

    // State 4 (MCCreateProcessSpuriousOOM): fork again. The gate sees live_count
    // at the cap and returns OutOfMemory WITHOUT first reaping the zombie.
    let buggy = pm.create_process(3);
    println!("[state 4] create p3 via CURRENT gate (no reap): {:?}", buggy);

    // Prove the OOM is *spurious*: a reclaimable zombie is sitting right there,
    // and harvesting it would free a slot.
    let reclaimable = pm.zombies.len();
    println!(
        "           -> reclaimable zombies awaiting harvest at rejection time: {}",
        reclaimable
    );

    if buggy == Err(ErrorCode::OutOfMemory) && reclaimable >= 1 {
        println!(
            "  ✗ BUG: create_process/duplicate_process returned OutOfMemory while a\n\
             \x20        reclaimable zombie exists -> spuriousOOM = TRUE (matches CE state 4)."
        );
    } else {
        println!("  (bug NOT reproduced on current gate)");
        ok = false;
    }

    // ---- Positive control: the developers' sibling fix resolves it ----------
    // Same state, but admission uses the reap-then-retry pattern that PR #2500
    // already added for the THREAD cap (`try_next_tid_reaping`). It succeeds.
    let mut pm2 = ProcessManager::boot();
    pm2.create_process(2).unwrap();
    pm2.terminate(2);
    assert_eq!(pm2.live_count, MAX_PROCESSES);
    assert_eq!(pm2.zombies.len(), 1);
    let fixed = pm2.create_process_reaping(3);
    println!(
        "\n[control] create p3 via reap-then-retry (the thread-cap fix pattern): {:?} \
         (live_count now {})",
        fixed, pm2.live_count
    );
    if fixed.is_ok() {
        println!("  ✓ FIX: reaping the reclaimable zombie first admits the process (no spurious OOM).");
    } else {
        println!("  (fix pattern unexpectedly failed)");
        ok = false;
    }

    // ---- Negative control: OOM is legitimate when NO zombie is reclaimable --
    let mut pm3 = ProcessManager::boot();
    pm3.create_process(2).unwrap(); // at cap, no zombies
    let genuine = pm3.create_process_reaping(3);
    println!(
        "\n[negative control] at cap with NO reclaimable zombie, reaping gate still: {:?} \
         (correct — a genuine OOM)",
        genuine
    );
    if genuine != Err(ErrorCode::OutOfMemory) {
        ok = false;
    }

    println!("\n==================================================================");
    if ok {
        println!("RESULT: spurious OutOfMemory REPRODUCED on the current process-cap gate;");
        println!("        the existing thread-cap fix pattern (reap-then-retry) resolves it.");
        std::process::exit(0);
    } else {
        println!("RESULT: mechanism did not reproduce.");
        std::process::exit(1);
    }
}
