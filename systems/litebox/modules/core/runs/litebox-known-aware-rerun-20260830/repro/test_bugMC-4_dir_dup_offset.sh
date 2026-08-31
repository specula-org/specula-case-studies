#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-4/worktree"
TMPDIR_ROOT="${TMPDIR:-/tmp}"
TMP_REPO="$(mktemp -d "$TMPDIR_ROOT/litebox-mc4-repro.XXXXXX")"
LOG="$TMP_REPO/mc4-cargo-test.log"

cleanup() {
    rm -rf "$TMP_REPO"
}
trap cleanup EXIT

echo "MC-4 repro: source=$WORKTREE"
echo "MC-4 repro: temp=$TMP_REPO"

if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude target --exclude .git "$WORKTREE"/ "$TMP_REPO"/
else
    cp -a "$WORKTREE"/. "$TMP_REPO"/
    rm -rf "$TMP_REPO/.git" "$TMP_REPO/target"
fi

cat >> "$TMP_REPO/litebox_shim_linux/src/syscalls/tests.rs" <<'RS'

#[test]
fn bug_mc4_dup_directory_descriptors_should_share_getdents_offset() {
    fn read_chunk_names(
        task: &crate::Task<crate::syscalls::tests::TestPlatform>,
        fd: i32,
    ) -> std::vec::Vec<std::string::String> {
        let mut buffer = [0u8; 43];
        let bytes = task
            .sys_getdirent64(
                fd,
                UserPtrMut::from_usize(buffer.as_mut_ptr() as usize),
                buffer.len(),
            )
            .expect("getdents64 should read a directory chunk");

        let mut names = std::vec::Vec::new();
        let mut offset = 0;
        while offset < bytes {
            let (dirent, _) =
                litebox_common_linux::LinuxDirent64::read_from_prefix(&buffer[offset..bytes])
                    .unwrap();
            let start =
                offset + core::mem::offset_of!(litebox_common_linux::LinuxDirent64, __name);
            let end = offset + dirent.len as usize;
            let name_bytes = &buffer[start..end];
            let null_pos = name_bytes
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(name_bytes.len());
            names.push(std::string::String::from(
                std::str::from_utf8(&name_bytes[..null_pos]).unwrap(),
            ));
            offset += dirent.len as usize;
        }
        names
    }

    let task = init_platform(None);
    let dir_fd = task
        .sys_open("/", OFlags::RDONLY, Mode::empty())
        .expect("open / should produce a directory fd") as i32;
    let dup_fd = task
        .sys_dup(dir_fd, None, None)
        .expect("dup of directory fd should succeed") as i32;

    let original_chunk = read_chunk_names(&task, dir_fd);
    let duplicate_chunk = read_chunk_names(&task, dup_fd);

    std::println!(
        "MC4_OBSERVED dir_fd={dir_fd} dup_fd={dup_fd} original_chunk={original_chunk:?} duplicate_chunk={duplicate_chunk:?}"
    );

    assert_ne!(
        original_chunk, duplicate_chunk,
        "duplicated directory fd repeated the same directory chunk; directory position is not shared across aliases"
    );
}
RS

set +e
CARGO_TARGET_DIR="$TMP_REPO/target" timeout 10m cargo test \
    --manifest-path "$TMP_REPO/Cargo.toml" \
    -p litebox_shim_linux \
    bug_mc4_dup_directory_descriptors_should_share_getdents_offset \
    -- --nocapture >"$LOG" 2>&1
STATUS=$?
set -e

cat "$LOG"
echo "MC-4 repro: cargo_status=$STATUS"

if grep -Fq 'MC4_OBSERVED' "$LOG" \
    && grep -Fq 'original_chunk=[".", ".."]' "$LOG" \
    && grep -Fq 'duplicate_chunk=[".", ".."]' "$LOG" \
    && [ "$STATUS" -ne 0 ]; then
    echo "MC-4 RESULT: BUG REPRODUCED - dup alias repeated the first directory chunk"
    exit 0
fi

echo "MC-4 RESULT: NOT REPRODUCED"
exit 1
