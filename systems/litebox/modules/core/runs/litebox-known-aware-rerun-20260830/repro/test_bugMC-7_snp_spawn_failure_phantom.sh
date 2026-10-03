#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-7/worktree"
TEST_FILE="$REPO/litebox_shim_linux/src/syscalls/tla_scenarios.rs"
BACKUP="$(mktemp)"

cp "$TEST_FILE" "$BACKUP"
cleanup() {
    cp "$BACKUP" "$TEST_FILE"
    rm -f "$BACKUP"
}
trap cleanup EXIT

cat >> "$TEST_FILE" <<'RUST'

#[test]
fn test_bugmc7_spawn_failure_leaves_phantom_and_blocks_wait_for_exit() {
    use std::sync::mpsc;
    use std::time::Duration;

    let task = super::tests::init_platform(None);
    let process = task.process().clone();

    std::println!("initial sysinfo.procs: {}", task.sys_sysinfo().procs);
    std::println!("initial process.nr_threads: {}", process.nr_threads());
    assert_eq!(task.sys_sysinfo().procs, 1);
    assert_eq!(process.nr_threads(), 1);

    let mut parent_tid = -1;
    let mut stack = [0u8; 4096];
    let args = clone_args(&mut parent_tid, &mut stack, true);

    litebox_tla_trace::reset_model();
    litebox_tla_trace::init_thread(
        "bugmc7_snp_spawn_failure_phantom",
        "t0",
        &[
            "TaskDoClonePrepare",
            "TaskDoClonePublishParentTid",
            "TaskDoCloneStackValidationSuccess",
            "ThreadStateNewThread",
            "TaskDoCloneTransferInit",
            "SnpLinuxKernelSpawnThreadFailure",
            "ProcessDetachThread",
        ],
    );
    litebox_tla_trace::clone_override(Some(false));

    let result = task.sys_clone3(
        &litebox_common_linux::PtRegs::default(),
        UserPtr::from_usize((&raw const args).addr()),
    );

    std::println!("clone3 result: {:?}", result);
    std::println!("parent_tid after clone3: {}", parent_tid);
    std::println!("sysinfo.procs after failed clone3: {}", task.sys_sysinfo().procs);
    std::println!(
        "process.nr_threads after failed clone3: {}",
        process.nr_threads()
    );

    assert!(
        matches!(result, Err(litebox_common_linux::errno::Errno::ENOMEM)),
        "forced SNP spawn failure should surface to clone3 as ENOMEM"
    );
    assert!(
        parent_tid > 0,
        "clone3 published the child TID before the platform spawn failed"
    );
    assert_eq!(
        task.sys_sysinfo().procs,
        2,
        "failed clone should have rolled back to one thread, but the phantom child remains counted"
    );
    assert_eq!(
        process.nr_threads(),
        2,
        "process thread counter includes the phantom child after failed spawn"
    );

    drop(task);
    std::println!(
        "process.nr_threads after dropping only real task: {}",
        process.nr_threads()
    );
    assert_eq!(
        process.nr_threads(),
        1,
        "parent detach leaves the leaked phantom thread attached"
    );
    litebox_tla_trace::shutdown();

    let (tx, rx) = mpsc::channel();
    let waiter_process = process.clone();
    std::thread::spawn(move || {
        let status = waiter_process.wait_for_exit();
        let _ = tx.send(status);
    });

    match rx.recv_timeout(Duration::from_millis(250)) {
        Ok(status) => panic!(
            "wait_for_exit unexpectedly returned despite phantom thread: {:?}",
            status
        ),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            std::println!(
                "wait_for_exit observation: still blocked after 250 ms with nr_threads={}",
                process.nr_threads()
            );
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            panic!("wait_for_exit observer disconnected")
        }
    }
}
RUST

export LITEBOX_TLA_RAW_DIR="${TMPDIR:-/tmp}/litebox_mc7_repro_traces"
rm -rf "$LITEBOX_TLA_RAW_DIR"

cd "$REPO"
echo "Level 0: attempted normal/public clone path analysis in this harness; it cannot force the required SNP host clone3 failure, so it does not trigger MC-7."
echo "Level 1: timing assistance is inapplicable; the bug is a deterministic failed-spawn cleanup path, not a race window."
echo "Level 2: executing valid sys_clone3, then injecting the admissible counterexample step MCSnpLinuxKernelSpawnThreadFailure(t0) via the existing tla_trace clone override."
CMD=(
    cargo test
    -p litebox_shim_linux
    --features tla_trace
    syscalls::tla_scenarios::test_bugmc7_spawn_failure_leaves_phantom_and_blocks_wait_for_exit
    --
    --exact
    --nocapture
    --test-threads=1
)

echo "running: ${CMD[*]}"
timeout 5m "${CMD[@]}"
