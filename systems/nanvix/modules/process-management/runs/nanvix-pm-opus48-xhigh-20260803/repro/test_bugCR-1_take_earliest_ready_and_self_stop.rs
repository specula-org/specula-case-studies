// Reproduction for finding CR-1 (Code Review): "Location & state-machine integrity"
// residual gaps —
//   A) deferred self-stop can run one extra quantum before deschedule
//      (src/kernel/src/pm/process/manager/mod.rs:951-966 + 2674-2697)
//   B) take_earliest_ready()'s `.expect` (mod.rs:2691-2693) would panic if every ready
//      process were stopped, allegedly relying on an UNENFORCED
//      "kernel process is never stopped" invariant.
//
// This is a `no_std` kernel with only in-kernel (boot-time) tests, so the scheduler
// cannot be host-unit-tested directly. This program is a FAITHFUL host port of the
// exact algorithm + guards from the cited sites (line refs inline). It walks the
// escalation ladder and shows:
//   * Level 0 (real API): stopping every process via the real kill/SIGSTOP path
//     (stop_process) CANNOT stop the kernel, so take_earliest_ready always finds a
//     non-stopped candidate — no panic. The invariant is ENFORCED, not assumed.
//   * Level 2 (state injection): only by FORCIBLY marking every ready process stopped
//     (bypassing stop_process's kernel guard — a state the real API refuses to build)
//     does `.expect` panic. That precondition is unreachable, so B is a FALSE POSITIVE.
//   * Concern A: a self-stopping running process is deferred but NEVER re-dispatched
//     while stopped (NoStoppedDispatch holds); it self-resolves at the next schedule().
//
// Build & run:  rustc -O test_bugCR-1_take_earliest_ready_and_self_stop.rs \
//                     -o /tmp/cr1 && /tmp/cr1
// (exit 0 => concerns are FALSE POSITIVE; exit != 0 => a concern reproduced.)

use std::panic;

const KERNEL: i32 = 0; // ProcessIdentifier::KERNEL

#[derive(Clone)]
struct ReadyProc {
    pid: i32,
    admission_time: u64,
    stopped: bool, // ProcessState::is_stopped()
}

// Faithful model of the manager's process lists relevant to scheduling.
struct Manager {
    ready: Vec<ReadyProc>,          // self.ready
    running: Option<ReadyProc>,     // self.running
    // The kernel is, by construction of the real guards, never in suspended/interrupted/
    // zombie; we don't model those lists because no path can put the kernel there.
}

// ---- Faithful port of stop_process (mod.rs:951-966) ----
// Returns Err (like ErrorCode::InvalidArgument) for the kernel process; else stops it.
fn stop_process(m: &mut Manager, pid: i32) -> Result<(), &'static str> {
    if pid == KERNEL {
        // mod.rs:955-959 — "cannot stop the kernel process"
        return Err("cannot stop the kernel process");
    }
    // A process the real API can only stop when it is NOT the running one
    // (cross-process posting is relayed through the PM daemon; self-stop marks the
    // running process, handled separately in concern A). Model both: find on ready or
    // running.
    if let Some(p) = m.ready.iter_mut().find(|p| p.pid == pid) {
        p.stopped = true; // mod.rs:963 set_stopped(true)
        return Ok(());
    }
    if let Some(ref mut r) = m.running {
        if r.pid == pid {
            r.stopped = true;
            return Ok(());
        }
    }
    Err("no such process")
}

// ---- Faithful port of take_earliest_ready (mod.rs:2674-2697) ----
// Panics (via .expect) iff every ready process is stopped.
fn take_earliest_ready(m: &mut Manager) -> ReadyProc {
    let mut selected: Option<(usize, u64)> = None;
    for (i, process) in m.ready.iter().enumerate() {
        if process.stopped {
            continue; // skip job-control stopped processes
        }
        let t = process.admission_time;
        match selected {
            Some((_, earliest)) if earliest <= t => {}
            _ => selected = Some((i, t)),
        }
    }
    let index = selected
        .expect("there should always be a non-stopped process ready to run")
        .0;
    m.ready.remove(index)
}

// ---- Faithful port of schedule()'s reschedule prologue (mod.rs:1671-1685) ----
// Push running back onto ready, then pick the next via take_earliest_ready.
fn schedule(m: &mut Manager) -> ReadyProc {
    if let Some(prev) = m.running.take() {
        m.ready.push_back_compat(prev); // self.ready.push_back(previous_process)
    }
    let next = take_earliest_ready(m);
    m.running = Some(next.clone());
    next
}

// small helper so the intent reads like push_back
trait PushBack {
    fn push_back_compat(&mut self, p: ReadyProc);
}
impl PushBack for Vec<ReadyProc> {
    fn push_back_compat(&mut self, p: ReadyProc) {
        self.push(p);
    }
}

fn fresh_manager(n_user: usize) -> Manager {
    // Kernel (pid 0) plus n_user user processes, all initially on the ready list.
    let mut ready = vec![ReadyProc { pid: KERNEL, admission_time: 0, stopped: false }];
    for k in 0..n_user {
        ready.push(ReadyProc {
            pid: (k as i32) + 1,
            admission_time: (k as u64) + 1,
            stopped: false,
        });
    }
    Manager { ready, running: None }
}

fn main() {
    let mut all_ok = true;
    println!("== CR-1 reproduction: take_earliest_ready `.expect` + deferred self-stop ==\n");

    // -----------------------------------------------------------------------------
    // Concern B — Level 0: real API. Try to stop EVERY process (incl. the kernel)
    // via the real kill/SIGSTOP path (stop_process), then schedule. Expect: kernel
    // refuses to stop, take_earliest_ready returns the kernel, no panic.
    // -----------------------------------------------------------------------------
    println!("[B/Level 0] real API: SIGSTOP every process (incl. kernel), then schedule");
    {
        let mut m = fresh_manager(3);
        let pids: Vec<i32> = m.ready.iter().map(|p| p.pid).collect();
        for pid in pids {
            match stop_process(&mut m, pid) {
                Ok(()) => println!("    stop_process(pid={pid}) -> Ok (stopped)"),
                Err(e) => println!("    stop_process(pid={pid}) -> Err(\"{e}\")  <-- guard fired"),
            }
        }
        let non_stopped = m.ready.iter().filter(|p| !p.stopped).count();
        println!(
            "    ready list: {} process(es), {} non-stopped",
            m.ready.len(),
            non_stopped
        );
        let res = panic::catch_unwind(panic::AssertUnwindSafe(|| take_earliest_ready(&mut m)));
        match res {
            Ok(sel) => {
                println!("    take_earliest_ready() -> selected pid={} (no panic)", sel.pid);
                if sel.pid == KERNEL && non_stopped >= 1 {
                    println!("    PASS: kernel stayed runnable; `.expect` did not fire.\n");
                } else {
                    println!("    UNEXPECTED selection\n");
                    all_ok = false;
                }
            }
            Err(_) => {
                println!("    REPRODUCED: `.expect` panicked via real API!\n");
                all_ok = false;
            }
        }
    }

    // -----------------------------------------------------------------------------
    // Concern B — Level 2: state injection. Forcibly mark EVERY ready process stopped
    // (bypassing stop_process's kernel guard). This is the ONLY way to reach the panic.
    // Document that this precondition is UNREACHABLE through the real API.
    // -----------------------------------------------------------------------------
    println!("[B/Level 2] INJECT unreachable state: force ALL ready stopped (bypass guard)");
    {
        let mut m = fresh_manager(3);
        for p in m.ready.iter_mut() {
            p.stopped = true; // <-- bypasses stop_process(); real API never does this to the kernel
        }
        println!("    (injected: kernel forcibly stopped — stop_process would have refused this)");
        let res = panic::catch_unwind(panic::AssertUnwindSafe(|| take_earliest_ready(&mut m)));
        match res {
            Ok(sel) => {
                println!("    take_earliest_ready() -> pid={} (no panic?!)\n", sel.pid);
                all_ok = false;
            }
            Err(_) => {
                println!("    `.expect` panicked — but ONLY under the injected state.");
                println!("    This precondition is UNREACHABLE via the real API:");
                println!("      - stop_process rejects KERNEL (mod.rs:955-959)");
                println!("      - kernel never sleeps/exits (mod.rs:1773/2125/2215) => never off `ready`");
                println!("    => Concern B is a FALSE POSITIVE (enforced invariant).\n");
            }
        }
    }

    // -----------------------------------------------------------------------------
    // Concern A — deferred self-stop. A running process stops itself; it is NOT
    // descheduled immediately, but at the next schedule() it is pushed to ready and
    // skipped. Assert it is never re-dispatched while stopped (NoStoppedDispatch).
    // -----------------------------------------------------------------------------
    println!("[A] deferred self-stop: running process stops itself, then schedule()");
    {
        let mut m = fresh_manager(2);
        // Make user pid=1 the running process (as if it had been dispatched).
        let idx = m.ready.iter().position(|p| p.pid == 1).unwrap();
        let running = m.ready.remove(idx);
        m.running = Some(running);
        println!("    running = pid=1 (user); it calls kill(self, self, SIGSTOP)");
        stop_process(&mut m, 1).unwrap(); // self-stop marks the running process
        let ran_extra = m.running.as_ref().map(|r| r.stopped).unwrap_or(false);
        println!(
            "    after stop_process: running pid=1 stopped={} (still on CPU -> may finish its quantum)",
            ran_extra
        );

        // Next scheduling opportunity: schedule() pushes it to ready and picks next.
        let next = schedule(&mut m);
        println!("    schedule() -> next dispatched pid={}", next.pid);
        // The self-stopped process must NOT be the one re-dispatched.
        if next.pid == 1 {
            println!("    REPRODUCED: stopped process was re-dispatched (NoStoppedDispatch violated)\n");
            all_ok = false;
        } else {
            // And it must now be sitting on ready, flagged stopped, skipped henceforth.
            let p1 = m.ready.iter().find(|p| p.pid == 1);
            let parked_stopped = p1.map(|p| p.stopped).unwrap_or(false);
            println!(
                "    pid=1 now on ready with stopped={} -> skipped by take_earliest_ready",
                parked_stopped
            );
            if parked_stopped {
                println!("    PASS: self-stopper finished at most its current quantum, never");
                println!("    re-dispatched while stopped (documented at mod.rs:942-945).");
                println!("    => Concern A is intended/self-resolving: FALSE POSITIVE.\n");
            } else {
                all_ok = false;
            }
        }
    }

    println!("=========================================================");
    if all_ok {
        println!("RESULT: neither residual concern reproduced a live defect.");
        println!("  B: `.expect` unreachable (kernel-never-stopped invariant ENFORCED).");
        println!("  A: deferred self-stop documented, self-resolving, NoStoppedDispatch held.");
        std::process::exit(0);
    } else {
        println!("RESULT: a concern reproduced a real defect (see above).");
        std::process::exit(1);
    }
}
