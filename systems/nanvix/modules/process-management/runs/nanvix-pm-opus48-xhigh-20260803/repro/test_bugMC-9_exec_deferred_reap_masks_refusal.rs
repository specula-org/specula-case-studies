// Reproduction for finding MC-9:
//   "execv is spuriously refused at MAX_THREADS (non-healing admission)"
//   invariant: ExecAdmission
//   counterexample: spec/output/MC_hunt_scenario2_mc9_final.out
//
// WHAT THE MODEL CLAIMS
// --------------------
// The TLA+ counterexample fires action `ExecRefuse` (cfg action "execR") while the
// deferred-reap set still holds a reclaimable detached-thread zombie:
//     State 5: ExitThread(t2)  -> deferred = {t2}, tlive = 2 (== MaxThreads)
//     State 6: Schedule(t1)
//     State 7: ExecRefuse(t1)  -> g.execRefused = TRUE     <-- ExecAdmission violated
// i.e. exec is refused at MAX_THREADS even though slot t2 is reclaimable.
//
// WHY THIS IS A SPEC ARTIFACT (the point of this reproduction)
// -----------------------------------------------------------
// In the hunt cfg, "execR" (ExecRefuse) and "reapSafe" (ReapDeferredSafe) are TWO
// INDEPENDENT schedulable actions, so TLC is free to fire ExecRefuse *before* the
// deferred set is drained (exactly what the CE does).
//
// The real kernel couples them: the execv() kcall entry point unconditionally reaps
// the deferred detached-thread zombies as its FIRST step, BEFORE the admission check
// in do_execv() ever runs:
//
//   src/kernel/src/pm/process/manager/unsafe.rs
//     351  pub unsafe fn exec(pid, args) -> Error {
//     361      Self::reap_deferred();                       // <-- drains `deferred_reap`
//     ...
//     434      match pm.do_execv(mm, pid, ...) { ... }      // admission happens here
//
//     610  unsafe fn reap_deferred() {
//     613      for (pid, zombie) in deferred { Self::harvest_zombie_thread(pid, zombie); }
//
//     654  unsafe fn harvest_zombie_thread(pid, zombie_thread) {
//     708      Self::get_mut().tm.on_thread_reaped();       // <-- live_count -= 1
//
//   src/kernel/src/pm/process/manager/mod.rs
//     2023     let (tid, next_tid) = self.tm.try_next_tid()?;   // non-healing admission
//
//   src/kernel/src/pm/thread/mod.rs
//     227  fn try_next_tid(&self) { if self.live_count >= MAX_THREADS { Err(OutOfMemory) } ... }
//     272  fn on_thread_reaped(&mut self) { ...; self.live_count -= 1; }
//
// So by the time do_execv() calls the non-healing try_next_tid(), the deferred zombie
// t2 has ALREADY been reaped and live_count is back below MAX_THREADS. The refusal the
// CE relies on therefore CANNOT occur in the implementation: `ExecRefuse` with a
// non-empty deferred set is an unreachable transition. The model under-models the
// mandatory entry-point reap.
//
// This program:
//   (1) transcribes the REAL admission arithmetic verbatim (try_next_tid /
//       commit_next_tid / on_thread_reaped) and replays the CE thread sequence under
//         (a) the MODEL ordering  (ExecRefuse before the deferred drain) -> REFUSED,
//         (b) the REAL ordering   (entry-point reap_deferred first)       -> ADMITTED;
//   (2) structurally asserts, against the ACTUAL source files, that the real exec
//       entry point reaps deferred zombies before do_execv's admission check.
//
// Build/run (host, std):  rustc -O test_bugMC-9_*.rs -o /tmp/mc9 && /tmp/mc9

use std::fs;

// MaxThreads for the hunt cfg MC_hunt_scenario2_mc9.cfg is 2 (`MaxThreads = 2`).
const MAX_THREADS: i64 = 2;

// ------------------------------------------------------------------------------------
// Faithful transcription of the real thread-admission counter.
// Mirrors src/kernel/src/pm/thread/mod.rs (ThreadManager).
// ------------------------------------------------------------------------------------
struct ThreadManager {
    next_id: i32,
    live_count: i64,
}

impl ThreadManager {
    // thread/mod.rs:200 `new` seeds { next_id: 1, live_count: 1 } (the kernel/main thread).
    fn new() -> Self {
        ThreadManager { next_id: 1, live_count: 1 }
    }

    // thread/mod.rs:227 try_next_tid: reject if live_count >= MAX_THREADS.
    fn try_next_tid(&self) -> Result<(i32, i32), &'static str> {
        if self.live_count >= MAX_THREADS {
            return Err("system-wide thread limit reached"); // ErrorCode::OutOfMemory
        }
        Ok((self.next_id, self.next_id + 1))
    }

    // thread/mod.rs:261 commit_next_tid: bump next_id and live_count.
    fn commit_next_tid(&mut self, next_tid: i32) {
        self.next_id = next_tid;
        self.live_count += 1;
    }

    // thread/mod.rs:272 on_thread_reaped: free a slot (called by harvest_zombie_thread).
    fn on_thread_reaped(&mut self) {
        assert!(self.live_count > 1, "live_count underflow");
        self.live_count -= 1;
    }
}

// Result of an execv admission attempt.
#[derive(PartialEq, Debug)]
enum ExecOutcome {
    Admitted,
    Refused,
}

// Replays the counterexample's thread sequence up to the point where t1 calls execv,
// then performs admission. `entry_reaps_first` selects the ordering:
//   true  = REAL implementation (KernelProcessManager::exec reaps deferred, then do_execv)
//   false = MODEL ordering       (ExecRefuse may fire while deferred is still non-empty)
fn replay_and_exec(entry_reaps_first: bool) -> ExecOutcome {
    let mut tm = ThreadManager::new(); // t1 live: live_count = 1
    let mut deferred: Vec<i32> = Vec::new();

    // State 2 of the CE: CreateThread(t1, t2, det=TRUE) -- healed create commits t2.
    let (_t2, next) = tm.try_next_tid().expect("t2 admission must succeed (live_count 1 < 2)");
    tm.commit_next_tid(next); // live_count = 2 (== MaxThreads)

    // States 3-5: t2 runs and, being detached, exits into the deferred-reap set.
    // (ExitThread of a detached thread pushes its zombie to `deferred_reap`; the slot is
    //  NOT yet returned -- on_thread_reaped has not run.)
    deferred.push(2); // deferred = {t2}; live_count still 2

    // State 7: t1 invokes execv().
    if entry_reaps_first {
        // REAL: KernelProcessManager::exec() first step -> reap_deferred()
        //       -> harvest_zombie_thread(..) -> tm.on_thread_reaped() for each deferred zombie.
        for _z in deferred.drain(..) {
            tm.on_thread_reaped(); // live_count: 2 -> 1
        }
    }
    // do_execv() admission: the NON-healing try_next_tid() (mod.rs:2023).
    match tm.try_next_tid() {
        Ok(_) => ExecOutcome::Admitted,
        Err(_) => ExecOutcome::Refused,
    }
}

// ------------------------------------------------------------------------------------
// Structural assertions against the ACTUAL kernel source, so this demonstration is tied
// to the real code and fails loudly if the ordering ever changes.
// ------------------------------------------------------------------------------------
fn byte_index_of(hay: &str, needle: &str, from: usize) -> Option<usize> {
    hay[from..].find(needle).map(|i| i + from)
}

fn assert_real_code_ordering(root: &str) {
    let unsafe_rs = fs::read_to_string(format!(
        "{root}/src/kernel/src/pm/process/manager/unsafe.rs"
    ))
    .expect("read unsafe.rs");

    // Locate the exec() entry point.
    let exec_fn = byte_index_of(&unsafe_rs, "pub unsafe fn exec(", 0)
        .expect("exec() entry point present");
    // Its FIRST action must be reap_deferred(), and do_execv() must come strictly after.
    let reap = byte_index_of(&unsafe_rs, "Self::reap_deferred();", exec_fn)
        .expect("exec() calls reap_deferred()");
    let do_exec = byte_index_of(&unsafe_rs, "do_execv(", exec_fn)
        .expect("exec() calls do_execv()");
    assert!(
        reap < do_exec,
        "exec() must reap_deferred() BEFORE do_execv() (reap@{} do_execv@{})",
        reap,
        do_exec
    );

    // reap_deferred() must decrement the live count via on_thread_reaped()
    // (through harvest_zombie_thread()).
    assert!(
        unsafe_rs.contains("fn harvest_zombie_thread(")
            && unsafe_rs.contains("tm.on_thread_reaped();"),
        "reap path must call on_thread_reaped() to free the deferred slot"
    );

    let mod_rs = fs::read_to_string(format!(
        "{root}/src/kernel/src/pm/process/manager/mod.rs"
    ))
    .expect("read mod.rs");
    // do_execv() uses the NON-healing try_next_tid() (the finding's cited site).
    let do_execv_def = byte_index_of(&mod_rs, "fn do_execv(", 0).expect("do_execv defined");
    assert!(
        byte_index_of(&mod_rs, "self.tm.try_next_tid()?;", do_execv_def).is_some(),
        "do_execv() uses the non-healing self.tm.try_next_tid()"
    );
    // The create/fork paths use the healing variant (asymmetry the finding names).
    assert!(
        mod_rs.contains("self.try_next_tid_reaping(mm)?;"),
        "create/fork paths use the healing try_next_tid_reaping()"
    );

    let thread_rs =
        fs::read_to_string(format!("{root}/src/kernel/src/pm/thread/mod.rs")).expect("read thread/mod.rs");
    assert!(
        thread_rs.contains("if self.live_count >= ::config::kernel::MAX_THREADS"),
        "try_next_tid() rejects at live_count >= MAX_THREADS"
    );
    assert!(
        thread_rs.contains("self.live_count -= 1;"),
        "on_thread_reaped() decrements live_count"
    );

    println!("[structural] exec() entry reaps deferred zombies BEFORE do_execv() admission: OK");
    println!("[structural] reap path calls on_thread_reaped() (frees the slot): OK");
    println!("[structural] do_execv() uses non-healing try_next_tid(); create/fork use reaping: OK");
}

fn main() {
    // Repo root: this file lives in <root>/.specula-output/repro/, so go up two levels.
    let root = std::env::args().nth(1).unwrap_or_else(|| {
        "/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-9/worktree".to_string()
    });

    println!("== MC-9 reproduction: exec deferred-reap masks the modeled ExecRefuse ==\n");

    assert_real_code_ordering(&root);

    println!();
    let model = replay_and_exec(false); // ExecRefuse fired before the deferred drain (as TLC did)
    let real = replay_and_exec(true); // implementation ordering: entry-point reap first

    println!("[model ordering]  ExecRefuse scheduled before reapSafe  -> exec {:?}", model);
    println!("[real  ordering]  execv() kcall reaps deferred first    -> exec {:?}", real);
    println!();

    // The CE requires the MODEL ordering to refuse; the real ordering must admit.
    assert_eq!(model, ExecOutcome::Refused, "model ordering should reproduce the CE refusal");
    assert_eq!(
        real,
        ExecOutcome::Admitted,
        "BUG would be real if the implementation refused here"
    );

    println!("RESULT: The counterexample's ExecRefuse fires only in the MODEL ordering,");
    println!("        where reapSafe is an independent action scheduled after execR.");
    println!("        The real execv() kcall reaps the deferred zombie t2 first");
    println!("        (unsafe.rs:361 -> on_thread_reaped, unsafe.rs:708), so live_count");
    println!("        drops below MAX_THREADS and admission SUCCEEDS. The modeled refusal");
    println!("        transition (execR while deferred != {{}}) is UNREACHABLE in the code.");
    println!();
    println!("VERDICT-SUPPORT: spec artifact (over-permissive ExecRefuse) -> SPEC_REPAIR");
}
