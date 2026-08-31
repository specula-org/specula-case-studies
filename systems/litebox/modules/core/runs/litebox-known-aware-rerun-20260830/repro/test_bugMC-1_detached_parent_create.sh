#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-1/worktree}"
TMPROOT="$(mktemp -d /dev/shm/litebox-mc1.XXXXXX 2>/dev/null || mktemp -d)"
WORK="$TMPROOT/repo"
cleanup() {
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

mkdir -p "$WORK"
(cd "$SOURCE_REPO" && tar --exclude='./target' --exclude='./.git' -cf - .) | (cd "$WORK" && tar -xf -)

cat >> "$WORK/litebox/src/fs/tests.rs" <<'RS'

#[cfg(test)]
mod specula_mc1_detached_parent_create {
    extern crate std;

    use crate::LiteBox;
    use crate::fs::{Mode, OFlags, UserInfo};
    use crate::platform::mock::MockPlatform;
    use std::format;
    use std::println;
    use std::string::String;
    use std::sync::{Arc, Barrier};
    use std::thread;
    use std::time::Duration;

    #[derive(Debug)]
    struct RaceOutcome {
        level: &'static str,
        attempt: usize,
        depth: usize,
        remover_delay_ns: u64,
        create_result: String,
        rmdir_result: String,
        write_result: String,
        fd_status_result: String,
        child_reachable_after: bool,
        parent_reachable_after: bool,
    }

    fn root_context() -> crate::fs::resolver::Context {
        let mut ctx = crate::fs::resolver::Context::new();
        ctx.set_acting_user(UserInfo::ROOT);
        ctx
    }

    fn build_fs() -> Arc<super::InMemFs> {
        let litebox = LiteBox::new(MockPlatform::new());
        Arc::new(super::in_mem_fs(&litebox))
    }

    fn mkdir_ok_or_exists(fs: &super::InMemFs, ctx: &crate::fs::resolver::Context, path: &str) {
        match fs.mkdir(ctx, path, Mode::RWXU | Mode::RWXG | Mode::RWXO) {
            Ok(()) => {}
            Err(crate::fs::errors::MkdirError::AlreadyExists) => {}
            Err(error) => panic!("mkdir {path}: {error:?}"),
        }
    }

    fn make_base(
        fs: &super::InMemFs,
        ctx: &crate::fs::resolver::Context,
        level: &str,
        depth: usize,
    ) -> String {
        let mut path = format!("/specula_mc1_{level}_{depth}");
        mkdir_ok_or_exists(fs, ctx, &path);
        for i in 0..depth {
            path.push('/');
            path.push_str(&format!("d{i:04}"));
            mkdir_ok_or_exists(fs, ctx, &path);
        }
        path
    }

    fn one_race(
        fs: Arc<super::InMemFs>,
        ctx: crate::fs::resolver::Context,
        level: &'static str,
        base: &str,
        attempt: usize,
        depth: usize,
        remover_delay_ns: u64,
    ) -> Option<RaceOutcome> {
        let victim = format!("{base}/victim_{attempt:06}");
        let child = format!("{victim}/child");
        mkdir_ok_or_exists(&fs, &ctx, &victim);

        let start = Arc::new(Barrier::new(3));
        let creator_start = Arc::clone(&start);
        let remover_start = Arc::clone(&start);

        let create_fs = Arc::clone(&fs);
        let create_ctx = ctx.clone();
        let create_child = child.clone();
        let creator = thread::spawn(move || {
            creator_start.wait();
            match create_fs.open(&create_ctx, &create_child, OFlags::CREAT | OFlags::RDWR, Mode::RWXU) {
                Ok(fd) => {
                    let write_result = match create_fs.write(&fd, b"mc1", None) {
                        Ok(n) => format!("Ok({n})"),
                        Err(error) => format!("Err({error:?})"),
                    };
                    let fd_status_result = match create_fs.fd_file_status(&fd) {
                        Ok(status) => format!("Ok(ino={}, size={})", status.node_info.ino, status.size),
                        Err(error) => format!("Err({error:?})"),
                    };
                    let close_result = create_fs.close(&fd);
                    (
                        String::from("Ok(fd)"),
                        write_result,
                        format!("{fd_status_result}; close={close_result:?}"),
                    )
                }
                Err(error) => (
                    format!("Err({error:?})"),
                    String::from("not-run"),
                    String::from("not-run"),
                ),
            }
        });

        let remove_fs = Arc::clone(&fs);
        let remove_ctx = ctx.clone();
        let remove_victim = victim.clone();
        let remover = thread::spawn(move || {
            remover_start.wait();
            if remover_delay_ns > 0 {
                thread::sleep(Duration::from_nanos(remover_delay_ns));
            }
            match remove_fs.rmdir(&remove_ctx, &remove_victim) {
                Ok(()) => String::from("Ok(())"),
                Err(error) => format!("Err({error:?})"),
            }
        });

        start.wait();
        let (create_result, write_result, fd_status_result) = creator.join().unwrap();
        let rmdir_result = remover.join().unwrap();
        let child_reachable_after = fs.file_status(&ctx, &child).is_ok();
        let parent_reachable_after = fs.file_status(&ctx, &victim).is_ok();

        let hit = create_result == "Ok(fd)"
            && rmdir_result == "Ok(())"
            && write_result == "Ok(3)"
            && fd_status_result.starts_with("Ok(")
            && !child_reachable_after
            && !parent_reachable_after;

        let outcome = RaceOutcome {
            level,
            attempt,
            depth,
            remover_delay_ns,
            create_result,
            rmdir_result,
            write_result,
            fd_status_result,
            child_reachable_after,
            parent_reachable_after,
        };

        if hit {
            Some(outcome)
        } else {
            let _ = fs.unlink(&ctx, &child);
            let _ = fs.rmdir(&ctx, &victim);
            None
        }
    }

    fn run_races(
        level: &'static str,
        depth: usize,
        attempts: usize,
        remover_delay_ns: u64,
    ) -> Option<RaceOutcome> {
        let fs = build_fs();
        let ctx = root_context();
        let base = make_base(&fs, &ctx, level, depth);
        for attempt in 0..attempts {
            if let Some(hit) = one_race(
                Arc::clone(&fs),
                ctx.clone(),
                level,
                &base,
                attempt,
                depth,
                remover_delay_ns,
            ) {
                return Some(hit);
            }
        }
        None
    }

    fn reported_level(level: &'static str) -> &'static str {
        if option_env!("SPECULA_MC1_LEVEL3").is_some() {
            "level3-test-only-delay"
        } else {
            level
        }
    }

    #[test]
    fn mc1_detached_parent_create_repro() {
        println!("MC-1 Level 0: racing open(O_CREAT|O_RDWR) against rmdir on a shallow empty parent");
        if let Some(hit) = run_races(reported_level("level0"), 1, 2_000, 0) {
            println!("MC-1 BUG TRIGGERED: {hit:?}");
            return;
        }
        println!("MC-1 Level 0 result: no hit in 2000 attempts");

        println!("MC-1 Level 1: timing-assisted public API race using a deep parent path and delayed rmdir");
        for (depth, attempts, delay) in [
            (512_usize, 2_000_usize, 0_u64),
            (512, 2_000, 1_000),
            (1024, 2_000, 2_000),
            (2048, 2_000, 5_000),
            (4096, 2_000, 10_000),
        ] {
            if let Some(hit) = run_races(reported_level("level1"), depth, attempts, delay) {
                println!("MC-1 BUG TRIGGERED: {hit:?}");
                return;
            }
            println!("MC-1 Level 1 sweep depth={depth} delay_ns={delay}: no hit in {attempts} attempts");
        }

        panic!("MC-1 public API race did not trigger before Level 3 fallback");
    }
}
RS

cd "$WORK"

set +e
timeout 6m cargo test -p litebox specula_mc1_detached_parent_create::mc1_detached_parent_create_repro -- --nocapture --test-threads=1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    exit 0
fi

echo "MC-1 Level 1 did not trigger; applying Level 3 test-only spin delay in a temporary copy"
python3 - "$WORK/litebox/src/fs/resolver.rs" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = """                if !Self::can_change_entries_in_dir(context, &parent) {
                    return Err(OpenError::NoWritePerms);
                }
"""
replacement = """                #[cfg(test)]
                for _ in 0..1_000_000 {
                    core::hint::spin_loop();
                }
                if !Self::can_change_entries_in_dir(context, &parent) {
                    return Err(OpenError::NoWritePerms);
                }
"""
if needle not in text:
    raise SystemExit("resolver insertion point not found")
path.write_text(text.replace(needle, replacement, 1))
PY

SPECULA_MC1_LEVEL3=1 timeout 6m cargo test -p litebox specula_mc1_detached_parent_create::mc1_detached_parent_create_repro -- --nocapture --test-threads=1
