/* SPDX-License-Identifier: MIT
 * Bounded Linux/Asterinas userspace-ABI probes. Run in a disposable Asterinas VM.
 * No set_tid_address panic trigger or storage fault injection is included.
 * Each case runs in its own process. PASS means the tested Linux contract held;
 * it is not a general compatibility certification. Requires a 64-bit Linux ABI.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef RWF_APPEND
#define RWF_APPEND 0x10
#endif
#ifndef MADV_FREE
#define MADV_FREE 8
#endif

enum { PASS = 0, FAIL = 1, SETUP_ERROR = 2, SKIP = 77 };
static int setup(const char *what) { perror(what); return SETUP_ERROR; }
static double now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) { perror("clock_gettime"); _exit(2); }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
static void hex(const unsigned char *s, size_t n) {
    for (size_t i = 0; i < n; ++i) printf("%02x", (unsigned)s[i]);
}
static int path_bytes(void) {
    char dir[] = "./abi-path-XXXXXX";
    if (!mkdtemp(dir)) return setup("mkdtemp");
    int d = open(dir, O_RDONLY | O_DIRECTORY);
    if (d < 0) { rmdir(dir); return setup("open directory"); }
    const char a[] = {'f', (char)0x80, 0}, b[] = {'f', (char)0x81, 0};
    int x = openat(d, a, O_WRONLY | O_CREAT | O_EXCL, 0600);
    int ex = errno;
    int y = openat(d, b, O_WRONLY | O_CREAT | O_EXCL, 0600);
    int ey = errno;
    printf("distinct byte names: first=%d errno=%d second=%d errno=%d\n",
           x, x < 0 ? ex : 0, y, y < 0 ? ey : 0);
    if (x >= 0) close(x);
    if (y >= 0) close(y);
    unlinkat(d, a, 0); unlinkat(d, b, 0); close(d); rmdir(dir);
    return x >= 0 && y >= 0 ? PASS : FAIL;
}
static int datagram_writev(void) {
    int s[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, s)) return setup("socketpair");
    struct iovec v[] = {{(void *)"ABCD", 4}, {(void *)"EFGH", 4}};
    ssize_t w = writev(s[0], v, 2);
    unsigned char a[16] = {0}, b[16] = {0};
    ssize_t r1 = recv(s[1], a, sizeof(a), 0);
    errno = 0;
    ssize_t r2 = recv(s[1], b, sizeof(b), 0);
    int e2 = errno;
    printf("writev=%zd first datagram=%zd second=%zd errno=%d first-data=", w, r1, r2, e2);
    if (r1 > 0) hex(a, (size_t)r1);
    puts(""); close(s[0]); close(s[1]);
    return w == 8 && r1 == 8 && !memcmp(a, "ABCDEFGH", 8) &&
           r2 == -1 && e2 == EAGAIN ? PASS : FAIL;
}
static int datagram_readv(void) {
    int s[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, s)) return setup("socketpair");
    if (send(s[0], "ABCDEFGH", 8, 0) != 8) return setup("send");
    unsigned char a[4] = {0}, b[4] = {0};
    struct iovec v[] = {{a, sizeof(a)}, {b, sizeof(b)}};
    ssize_t r = readv(s[1], v, 2);
    printf("readv=%zd first=", r); hex(a, 4); printf(" second="); hex(b, 4); puts("");
    close(s[0]); close(s[1]);
    return r == 8 && !memcmp(a, "ABCD", 4) && !memcmp(b, "EFGH", 4) ? PASS : FAIL;
}
static volatile sig_atomic_t alarm_seen;
static void alarm_handler(int sig) { (void)sig; alarm_seen = 1; }
static int pipe_readv_progress(void) {
    int p[2];
    if (pipe(p)) return setup("pipe");
    if (write(p[1], "ABCD", 4) != 4) return setup("write pipe");
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = alarm_handler; sigemptyset(&sa.sa_mask);
    if (sigaction(SIGALRM, &sa, NULL)) return setup("sigaction");
    unsigned char a[4] = {0}, b[4] = {0};
    struct iovec v[] = {{a, 4}, {b, 4}};
    alarm_seen = 0; alarm(1);
    double start = now();
    ssize_t r = readv(p[0], v, 2);
    double elapsed = now() - start;
    alarm(0);
    printf("readv=%zd elapsed=%.6f alarm_seen=%d (write end remained open)\n",
           r, elapsed, (int)alarm_seen);
    close(p[0]); close(p[1]);
    return r == 4 && !memcmp(a, "ABCD", 4) && !alarm_seen ? PASS : FAIL;
}
static int nofile_limit(void) {
    struct rlimit lim;
    if (getrlimit(RLIMIT_NOFILE, &lim)) return setup("getrlimit");
    lim.rlim_cur = 0;
    if (setrlimit(RLIMIT_NOFILE, &lim)) return setup("setrlimit");
    errno = 0;
    long fd = syscall(SYS_openat, AT_FDCWD, "/dev/null", O_RDONLY, 0);
    int e = errno;
    printf("RLIMIT_NOFILE soft=0: openat=%ld errno=%d\n", fd, e);
    if (fd >= 0) close((int)fd);
    return fd == -1 && e == EMFILE ? PASS : FAIL;
}
static int select_large_nfds(void) {
#ifdef SYS_select
    struct rlimit lim;
    if (getrlimit(RLIMIT_NOFILE, &lim)) return setup("getrlimit");
    if (lim.rlim_max < 2048) { puts("SKIP: hard RLIMIT_NOFILE < 2048"); return SKIP; }
    if (lim.rlim_cur < 2048) { lim.rlim_cur = 2048; if (setrlimit(RLIMIT_NOFILE, &lim)) return setup("setrlimit"); }
    struct timeval tv = {0, 0}; errno = 0;
    long r = syscall(SYS_select, 1025, NULL, NULL, NULL, &tv);
    printf("raw select(nfds=1025, empty sets)=%ld errno=%d\n", r, errno);
    return r == 0 ? PASS : FAIL;
#else
    return SKIP;
#endif
}
static int select_short_bitmap(void) {
#ifdef SYS_select
    long page = sysconf(_SC_PAGESIZE);
    unsigned char *m = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return setup("mmap");
    if (mprotect(m + page, (size_t)page, PROT_NONE)) return setup("mprotect");
    unsigned long *bits = (unsigned long *)(m + page - sizeof(unsigned long));
    *bits = 0;
    struct timeval tv = {0, 0}; errno = 0;
    long r = syscall(SYS_select, 1, bits, NULL, NULL, &tv);
    printf("raw select(nfds=1, one-word bitmap at page end)=%ld errno=%d\n", r, errno);
    munmap(m, (size_t)page * 2);
    return r == 0 ? PASS : FAIL;
#else
    return SKIP;
#endif
}
static int select_timeout(void) {
#ifdef SYS_select
    struct timeval tv = {0, 20000};
    long r = syscall(SYS_select, 0, NULL, NULL, NULL, &tv);
    printf("raw select=%ld remaining=%ld.%06ld\n", r, (long)tv.tv_sec, (long)tv.tv_usec);
    return r == 0 && tv.tv_sec == 0 && tv.tv_usec == 0 ? PASS : FAIL;
#else
    return SKIP;
#endif
}
static int ppoll_timeout(void) {
#ifdef SYS_ppoll
    struct timespec ts = {0, 20000000};
    long r = syscall(SYS_ppoll, NULL, 0, &ts, NULL, sizeof(uint64_t));
    printf("raw ppoll=%ld remaining=%ld.%09ld\n", r, (long)ts.tv_sec, ts.tv_nsec);
    return r == 0 && ts.tv_sec == 0 && ts.tv_nsec == 0 ? PASS : FAIL;
#else
    return SKIP;
#endif
}
static int rusage_null(void) {
    errno = 0;
    long r = syscall(SYS_getrusage, RUSAGE_SELF, NULL);
    int e = errno;
    printf("raw getrusage(NULL)=%ld errno=%d\n", r, e);
    return r == -1 && e == EFAULT ? PASS : FAIL;
}
static int rusage_accounting(void) {
    size_t n = 8u * 1024u * 1024u;
    long page = sysconf(_SC_PAGESIZE);
    volatile unsigned char *m = mmap(NULL, n, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return setup("mmap");
    for (size_t i = 0; i < n; i += (size_t)page) m[i] = 1;
    struct rusage u;
    if (getrusage(RUSAGE_SELF, &u)) return setup("getrusage");
    printf("after touching 8 MiB: maxrss=%ld KiB minflt=%ld majflt=%ld nvcsw=%ld\n",
           u.ru_maxrss, u.ru_minflt, u.ru_majflt, u.ru_nvcsw);
    munmap((void *)m, n);
    return u.ru_maxrss > 0 && u.ru_minflt > 0 ? PASS : FAIL;
}
static int sigchld_payload(void) {
    sigset_t set; sigemptyset(&set); sigaddset(&set, SIGCHLD);
    if (sigprocmask(SIG_BLOCK, &set, NULL)) return setup("sigprocmask");
    pid_t child = fork();
    if (child < 0) return setup("fork");
    if (!child) _exit(37);
    struct timespec timeout = {2, 0};
    siginfo_t info; memset(&info, 0, sizeof(info));
    int sig = sigtimedwait(&set, &info, &timeout);
    printf("SIGCHLD=%d code=%d pid=%ld expected_pid=%ld status=%d\n",
           sig, info.si_code, (long)info.si_pid, (long)child, info.si_status);
    int status;
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) break;
    return sig == SIGCHLD && info.si_code == CLD_EXITED &&
           info.si_pid == child && info.si_status == 37 ? PASS : FAIL;
}
static int madvise_dontfork(void) {
    size_t n = (size_t)sysconf(_SC_PAGESIZE);
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return setup("mmap");
    errno = 0; int r = madvise(p, n, MADV_DONTFORK); int e = errno;
    printf("MADV_DONTFORK on private anonymous mapping=%d errno=%d\n", r, e);
    munmap(p, n);
    /* This is an option-acceptance probe, not a complete inheritance test. */
    return r == 0 ? PASS : FAIL;
}
static int madvise_free_shared(void) {
    size_t n = (size_t)sysconf(_SC_PAGESIZE);
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return setup("mmap");
    errno = 0; int r = madvise(p, n, MADV_FREE); int e = errno;
    printf("MADV_FREE on shared anonymous mapping=%d errno=%d\n", r, e);
    munmap(p, n);
    return r == -1 && e == EINVAL ? PASS : FAIL;
}
static int pwritev2_append(void) {
#ifdef SYS_pwritev2
    char name[] = "./abi-append-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) return setup("mkstemp");
    unlink(name);
    if (write(fd, "A", 1) != 1) return setup("write");
    struct iovec v = {(void *)"B", 1};
    /* Linux's raw 64-bit ABI passes a complete offset_low, an ignored offset_high,
     * and then flags. This is intentionally not the libc pwritev2 signature. */
    errno = 0;
    long r = syscall(SYS_pwritev2, fd, &v, 1, 0UL, 0UL, (unsigned long)RWF_APPEND);
    int e = errno;
    char b[3] = {0}; ssize_t n = pread(fd, b, 2, 0);
    printf("raw pwritev2(RWF_APPEND, offset=0)=%ld errno=%d file-size-read=%zd data=%s\n", r, e, n, b);
    close(fd);
    return r == 1 && n == 2 && !memcmp(b, "AB", 2) ? PASS : FAIL;
#else
    return SKIP;
#endif
}
static int make_pty(int *master, int *slave) {
    char name[PATH_MAX];
    *master = posix_openpt(O_RDWR | O_NOCTTY);
    if (*master < 0) return -1;
    if (grantpt(*master) || unlockpt(*master)) { close(*master); return -1; }
    int err = ptsname_r(*master, name, sizeof(name));
    if (err) { errno = err; close(*master); return -1; }
    *slave = open(name, O_RDWR | O_NOCTTY);
    if (*slave < 0) { close(*master); return -1; }
    return 0;
}
static int pty_mode(int slave, int canonical, int min, int time) {
    struct termios t;
    if (tcgetattr(slave, &t)) return -1;
    cfmakeraw(&t);
    if (canonical) t.c_lflag |= ICANON;
    t.c_cc[VMIN] = (cc_t)min; t.c_cc[VTIME] = (cc_t)time;
    return tcsetattr(slave, TCSANOW, &t);
}
static int tty_vtime(void) {
    int m, s;
    if (make_pty(&m, &s)) return setup("make_pty");
    if (pty_mode(s, 0, 0, 1)) return setup("tcsetattr");
    char c; double start = now(); ssize_t n = read(s, &c, 1); double elapsed = now() - start;
    printf("noncanonical VMIN=0 VTIME=1: read=%zd elapsed=%.6f\n", n, elapsed);
    close(s); close(m);
    return n == 0 && elapsed >= 0.05 ? PASS : FAIL;
}
static int tty_canonical_bytes(void) {
    int m, s;
    if (make_pty(&m, &s)) return setup("make_pty");
    if (pty_mode(s, 1, 1, 0)) return setup("tcsetattr");
    const unsigned char msg[] = {0xc3, 0xa9, '\n'};
    if (write(m, msg, sizeof(msg)) != (ssize_t)sizeof(msg)) return setup("pty write");
    unsigned char buf[16] = {0}; ssize_t n = read(s, buf, sizeof(buf));
    printf("canonical UTF-8 bytes: read=%zd data=", n); if (n > 0) hex(buf, (size_t)n); puts("");
    close(s); close(m);
    return n == 3 && !memcmp(buf, msg, 3) ? PASS : FAIL;
}
static int tty_canonical_vmin(void) {
    int m, s;
    if (make_pty(&m, &s)) return setup("make_pty");
    if (pty_mode(s, 1, 5, 0)) return setup("tcsetattr");
    int fl = fcntl(s, F_GETFL);
    if (fl < 0 || fcntl(s, F_SETFL, fl | O_NONBLOCK) < 0) return setup("fcntl");
    if (write(m, "x\n", 2) != 2) return setup("pty write");
    /* Give Linux's deferred PTY line-discipline work a bounded chance to run. */
    char b[16] = {0}; ssize_t n = -1; int e = 0;
    double end = now() + 0.2;
    do {
        errno = 0; n = read(s, b, sizeof(b)); e = errno;
        if (n >= 0 || e != EAGAIN) break;
        struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
    } while (now() < end);
    printf("canonical VMIN=5, complete two-byte line: read=%zd errno=%d\n", n, e);
    close(s); close(m);
    return n == 2 && !memcmp(b, "x\n", 2) ? PASS : FAIL;
}
static int tty_winsize_signal(void) {
    if (setsid() < 0) return setup("setsid");
    int m, s;
    if (make_pty(&m, &s)) return setup("make_pty");
    if (ioctl(s, TIOCSCTTY, 0)) return setup("TIOCSCTTY");
    if (tcsetpgrp(s, getpgrp())) return setup("tcsetpgrp");
    /* Closing our own controlling terminal may send SIGHUP. */
    signal(SIGHUP, SIG_IGN);
    sigset_t set; sigemptyset(&set); sigaddset(&set, SIGWINCH);
    if (sigprocmask(SIG_BLOCK, &set, NULL)) return setup("sigprocmask");
    struct winsize w;
    if (ioctl(s, TIOCGWINSZ, &w)) return setup("TIOCGWINSZ");
    w.ws_row = w.ws_row == 41 ? 42 : 41;
    if (ioctl(s, TIOCSWINSZ, &w)) return setup("TIOCSWINSZ");
    struct timespec ts = {0, 200000000}; siginfo_t info;
    errno = 0; int r = sigtimedwait(&set, &info, &ts); int e = errno;
    printf("resize controlling PTY: received=%d expected=%d errno=%d\n", r, SIGWINCH, e);
    close(s); close(m);
    return r == SIGWINCH ? PASS : FAIL;
}
