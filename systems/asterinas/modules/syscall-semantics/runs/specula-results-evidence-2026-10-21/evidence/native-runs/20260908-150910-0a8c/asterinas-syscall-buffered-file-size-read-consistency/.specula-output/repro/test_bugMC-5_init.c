// SPDX-License-Identifier: MPL-2.0
// Guest init for the MC-5 repro: mounts the fixture filesystems and runs
// /test_mc5 as unprivileged uid 1000 (mirrors the Specula harness init).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void) {
    mkdir("/dev",0755); mkdir("/proc",0755); mkdir("/tmp",0777);
    mount("devtmpfs","/dev","devtmpfs",0,NULL);
    mount("proc","/proc","proc",0,NULL);
    mkdir("/ramfs",0777); mkdir("/ext2",0777); mkdir("/exfat",0777);
    if(mount("/dev/vda","/ext2","ext2",0,NULL) || mount("/dev/vdb","/exfat","exfat",0,NULL)) {
        perror("mount fixtures"); printf("SPECULA_BOOT_ERROR\n"); fflush(stdout);
        reboot(RB_POWER_OFF); return 1;
    }
    chown("/ramfs",1000,1000); chown("/ext2",1000,1000); chown("/exfat",1000,1000);
    chmod("/ramfs",0777); chmod("/ext2",0777); chmod("/exfat",0777);
    pid_t child=fork();
    if(child==0) {
        if(setgid(1000)||setuid(1000)) _exit(120);
        execl("/test_mc5","/test_mc5",NULL); perror("exec"); _exit(121);
    }
    int status=0; waitpid(child,&status,0);
    printf("SPECULA_EXIT %d\n",status); fflush(stdout);
    sync(); reboot(RB_POWER_OFF); return 0;
}
