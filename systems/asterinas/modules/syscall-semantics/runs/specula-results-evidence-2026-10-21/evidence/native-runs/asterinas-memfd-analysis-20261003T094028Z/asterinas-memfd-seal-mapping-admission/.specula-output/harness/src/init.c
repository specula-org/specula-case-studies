// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void)
{
    mkdir("/proc", 0755);
    if (mount("proc", "/proc", "proc", 0, NULL)) { perror("mount proc"); return 2; }
    pid_t pid = fork();
    if (!pid) { execl("/scenarios", "scenarios", NULL); perror("exec scenarios"); _exit(2); }
    int status;
    if (pid < 0 || waitpid(pid, &status, 0) < 0) { perror("wait"); return 2; }
    printf("SPECULA_TEST_EXIT %d\n", WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 2;
}
