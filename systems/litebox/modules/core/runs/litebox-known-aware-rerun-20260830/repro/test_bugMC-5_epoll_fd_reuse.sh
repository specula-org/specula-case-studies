#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${LITEBOX_SRC:-/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-5/worktree}"

if [[ ! -d "$SOURCE_REPO/litebox_shim_linux" ]]; then
  echo "source repo not found: $SOURCE_REPO" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/litebox-mc5.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

WORK="$TMP_ROOT/worktree"
mkdir -p "$WORK"
rsync -a --exclude='.git' --exclude='target' "$SOURCE_REPO"/ "$WORK"/

cat >> "$WORK/litebox_shim_linux/src/syscalls/epoll.rs" <<'RS'

#[cfg(test)]
mod bugmc5_last_close_raw_fd_reuse_repro {
    extern crate std;

    use crate::{
        UserPtr,
        syscalls::tests::{TestPlatform, init_platform},
    };
    use litebox::{event::Events, fs::OFlags};
    use litebox_common_linux::{EpollCreateFlags, EpollEvent, EpollOp};

    use super::EpollSubsystem;

    fn interest_counts(task: &crate::Task<TestPlatform>, epfd: i32) -> (usize, usize) {
        let epoll_fd = {
            let files = task.files.borrow();
            files
                .raw_descriptor_store
                .read()
                .fd_from_raw_integer::<EpollSubsystem<TestPlatform>>(epfd as usize)
                .unwrap()
        };
        let handle = {
            let descriptors = task.global.litebox.descriptor_table();
            descriptors.entry_handle(&epoll_fd).unwrap()
        };
        handle.with_entry(|epoll_file| {
            let interests = epoll_file.interests.lock();
            let stale = interests
                .values()
                .filter(|entry| entry.desc.upgrade().is_none())
                .count();
            (interests.len(), stale)
        })
    }

    #[test]
    fn test_bugmc5_last_close_raw_fd_reuse_accumulates_interests() {
        let task = init_platform(None);
        let epfd = task
            .sys_epoll_create(EpollCreateFlags::empty())
            .expect("epoll_create failed") as i32;

        let mut expected_recycled_rfd = None;
        for round in 1u64..=6 {
            let (rfd, wfd) = task.sys_pipe2(OFlags::empty()).expect("pipe2 failed");
            if let Some(expected) = expected_recycled_rfd {
                assert_eq!(
                    rfd, expected,
                    "raw fd reuse must be reached by normal pipe2 allocation"
                );
            } else {
                expected_recycled_rfd = Some(rfd);
            }

            let event = EpollEvent {
                events: Events::IN.bits(),
                data: round,
            };
            task
                .sys_epoll_ctl(
                    epfd,
                    EpollOp::EpollCtlAdd,
                    rfd as i32,
                    UserPtr::from_usize((&raw const event).addr()),
                )
                .expect("epoll_ctl add failed");

            task.sys_close(rfd as i32).expect("close read fd failed");
            task.sys_close(wfd as i32).expect("close write fd failed");

            let (total, stale) = interest_counts(&task, epfd);
            std::println!(
                "round={round} recycled_fd={rfd} write_fd={wfd} retained_interests={total} stale_interests={stale}"
            );
        }

        let (total, stale) = interest_counts(&task, epfd);
        assert_eq!(
            (total, stale),
            (0, 0),
            "MC-5 reproduced: stale interests retained after last close"
        );
    }
}
RS

LOG="$TMP_ROOT/repro.log"
set +e
(
  cd "$WORK"
  CARGO_TARGET_DIR="$SOURCE_REPO/target" timeout 5m cargo test \
    -p litebox_shim_linux \
    bugmc5_last_close_raw_fd_reuse_accumulates_interests \
    -- --nocapture
) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

echo "cargo_status=$status"

if grep -q "retained_interests=6 stale_interests=6" "$LOG" \
  && grep -q "MC-5 reproduced: stale interests retained after last close" "$LOG"; then
  echo "MC-5 reproduced: public syscalls left stale epoll interests after last close and raw-fd reuse"
  exit 0
fi

echo "MC-5 not reproduced: expected stale-interest evidence was not observed" >&2
exit 1
