// SPDX-License-Identifier: MPL-2.0
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <gnu/libc-version.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static void report(const char *name, long ret, int error, const siginfo_t *info)
{
    printf("{\"kind\":\"calibration\",\"case\":\"%s\",\"libcRet\":%ld,\"errno\":%d,"
           "\"si_pid\":%d,\"si_uid\":%u,\"si_signo\":%d,\"si_code\":%d,\"si_status\":%d}\n",
           name, ret, error, info->si_pid, info->si_uid, info->si_signo, info->si_code, info->si_status);
}
int main(void)
{
    alarm(20);
    struct sigaction action = { .sa_handler = SIG_DFL };
    sigset_t blocked;
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGCHLD, &action, NULL) == 0);
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGCHLD);
    assert(sigprocmask(SIG_BLOCK, &blocked, NULL) == 0);
    struct utsname identity;
    assert(uname(&identity) == 0);
    printf("{\"kind\":\"identity\",\"kernel\":\"%s %s %s\",\"libc\":\"glibc %s\"}\n",
           identity.sysname, identity.release, identity.machine, gnu_get_libc_version());
    int gate[2];
    assert(pipe(gate) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) { char byte; close(gate[1]); assert(read(gate[0], &byte, 1) == 1); _exit(37); }
    close(gate[0]);
    for (int poison = 0; poison < 2; ++poison) {
        siginfo_t info;
        memset(&info, poison ? 0x5a : 0, sizeof(info));
        errno = 0;
        long ret = syscall(SYS_waitid, P_PID, child, &info, WEXITED | WNOHANG, NULL);
        int error = errno;
        report(poison ? "WR-SQ-poison" : "WR-SQ-zero", ret, error, &info);
        assert(ret == 0 && error == 0);
    }
    assert(write(gate[1], "x", 1) == 1);
    close(gate[1]);
    int status;
    assert(syscall(SYS_wait4, child, &status, 0, NULL) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 37);
    void *fault = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(fault != MAP_FAILED);
    for (int mode = 0; mode < 3; ++mode) {
        child = fork();
        assert(child >= 0);
        if (!child) _exit(37);
        siginfo_t info = {0};
        assert(syscall(SYS_waitid, P_PID, child, &info, WEXITED | WNOWAIT, NULL) == 0);
        assert(info.si_pid == child && info.si_status == 37);
        errno = 0;
        long ret = mode == 0 ? syscall(SYS_wait4, child, fault, 0, NULL) :
            syscall(SYS_waitid, P_PID, child, fault, WEXITED | (mode == 2 ? WNOWAIT : 0), NULL);
        int error = errno;
        report(mode == 0 ? "WR-CF-wait4-fault" : mode == 1 ? "WR-CF-waitid-fault" : "WR-CF-nowait-fault", ret, error, &info);
        assert(ret == -1 && error == EFAULT);
        errno = 0;
        ret = syscall(SYS_wait4, child, &status, WNOHANG, NULL);
        error = errno;
        report(mode == 0 ? "WR-CF-wait4-followup" : mode == 1 ? "WR-CF-waitid-followup" : "WR-CF-nowait-followup", ret, error, &info);
        if (mode == 2) {
            assert(ret == child && error == 0);
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 37);
        } else assert(ret == -1 && error == ECHILD);
    }
    assert(munmap(fault, 4096) == 0);
    puts("WR_CALIBRATION_COMPLETE");
    return 0;
}
