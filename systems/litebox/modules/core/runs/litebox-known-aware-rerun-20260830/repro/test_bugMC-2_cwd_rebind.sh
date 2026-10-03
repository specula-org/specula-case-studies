#!/usr/bin/env bash
set -euo pipefail

REPO="${LITEBOX_REPO:-/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-2/worktree}"
WORK="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

DEST="$WORK/litebox"
mkdir -p "$DEST"

if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude target --exclude .git "$REPO/" "$DEST/"
else
    tar -C "$REPO" --exclude='./target' --exclude='./.git' -cf - . | tar -C "$DEST" -xf -
fi

TEST_FILE="$DEST/litebox_shim_linux/src/syscalls/file.rs"
TMP_FILE="$WORK/file.rs"

head -n -1 "$TEST_FILE" > "$TMP_FILE"
cat >> "$TMP_FILE" <<'RS'

    #[test]
    fn cwd_path_recreation_redirects_relative_open() {
        use litebox_common_linux::AtFlags;

        let task = crate::syscalls::tests::init_platform(None);
        let cwd_path = "/mc2_recreated_cwd";
        let replacement_file = "/mc2_recreated_cwd/attacker.txt";
        let payload = b"replacement namespace payload";

        task.sys_mkdirat(litebox_common_linux::AT_FDCWD, cwd_path, 0o777)
            .expect("create original cwd directory");
        task.sys_chdir(cwd_path).expect("chdir into original directory");
        std::println!("STEP chdir: cwd stored as {cwd_path}");

        task.sys_unlinkat(
            litebox_common_linux::AT_FDCWD,
            cwd_path,
            AtFlags::AT_REMOVEDIR,
        )
        .expect("remove pathname of current directory");
        std::println!("STEP remove: original cwd pathname removed");

        task.sys_mkdirat(litebox_common_linux::AT_FDCWD, cwd_path, 0o777)
            .expect("recreate same pathname as replacement directory");
        std::println!("STEP recreate: replacement directory now owns {cwd_path}");

        let writer = task
            .sys_open(
                replacement_file,
                OFlags::CREAT | OFlags::WRONLY,
                Mode::RUSR | Mode::WUSR,
            )
            .expect("create attacker-controlled replacement file");
        task.sys_write(i32::try_from(writer).unwrap(), payload, None)
            .expect("write payload to replacement file");
        task.sys_close(i32::try_from(writer).unwrap())
            .expect("close replacement writer");
        std::println!("STEP attacker: wrote payload to {replacement_file}");

        let reader = task
            .sys_open("attacker.txt", OFlags::RDONLY, Mode::empty())
            .expect("BUG: relative open from stale cwd should not resolve into replacement path");
        let mut buf = [0u8; 64];
        let n = task
            .sys_read(i32::try_from(reader).unwrap(), &mut buf, None)
            .expect("read through redirected relative fd");
        task.sys_close(i32::try_from(reader).unwrap())
            .expect("close redirected reader");

        let observed = core::str::from_utf8(&buf[..n]).unwrap();
        std::println!("OBSERVED relative_read={observed:?}");
        std::println!("OBSERVED replacement_path_stat={:?}", task.sys_stat(replacement_file));

        assert_eq!(&buf[..n], payload);
        assert!(
            task.sys_stat(replacement_file).is_ok(),
            "relative open must not create or consume replacement namespace state"
        );
        std::println!(
            "BUG_TRIGGERED: relative open after cwd pathname removal/recreation read replacement namespace file"
        );
    }
RS
tail -n 1 "$TEST_FILE" >> "$TMP_FILE"
mv "$TMP_FILE" "$TEST_FILE"

cd "$DEST"
echo "COMMAND: timeout 5m cargo test -p litebox_shim_linux syscalls::file::tests::cwd_path_recreation_redirects_relative_open -- --nocapture"
timeout 5m cargo test -p litebox_shim_linux syscalls::file::tests::cwd_path_recreation_redirects_relative_open -- --nocapture
