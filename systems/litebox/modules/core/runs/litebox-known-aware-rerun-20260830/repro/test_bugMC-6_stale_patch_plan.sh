#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-6/worktree"
REPRO_DIR="/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro"
MOD_FILE="$WORKTREE/litebox_shim_linux/src/syscalls/mod.rs"
TEST_RS="$WORKTREE/litebox_shim_linux/src/syscalls/bug_mc6_repro.rs"
OLD_BIN="$WORKTREE/litebox_shim_linux/src/syscalls/bug_mc6_old_elf.bin"
VICTIM_BIN="$WORKTREE/litebox_shim_linux/src/syscalls/bug_mc6_victim.bin"
OUTPUT_FILE="$REPRO_DIR/test_bugMC-6_stale_patch_plan.output.txt"

tmpdir="$(mktemp -d)"
cleanup() {
    set +e
    if [ -f "$tmpdir/mod.rs.orig" ]; then
        cp "$tmpdir/mod.rs.orig" "$MOD_FILE"
    fi
    rm -f "$TEST_RS" "$OLD_BIN" "$VICTIM_BIN"
    rm -rf "$tmpdir"
}
trap cleanup EXIT

cd "$WORKTREE"
cp "$MOD_FILE" "$tmpdir/mod.rs.orig"

python3 - "$OLD_BIN" "$VICTIM_BIN" <<'PY'
import struct
import sys
from pathlib import Path

old_path = Path(sys.argv[1])
victim_path = Path(sys.argv[2])
page = 4096

old = bytearray(page)
old[0:16] = b"\x7fELF" + bytes([2, 1, 1, 0, 0]) + bytes(7)

def put16(buf, off, val):
    buf[off:off + 2] = struct.pack("<H", val)

def put32(buf, off, val):
    buf[off:off + 4] = struct.pack("<I", val)

def put64(buf, off, val):
    buf[off:off + 8] = struct.pack("<Q", val)

put16(old, 16, 3)       # ET_DYN
put16(old, 18, 62)      # EM_X86_64
put32(old, 20, 1)       # EV_CURRENT
put64(old, 24, 0)       # e_entry
put64(old, 32, 64)      # e_phoff
put64(old, 40, 0)       # e_shoff
put32(old, 48, 0)       # e_flags
put16(old, 52, 64)      # e_ehsize
put16(old, 54, 56)      # e_phentsize
put16(old, 56, 1)       # e_phnum

ph = 64
put32(old, ph + 0, 1)       # PT_LOAD
put32(old, ph + 4, 5)       # PF_R | PF_X
put64(old, ph + 8, 0)       # p_offset
put64(old, ph + 16, 0)      # p_vaddr
put64(old, ph + 24, 0)      # p_paddr
put64(old, ph + 32, page)   # p_filesz
put64(old, ph + 40, page)   # p_memsz
put64(old, ph + 48, page)   # p_align

victim = bytearray([0x90] * page)  # NOP sled, decoded as x86_64 instructions.
victim[128:130] = b"\x0f\x05"      # raw syscall instruction.
victim[130] = 0xC3                 # ret, not needed for the check.

old_path.write_bytes(old)
victim_path.write_bytes(victim)
PY

cat > "$TEST_RS" <<'RS'
extern crate std;

use crate::{LinuxShimBuilder, Task, UserPtrMut};
use alloc::borrow::Cow;
use alloc::sync::Arc;
use litebox::fs::{Mode, OFlags, UserInfo};
use litebox_common_linux::{MapFlags, ProtFlags};
use std::fmt::Write as _;
use std::println;
use std::sync::Once;

const TEST_TAR_FILE: &[u8] = include_bytes!("../../../litebox/src/fs/test.tar");
const OLD_ELF: &[u8] = include_bytes!("bug_mc6_old_elf.bin");
const VICTIM: &[u8] = include_bytes!("bug_mc6_victim.bin");
const PAGE: usize = litebox::mm::linux::PAGE_SIZE;
const PROBE_START: usize = 120;
const PROBE_LEN: usize = 24;
const SYSCALL_IN_PROBE: usize = 8;

fn register_cow_backing() {
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| {
        let platform = super::tests::test_platform(None);
        let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/syscalls");
        platform.register_cow_region(OLD_ELF, base.join("bug_mc6_old_elf.bin"));
        platform.register_cow_region(VICTIM, base.join("bug_mc6_victim.bin"));
    });
}

fn task_with_repro_files() -> Task<super::tests::TestPlatform> {
    register_cow_backing();
    let platform = super::tests::test_platform(None);
    let builder = LinuxShimBuilder::new(platform);
    let in_mem = litebox::fs::in_mem::InMem::new_initialized([
        (
            "/",
            litebox::fs::in_mem::InitialNode::Directory {
                mode: Mode::RWXU | Mode::RWXG | Mode::RWXO,
                owner: UserInfo::ROOT,
            },
        ),
        (
            "/old_elf",
            litebox::fs::in_mem::InitialNode::File {
                mode: Mode::RUSR,
                owner: UserInfo::ROOT,
                data: Cow::Borrowed(OLD_ELF),
            },
        ),
        (
            "/victim",
            litebox::fs::in_mem::InitialNode::File {
                mode: Mode::RUSR,
                owner: UserInfo::ROOT,
                data: Cow::Borrowed(VICTIM),
            },
        ),
    ]);
    let fs = Arc::new(builder.default_fs(in_mem, TEST_TAR_FILE.into()));
    builder.build().0.new_test_task(fs)
}

fn read_window(addr: usize) -> std::vec::Vec<u8> {
    UserPtrMut::<u8>::from_usize(addr + PROBE_START)
        .to_owned_slice::<super::tests::TestPlatform>(PROBE_LEN)
        .expect("probe window must be readable")
        .into_vec()
}

fn hex(bytes: &[u8]) -> std::string::String {
    let mut out = std::string::String::new();
    for (idx, byte) in bytes.iter().enumerate() {
        if idx != 0 {
            out.push(' ');
        }
        write!(&mut out, "{byte:02x}").unwrap();
    }
    out
}

#[test]
fn bug_mc6_stale_patch_plan_level0_public_syscalls() {
    let task = task_with_repro_files();
    let old_fd = task
        .sys_open("/old_elf", OFlags::RDONLY, Mode::empty())
        .expect("open old ELF") as i32;
    let victim_fd = task
        .sys_open("/victim", OFlags::RDONLY, Mode::empty())
        .expect("open victim") as i32;

    let old_mapping = task
        .sys_mmap(0, PAGE, ProtFlags::PROT_READ, MapFlags::MAP_PRIVATE, old_fd, 0)
        .expect("initial read-only ELF mmap");
    let base = old_mapping.as_usize();
    let old_window = read_window(base);

    let replacement = task
        .sys_mmap(
            base,
            PAGE,
            ProtFlags::PROT_READ,
            MapFlags::MAP_PRIVATE | MapFlags::MAP_FIXED,
            victim_fd,
            0,
        )
        .expect("MAP_FIXED replacement mmap");
    assert_eq!(replacement.as_usize(), base);

    let victim_before = read_window(base);
    assert_eq!(
        &victim_before[SYSCALL_IN_PROBE..SYSCALL_IN_PROBE + 2],
        &[0x0f, 0x05],
        "victim must contain an unmodified raw syscall before mprotect"
    );

    let mprotect_result = task.sys_mprotect(
        replacement,
        PAGE,
        ProtFlags::PROT_READ | ProtFlags::PROT_EXEC,
    );
    let victim_after = read_window(base);

    println!("MC6_LEVEL0_SEQUENCE=old_elf_mmap_R -> victim_mmap_MAP_FIXED_R -> mprotect_RX");
    println!("mapped_addr=0x{base:x}");
    println!("old_mapping_window_before_replace={}", hex(&old_window));
    println!("victim_window_before_mprotect={}", hex(&victim_before));
    println!("victim_window_after_mprotect={}", hex(&victim_after));
    println!(
        "syscall_bytes_before={:02x} {:02x}",
        victim_before[SYSCALL_IN_PROBE],
        victim_before[SYSCALL_IN_PROBE + 1]
    );
    println!(
        "syscall_bytes_after={:02x} {:02x}",
        victim_after[SYSCALL_IN_PROBE],
        victim_after[SYSCALL_IN_PROBE + 1]
    );
    println!("mprotect_result={mprotect_result:?}");

    assert!(mprotect_result.is_ok(), "mprotect should return success");
    assert_ne!(
        victim_before, victim_after,
        "replacement mapping should not be rewritten by stale old fd patch state"
    );
    assert_ne!(
        &victim_after[SYSCALL_IN_PROBE..SYSCALL_IN_PROBE + 2],
        &[0x0f, 0x05],
        "stale patch path did not rewrite the victim syscall bytes"
    );
    println!("MC6_LEVEL0_REPRODUCED=stale ELF patch plan rewrote replacement mapping");
}
RS

python3 - "$MOD_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
module = "\n#[cfg(test)]\nmod bug_mc6_repro;\n"
if "mod bug_mc6_repro;" not in text:
    marker = '#[cfg(all(test, feature = "tla_trace"))]\nmod tla_scenarios;\n'
    if marker in text:
        text = text.replace(marker, marker + module, 1)
    else:
        text += module
    path.write_text(text)
PY

cmd=(timeout 10m cargo test -p litebox_shim_linux bug_mc6_stale_patch_plan_level0_public_syscalls -- --nocapture --test-threads=1)
set +e
{
    printf 'COMMAND:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    "${cmd[@]}"
    status=$?
    echo "EXIT_STATUS: $status"
    exit "$status"
} 2>&1 | tee "$OUTPUT_FILE"
status=${PIPESTATUS[0]}
set -e
exit "$status"
