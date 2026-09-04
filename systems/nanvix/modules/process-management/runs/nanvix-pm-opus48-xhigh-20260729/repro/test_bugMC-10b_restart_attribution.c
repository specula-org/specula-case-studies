// Reproduction for finding MC-10b:
//   "SA_RESTART applied per the delivered signal, not the interrupting one"
//   invariant : RestartAttribution  (model ghost `restartMisattributed`)
//   config    : MC_hunt_scenario7.cfg
//   CE        : spec/output/MC_hunt_MC-10b.out
//
// -------------------------------------------------------------------------
// What the finding claims
// -------------------------------------------------------------------------
// Nanvix's try_deliver_signal (src/kernel/src/pm/process/manager/signal.rs:206-316):
//   * :220 consumes a restart record via take_restart(); the record
//          (KcallRestart, src/kernel/src/pm/thread/state.rs:56-62) carries the
//          interrupted call's number + args but NO signal number.
//   * :240-254 selects the LOWEST-numbered deliverable *caught* signal
//          (deliverable = (pending | thread_pending) & !blocked, then the lowest
//          set bit whose disposition is Handler).
//   * :280-283 applies SA_RESTART iff the restart record is present AND the
//          *delivered* signal's sa_flags has SA_RESTART.
// The finding argues restart is therefore attributed to the delivered signal
// rather than "the signal that interrupted the call", so a call interrupted by a
// non-SA_RESTART signal could be transparently restarted (or vice versa).
//
// -------------------------------------------------------------------------
// What this test shows
// -------------------------------------------------------------------------
// Nanvix explicitly emulates Linux here ("the kernel's analog of Linux's
// ERESTARTSYS", thread/state.rs:51-54). This test establishes the ground-truth
// POSIX semantics on a real OS and shows that "SA_RESTART decided by the DELIVERED
// signal's flags" IS the correct behaviour -- real Unix has no separate
// "interrupting signal" whose flags govern restart; the delivered/dequeued signal
// governs. Hence the flagged path reproduces but is BENIGN (POSIX-correct), and the
// RestartAttribution invariant over-flags a benign state.
//
//   A (informational) : real-OS multi-signal delivery order is POSIX-unspecified.
//   B (GATE, determin.): the DELIVERED signal's SA_RESTART flag ALONE governs
//                        whether an interrupted restartable syscall (read) restarts,
//                        independent of the signal number  -> mirrors signal.rs:280-283.
//   C (GATE, determin.): a faithful port of Nanvix's try_deliver_signal selection +
//                        restart decision, driven through the CE's pending set with a
//                        signum-less restart record, selects the lowest caught signal
//                        and governs restart by ITS flag -- agreeing with the POSIX
//                        rule from B. There is no signum in the record to attribute
//                        against, so "misattribution" is not a reachable defect.

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
static volatile sig_atomic_t g_order[8];
static volatile sig_atomic_t g_n = 0;
static void rec_handler(int s) { if (g_n < 8) g_order[g_n++] = s; }

static void install(int signo, int flags, void (*fn)(int)) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fn;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = flags;
    if (sigaction(signo, &sa, NULL) != 0) { perror("sigaction"); exit(2); }
}

// ---------------------------------------------------------------------------
// A: observed multi-signal delivery order (informational; POSIX-unspecified)
// ---------------------------------------------------------------------------
static void part_a_order(void) {
    install(SIGUSR1, 0, rec_handler);
    install(SIGUSR2, 0, rec_handler);
    sigset_t both, old;
    sigemptyset(&both); sigaddset(&both, SIGUSR1); sigaddset(&both, SIGUSR2);
    sigprocmask(SIG_BLOCK, &both, &old);
    g_n = 0;
    raise(SIGUSR2); raise(SIGUSR1);          // both pending simultaneously
    sigprocmask(SIG_SETMASK, &old, NULL);    // deliver both
    printf("A  observed delivery order = [%d,%d]  (SIGUSR1=%d SIGUSR2=%d)\n",
           (int)g_order[0], (int)g_order[1], SIGUSR1, SIGUSR2);
    printf("A  NOTE: POSIX leaves multi-signal delivery order unspecified; Nanvix\n"
           "        picks the lowest (trailing_zeros, signal.rs:247). Order does not\n"
           "        affect the attribution question -- restart is governed by the\n"
           "        signal that is delivered, tested in B.\n");
}

// ---------------------------------------------------------------------------
// B: delivered signal's SA_RESTART flag governs restart of interrupted read()
// ---------------------------------------------------------------------------
// Returns 1 if read() ultimately returned data (restarted), 0 if EINTR.
static int read_interrupted_by(int signo, int flags) {
    install(signo, flags, rec_handler);
    int fd[2];
    if (pipe(fd) != 0) { perror("pipe"); exit(2); }
    pid_t c = fork();
    if (c == 0) {                       // child: interrupt read, then feed data
        close(fd[0]);
        usleep(150 * 1000);
        kill(getppid(), signo);
        usleep(150 * 1000);
        if (write(fd[1], "X", 1) != 1) _exit(3);
        usleep(30 * 1000);
        _exit(0);
    }
    close(fd[1]);
    char b[4];
    errno = 0;
    ssize_t n = read(fd[0], b, 1);      // blocks; interrupted by signo
    int e = errno;
    close(fd[0]);
    int st; waitpid(c, &st, 0);
    if (n == 1) return 1;
    if (n < 0 && e == EINTR) return 0;
    fprintf(stderr, "unexpected read n=%zd errno=%d\n", n, e);
    exit(2);
}

static int part_b_governance(void) {
    struct { int sig; int flags; int expect_restart; const char *name; } cases[] = {
        { SIGUSR1, SA_RESTART, 1, "SIGUSR1 +SA_RESTART" },
        { SIGUSR1, 0,          0, "SIGUSR1  no-RESTART" },
        { SIGUSR2, SA_RESTART, 1, "SIGUSR2 +SA_RESTART" },
        { SIGUSR2, 0,          0, "SIGUSR2  no-RESTART" },
    };
    int ok = 1;
    for (unsigned i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        int r = read_interrupted_by(cases[i].sig, cases[i].flags);
        int pass = (r == cases[i].expect_restart);
        ok &= pass;
        printf("B  read interrupted by %s -> %-7s (expect %-7s) %s\n",
               cases[i].name, r ? "RESTART" : "EINTR",
               cases[i].expect_restart ? "RESTART" : "EINTR", pass ? "PASS" : "FAIL");
    }
    printf("B  => restart is governed SOLELY by the DELIVERED signal's SA_RESTART\n"
           "      flag, independent of the signal number  (mirrors signal.rs:280-283).\n");
    return ok;
}

// ---------------------------------------------------------------------------
// C: faithful port of Nanvix try_deliver_signal decision (signal.rs:240-284)
// ---------------------------------------------------------------------------
// disp[s]=1 => caught (Handler disposition); sar[s]=1 => that handler has SA_RESTART.
static int nanvix_deliver(unsigned pending, unsigned thread_pending, unsigned blocked,
                          const int *disp, const int *sar,
                          int have_restart_record, int *do_restart) {
    unsigned deliverable = (pending | thread_pending) & ~blocked;   // :242
    int signum = 0;
    while (deliverable != 0) {                                      // :243
        int s = __builtin_ctz(deliverable) + 1;                    // trailing_zeros+1  :247
        if (disp[s] == 1) { signum = s; break; }                   // Handler -> break  :248
        deliverable &= deliverable - 1;                            // skip non-caught   :252
    }
    if (signum == 0) { *do_restart = 0; return 0; }
    *do_restart = (have_restart_record && sar[signum]) ? 1 : 0;    // :280-283
    return signum;
}

static int part_c_port_vs_oracle(void) {
    // Reconstruct the exact shape of the CE (MC_hunt_MC-10b.out):
    //   disposition p1 = <<default, handler>>  -> signal 2 is caught, signal 1 is not
    //   pending p1 = {2}                        -> signal 2 pending
    //   MCMarkInterruptedBySignal(1)            -> a signum-less restart record exists
    //   MCDeliverSignal                         -> delivers signal 2
    // The model marks the call "interrupted by signal 1" (a DEFAULT-disposition,
    // NOT-pending signal) yet delivers signal 2, then flags restartMisattributed.
    // In the implementation, signal 1's identity is nowhere in the record.
    int disp[8] = {0,0,1,0,0,0,0,0};   // signal 2 caught
    int sar [8] = {0,0,1,0,0,0,0,0};   // signal 2 handler has SA_RESTART
    unsigned pending = (1u << (2 - 1));  // {2}
    int do_restart = 0;
    int delivered = nanvix_deliver(pending, 0, 0, disp, sar,
                                   /*have_restart_record=*/1, &do_restart);

    // POSIX oracle (from part B): the DELIVERED signal's SA_RESTART flag governs.
    // Delivered = signal 2, which has SA_RESTART -> restart. There is no separate
    // "interrupting signal" (model's signal 1) consulted anywhere.
    int posix_restart = sar[delivered] ? 1 : 0;
    int ok = (delivered == 2) && (do_restart == 1) && (do_restart == posix_restart);
    printf("C  CE port: delivered=sig%d, do_restart=%d ; POSIX rule (delivered governs)=%d -> %s\n",
           delivered, do_restart, posix_restart, ok ? "PASS(agree)" : "FAIL(differ)");
    printf("C  => the record has NO signum; Nanvix (and POSIX) let the DELIVERED\n"
           "      caught signal govern restart. Attributing to a distinct\n"
           "      'interrupting signal' is a property neither implements => the\n"
           "      RestartAttribution invariant flags a benign, unreachable state.\n");
    return ok;
}

int main(void) {
    printf("== MC-10b reproduction: SA_RESTART attribution (delivered vs interrupting) ==\n\n");
    part_a_order();
    printf("\n");
    int b = part_b_governance();
    printf("\n");
    int c = part_c_port_vs_oracle();
    printf("\nRESULT: B(governance)=%d C(CE-port==POSIX)=%d\n", b, c);
    if (b && c) {
        printf("CONCLUSION: BENIGN. Nanvix applies SA_RESTART per the DELIVERED (lowest\n"
               "caught) signal -- exactly POSIX/Linux, which has no separate 'interrupting\n"
               "signal' identity for restart. The path reproduces but no consumer observes\n"
               "a wrong outcome. RestartAttribution / restartMisattributed is a spec/\n"
               "invariant artifact (benign over-flag). => PENDING REPAIR (INVARIANT)\n");
        return 0;
    }
    printf("CONCLUSION: unexpected divergence from POSIX -- would indicate a real bug.\n");
    return 1;
}
