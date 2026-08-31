#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${WORKTREE:-/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-8/worktree}"
TIMEOUT="${LITEBOX_REPRO_TIMEOUT:-5m}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

src="$tmpdir/clone3_parent_tid_failure.c"
bin="$tmpdir/clone3_parent_tid_failure"
out="$tmpdir/litebox.out"

cat >"$src" <<'C_EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <linux/sched.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_clone3
# ifdef __NR_clone3
#  define SYS_clone3 __NR_clone3
# elif defined(__x86_64__)
#  define SYS_clone3 435
# else
#  error "SYS_clone3 is not known on this architecture"
# endif
#endif

#ifndef CLONE_VM
# define CLONE_VM 0x00000100
#endif
#ifndef CLONE_FS
# define CLONE_FS 0x00000200
#endif
#ifndef CLONE_FILES
# define CLONE_FILES 0x00000400
#endif
#ifndef CLONE_SIGHAND
# define CLONE_SIGHAND 0x00000800
#endif
#ifndef CLONE_THREAD
# define CLONE_THREAD 0x00010000
#endif
#ifndef CLONE_PARENT_SETTID
# define CLONE_PARENT_SETTID 0x00100000
#endif

struct litebox_clone_args {
    uint64_t flags;
    uint64_t pidfd;
    uint64_t child_tid;
    uint64_t parent_tid;
    uint64_t exit_signal;
    uint64_t stack;
    uint64_t stack_size;
    uint64_t tls;
    uint64_t set_tid;
    uint64_t set_tid_size;
    uint64_t cgroup;
};

int main(void) {
    enum { sentinel = 0x13572468 };
    volatile int parent_tid = sentinel;
    char invalid_nonzero_stack_address = 0;

    struct litebox_clone_args args = {0};
    args.flags = (uint64_t)CLONE_VM |
                 (uint64_t)CLONE_THREAD |
                 (uint64_t)CLONE_SIGHAND |
                 (uint64_t)CLONE_FILES |
                 (uint64_t)CLONE_PARENT_SETTID;
    args.parent_tid = (uint64_t)(uintptr_t)&parent_tid;
    args.stack = (uint64_t)(uintptr_t)&invalid_nonzero_stack_address;
    args.stack_size = 0;

    int before = parent_tid;
    errno = 0;
    long ret = syscall(SYS_clone3, &args, sizeof(args));
    int err = errno;
    int after = parent_tid;

    printf("clone3_ret=%ld errno=%d (%s) parent_tid_before=%d parent_tid_after=%d\n",
           ret, err, strerror(err), before, after);

    if (ret == -1 && err == EINVAL && before == sentinel && after != sentinel) {
        printf("BUG_REPRODUCED: failed clone3 changed caller-visible parent_tid to %d\n", after);
        return 0;
    }

    if (ret == -1 && err == EINVAL && after == sentinel) {
        printf("NO_BUG: failed clone3 left parent_tid unchanged\n");
        return 2;
    }

    printf("UNEXPECTED: clone3 result did not match invalid-stack failure path\n");
    return 3;
}
C_EOF

echo "[build] gcc -static -O2 -Wall -Wextra -o $bin $src"
gcc -static -O2 -Wall -Wextra -o "$bin" "$src"

echo "[run] timeout $TIMEOUT cargo run -q -p litebox_runner_linux_userland -- --unstable --rewrite-syscalls $bin"
set +e
(
    cd "$WORKTREE"
    timeout "$TIMEOUT" cargo run -q -p litebox_runner_linux_userland -- --unstable --rewrite-syscalls "$bin"
) >"$out" 2>&1
status=$?
set -e

cat "$out"
echo "[litebox_exit] $status"

if [ "$status" -ne 0 ]; then
    echo "[result] FAIL: LiteBox runner exited nonzero"
    exit 1
fi

if grep -q "BUG_REPRODUCED" "$out"; then
    echo "[result] PASS: Level 0 public clone3 syscall reproduced MC-8"
    exit 0
fi

echo "[result] FAIL: bug signature not observed"
exit 1
