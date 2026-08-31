#!/usr/bin/env bash
set -euo pipefail

SRC="/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-3/worktree"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/litebox-mc3-repro.XXXXXX")"
WORK="$TMP_ROOT/worktree"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

rsync -a --exclude target "$SRC"/ "$WORK"/

python3 - "$WORK/litebox_shim_linux/src/syscalls/file.rs" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
insert = r'''

    fn mc3_write_replacement_file(
        task: &crate::Task<crate::syscalls::tests::TestPlatform>,
        path: &str,
    ) {
        let fd = task
            .sys_open(
                path,
                OFlags::CREAT | OFlags::WRONLY | OFlags::TRUNC,
                Mode::RUSR | Mode::WUSR,
            )
            .expect("create replacement file");
        assert_eq!(task.sys_write(fd as i32, b"BBBB", None).unwrap(), 4);
        task.sys_close(fd as i32).expect("close replacement file");
    }

    #[test]
    fn mc3_level0_black_box_probe_no_timing() {
        let task = crate::syscalls::tests::init_platform(None);
        mc3_write_replacement_file(&task, "/mc3_level0_reused.txt");

        let (read_fd, write_fd) = task.sys_pipe2(OFlags::empty()).expect("pipe2");
        let read_fd_i32 = read_fd as i32;
        let write_fd_i32 = write_fd as i32;

        let replacement_seen = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(u32::MAX));
        let replacement_seen_child = replacement_seen.clone();
        let closer = task.spawn_clone_for_test(move |child| {
            child.sys_close(read_fd_i32).expect("close original read fd");
            let replacement = child
                .sys_open("/mc3_level0_reused.txt", OFlags::RDONLY, Mode::empty())
                .expect("open replacement file");
            replacement_seen_child.store(replacement, std::sync::atomic::Ordering::SeqCst);
            assert_eq!(replacement, read_fd);
            let _ = child.sys_write(write_fd_i32, b"AAAA", None);
            let _ = child.sys_write(write_fd_i32, b"CCCC", None);
        });

        let mut first = [0u8; 4];
        let mut second = [0u8; 4];
        let iovs = [
            IoReadVec {
                iov_base: UserPtrMut::from_usize(first.as_mut_ptr().expose_provenance()),
                iov_len: first.len(),
            },
            IoReadVec {
                iov_base: UserPtrMut::from_usize(second.as_mut_ptr().expose_provenance()),
                iov_len: second.len(),
            },
        ];

        let result = task.sys_readv(
            read_fd_i32,
            UserPtr::from_usize(iovs.as_ptr().expose_provenance()),
            iovs.len(),
        );
        closer.join().unwrap();

        std::println!(
            "LEVEL0_PROBE result={result:?} replacement_fd={} first={:?} second={:?}",
            replacement_seen.load(std::sync::atomic::Ordering::SeqCst),
            std::str::from_utf8(&first).unwrap_or("<non-utf8>"),
            std::str::from_utf8(&second).unwrap_or("<non-utf8>")
        );
    }

    #[test]
    fn mc3_level1_readv_fd_reuse_mixes_pipe_and_file() {
        let task = crate::syscalls::tests::init_platform(None);
        mc3_write_replacement_file(&task, "/mc3_level1_reused.txt");

        let (read_fd, write_fd) = task.sys_pipe2(OFlags::empty()).expect("pipe2");
        let read_fd_i32 = read_fd as i32;
        let write_fd_i32 = write_fd as i32;

        let replacement_seen = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(u32::MAX));
        let replacement_seen_child = replacement_seen.clone();
        let closer = task.spawn_clone_for_test(move |child| {
            std::thread::sleep(std::time::Duration::from_millis(150));
            child.sys_close(read_fd_i32).expect("close original read fd");
            let replacement = child
                .sys_open("/mc3_level1_reused.txt", OFlags::RDONLY, Mode::empty())
                .expect("open replacement file");
            replacement_seen_child.store(replacement, std::sync::atomic::Ordering::SeqCst);
            assert_eq!(replacement, read_fd);
            let wrote = child
                .sys_write(write_fd_i32, b"AAAA", None)
                .expect("write first pipe chunk");
            assert_eq!(wrote, 4);
            std::thread::sleep(std::time::Duration::from_millis(100));
            let _ = child.sys_write(write_fd_i32, b"CCCC", None);
        });

        let mut first = [0u8; 4];
        let mut second = [0u8; 4];
        let iovs = [
            IoReadVec {
                iov_base: UserPtrMut::from_usize(first.as_mut_ptr().expose_provenance()),
                iov_len: first.len(),
            },
            IoReadVec {
                iov_base: UserPtrMut::from_usize(second.as_mut_ptr().expose_provenance()),
                iov_len: second.len(),
            },
        ];

        let n = task
            .sys_readv(
                read_fd_i32,
                UserPtr::from_usize(iovs.as_ptr().expose_provenance()),
                iovs.len(),
            )
            .expect("readv should return bytes");
        closer.join().unwrap();

        std::println!(
            "LEVEL1_TRIGGER n={n} original_read_fd={read_fd} writer_fd={write_fd} replacement_fd={} first={:?} second={:?}",
            replacement_seen.load(std::sync::atomic::Ordering::SeqCst),
            std::str::from_utf8(&first).unwrap(),
            std::str::from_utf8(&second).unwrap()
        );
        std::println!(
            "BUG_TRIGGERED: one sys_readv read first iovec from the original pipe OFD and second iovec from the file reopened on the same raw fd"
        );

        assert_eq!(n, 8);
        assert_eq!(&first, b"AAAA");
        assert_eq!(&second, b"BBBB");
    }
'''

marker = "\n}\n"
idx = text.rfind(marker)
if idx < 0:
    raise SystemExit("could not find end of syscalls::file tests module")
text = text[:idx] + insert + text[idx:]
path.write_text(text)
PY

cd "$WORK"
export CARGO_TARGET_DIR="$SRC/target"
echo "RUN: timeout 10m cargo test -p litebox_shim_linux mc3_ --lib -- --nocapture --test-threads=1"
timeout 10m cargo test -p litebox_shim_linux mc3_ --lib -- --nocapture --test-threads=1
