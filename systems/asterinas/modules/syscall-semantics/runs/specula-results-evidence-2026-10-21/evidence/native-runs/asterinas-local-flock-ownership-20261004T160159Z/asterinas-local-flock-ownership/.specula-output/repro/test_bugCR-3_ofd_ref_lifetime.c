// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding CR-3: "Last descriptor removal is not final
// OFD release" (Scenario 4; Asterinas local flock campaign).
//
// Runs as the guest init on the Asterinas kernel (reviewed harness build at
// pinned 0c6053709), and — as the control — as a normal process on real Linux
// (tmpfs). It exercises ONLY public syscall interfaces (open/dup/fork/close/
// flock) and checks the open-file-description (OFD) reference-lifetime
// contract that the finding hypothesizes about:
//
//   A1  closing one descriptor of a dup alias pair preserves the flock held
//       by the shared OFD (flock(2): the lock "is released ... when all such
//       file descriptors have been closed")
//   A2  the lock can still be released through the surviving alias (LOCK_UN)
//   A3  closing the LAST descriptor of an aliased OFD releases the flock
//       synchronously within close()
//   C   closing the only descriptor of an OFD releases the flock
//       synchronously within close() (the ClosedFile -> InodeHandle::drop ->
//       unlock_flock chain must complete inside the close syscall)
//   E0  control: with no in-flight reference, flock on an already-closed fd
//       returns EBADF (anchors that EBADF applies only to the
//       never-captured case)
//   B   a blocking flock() that is already waiting while another thread
//       closes ITS OWN fd must complete with 0 once the blocker releases —
//       not return EBADF (close(2): "the blocking I/O system call holds a
//       reference to the underlying open file description ... the blocking
//       system call in the first thread may successfully complete after the
//       close() in the second thread") — and the transiently acquired lock
//       on the now-fd-less file must be cleaned once the in-flight reference
//       drains (no stale "expired ownership" left behind)
//   D   same as B, but the blocker is released by close() itself (final
//       release through the destructor path must still wake and let the
//       deferred syscall finish)
//   G   a forked child's inherited descriptor keeps the locked OFD alive
//       across the parent's close(); when the child exits and the last
//       external reference drains, the flock must be gone
//
// pthreads (CLONE_FILES) force the shared file-table path, so the blocked
// syscalls operate through the get_file_fast! Arc-clone slow path — the
// "in-flight syscall reference" named by the finding.
//
// Every check prints "[ PASS ]" or "[FAIL!!]" with observed values; exit
// status 0 iff all passed. As PID 1 the fixture ends with reboot(RB_POWER_OFF).

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define LOCK_SH_OP (LOCK_SH | LOCK_NB)
#define LOCK_EX_OP (LOCK_EX | LOCK_NB)

static const char *LOCKFILE = "/tmp/cr3_flock_lifetime.file";

static int check_failures;
static int check_total;

#define CHECK_MSG(cond, ...)                                                  \
	do {                                                                  \
		check_total++;                                               \
		if (cond) {                                                  \
			printf("[ PASS ] %s\n", __func__);                    \
		} else {                                                     \
			check_failures++;                                    \
			printf("[FAIL!!] %s: ", __func__);                   \
			printf(__VA_ARGS__);                                 \
			printf("\n");                                        \
		}                                                            \
		fflush(stdout);                                              \
	} while (0)

/* flock() returning the raw status; errno snapshot kept for reporting. */
static int flock_rc(int fd, int op, int *err_out)
{
	errno = 0;
	int r = flock(fd, op);

	if (err_out)
		*err_out = errno;
	return r;
}

/* Expect flock() to succeed (ret 0). */
static int flock_ok(int fd, int op)
{
	int e;

	return flock_rc(fd, op, &e) == 0;
}

static int open_rw(void)
{
	int fd = open(LOCKFILE, O_RDWR | O_CREAT, 0600);

	if (fd < 0) {
		printf("FATAL: open(%s) failed errno=%d\n", LOCKFILE, errno);
		fflush(stdout);
		exit(3);
	}
	return fd;
}

/* ------------------------------------------------------------------ */
/* Worker thread: blocking LOCK_EX on fd while a concurrent close may  */
/* remove that same fd from the file table.                            */
/* ------------------------------------------------------------------ */

struct waiter_arg {
	int fd;
	int ret;
	int err;
	atomic_int state; /* 0=init, 1=calling flock, 2=returned */
};

static void *flock_waiter(void *p)
{
	struct waiter_arg *a = p;

	atomic_store(&a->state, 1);
	errno = 0;
	a->ret = flock(a->fd, LOCK_EX);
	a->err = errno;
	atomic_store(&a->state, 2);
	return NULL;
}

/* Wait (bounded) until the waiter's flock() has returned. */
static int waiter_done(struct waiter_arg *a, int poll_ms)
{
	for (int i = 0; i < poll_ms / 10; i++) {
		if (atomic_load(&a->state) == 2)
			return 1;
		usleep(10 * 1000);
	}
	return atomic_load(&a->state) == 2;
}

/* ------------------------------------------------------------------ */
/* A1/A2: dup alias — closing one alias keeps the shared OFD's flock   */
/* ------------------------------------------------------------------ */

static void case_alias_preservation(void)
{
	int fdA = open_rw();
	int fdB = dup(fdA);
	int fdC;
	int rc, e;

	CHECK_MSG(flock_rc(fdA, LOCK_EX, &e) == 0,
		  "setup: flock(fdA, LOCK_EX) failed errno=%d", e);

	/* Close one of the two aliases. */
	close(fdA);

	fdC = open_rw();
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == -1 && e == EAGAIN,
		  "alias's flock did NOT survive close of the other "
		  "descriptor: independent open LOCK_EX|LOCK_NB returned "
		  "rc=%d errno=%d (Linux: held by the surviving alias)",
		  rc, e);

	/* The lock taken via the first alias can be released through the
	 * surviving alias (same OFD). */
	CHECK_MSG(flock_rc(fdB, LOCK_UN, &e) == 0,
		  "LOCK_UN via the surviving alias failed errno=%d", e);

	/* Now the file must be lockable by the independent OFD. */
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == 0,
		  "file still locked after unlock through the surviving alias "
		  "(rc=%d errno=%d)", rc, e);

	flock(fdC, LOCK_UN);
	close(fdC);
	close(fdB);
}

/* ------------------------------------------------------------------ */
/* A3: closing the LAST descriptor of an aliased OFD releases the      */
/* flock synchronously within close()                                  */
/* ------------------------------------------------------------------ */

static void case_alias_last_close_releases(void)
{
	int fdA = open_rw();
	int fdB = dup(fdA);
	int fdC;
	int rc, e;

	flock(fdA, LOCK_EX);
	close(fdA);
	close(fdB); /* last descriptor of the locked OFD */

	fdC = open_rw();
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == 0,
		  "final close of the last (alias) descriptor did not release "
		  "the flock synchronously inside close(): independent open "
		  "LOCK_EX|LOCK_NB returned rc=%d errno=%d (Linux: released)",
		  rc, e);

	flock(fdC, LOCK_UN);
	close(fdC);
}

/* ------------------------------------------------------------------ */
/* C: single-descriptor close releases the flock synchronously         */
/* ------------------------------------------------------------------ */

static void case_single_close_releases(void)
{
	int fdA = open_rw();
	int fdC;
	int rc, e;

	flock(fdA, LOCK_EX);
	close(fdA); /* the only descriptor; final cleanup must be inside */

	fdC = open_rw();
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == 0,
		  "close of the only descriptor did not release the flock "
		  "synchronously inside close() (rc=%d errno=%d)", rc, e);

	flock(fdC, LOCK_UN);
	close(fdC);
}

/* ------------------------------------------------------------------ */
/* E0: control — no in-flight reference, plain EBADF                   */
/* ------------------------------------------------------------------ */

static void case_closed_fd_ebadf(void)
{
	int fdA = open_rw();
	int rc, e;

	close(fdA);
	rc = flock_rc(fdA, LOCK_SH_OP, &e);
	CHECK_MSG(rc == -1 && e == EBADF,
		  "flock on a closed fd without an in-flight reference "
		  "returned rc=%d errno=%d (expected EBADF)", rc, e);
}

/* ------------------------------------------------------------------ */
/* B/D: a blocked flock() refers its own fd while that fd is closed   */
/* by another thread; the blocker is released either by LOCK_UN (B) or */
/* close() (D). release_by_close selects the release mechanism.        */
/* ------------------------------------------------------------------ */

static void case_inflight_close(int release_by_close)
{
	int fdA = open_rw(); /* blocker OFD */
	int fdD;              /* the waiter's own OFD */
	struct waiter_arg arg;
	pthread_t t;
	int rc, e;

	if (flock(fdA, LOCK_EX) != 0) {
		printf("FATAL: setup flock(fdA) errno=%d\n", errno);
		fflush(stdout);
		exit(3);
	}

	fdD = open_rw();
	arg.fd = fdD;
	arg.ret = -99;
	arg.err = 0;
	atomic_store(&arg.state, 0);

	if (pthread_create(&t, NULL, flock_waiter, &arg) != 0) {
		printf("FATAL: pthread_create failed errno=%d\n", errno);
		fflush(stdout);
		exit(3);
	}

	/* Wait until the thread is about to call flock(), then give it time
	 * to capture the file reference and park. It cannot obtain the
	 * lock yet: fdA still holds LOCK_EX. */
	while (atomic_load(&arg.state) != 1)
		sched_yield();
	usleep(300 * 1000);

	/* Remove the waiter's own fd while its blocking flock() runs. */
	rc = close(fdD);
	CHECK_MSG(rc == 0, "close of the in-use fd failed rc=%d errno=%d",
		  rc, errno);

	/* The freed fd number may be reused by an unrelated new open; that
	 * new OFD is independent and must still see the blocker's lock
	 * (the in-flight request must not be confused with fd reuse). */
	{
		int fdD2 = open_rw();
		int reused = (fdD2 == fdD);

		printf("  [info] fd number %d reused after close: %s\n", fdD,
		       reused ? "yes" : "no");
		fflush(stdout);
		rc = flock_rc(fdD2, LOCK_EX_OP, &e);
		CHECK_MSG(rc == -1 && e == EAGAIN,
			  "independent re-opened OFD did not conflict with the "
			  "blocker (rc=%d errno=%d)", rc, e);
		close(fdD2);
	}

	/* Release the blocker, either by explicit unlock or by close(). */
	if (release_by_close) {
		close(fdA);
		fdA = -1;
	} else {
		flock(fdA, LOCK_UN);
	}

	/* The blocked syscall must now complete. Linux contract: it holds a
	 * reference to the open file description, so it completes with 0
	 * even though its fd was removed — EBADF would be a deviation. */
	int done = waiter_done(&arg, 2000);

	CHECK_MSG(done,
		  "blocking flock on the closed fd never completed (release "
		  "via %s) within 2s", release_by_close ? "close" : "LOCK_UN");
	if (done) {
		pthread_join(t, NULL);
		CHECK_MSG(arg.ret == 0,
			  "blocking flock after its own FD removal returned "
			  "ret=%d errno=%d (Linux close(2): completes with 0)",
			  arg.ret, arg.err);
	} else {
		pthread_detach(t);
	}

	/* The waiter transiently acquired the lock on a file that no longer
	 * has an fd. Once its syscall reference drained, the final
	 * destructor must have removed that ownership: nobody may be left
	 * holding the file. */
	{
		int fdE = open_rw();

		CHECK_MSG(flock_ok(fdE, LOCK_EX_OP),
			  "expired flock ownership leaked after the in-flight "
			  "reference drained: independent open cannot acquire");
		flock(fdE, LOCK_UN);
		close(fdE);
	}

	if (fdA >= 0)
		close(fdA);
}

/* ------------------------------------------------------------------ */
/* G: forked child's inherited descriptor keeps the OFD (and its      */
/* flock) alive across the parent's close; child exit drains the last  */
/* external reference and the flock must be gone                       */
/* ------------------------------------------------------------------ */

static void case_fork_reference(void)
{
	int fdA = open_rw();
	int fdC;
	int rc, e;
	pid_t pid;

	flock(fdA, LOCK_EX);

	pid = fork();
	if (pid < 0) {
		printf("FATAL: fork failed errno=%d\n", errno);
		fflush(stdout);
		exit(3);
	}
	if (pid == 0) {
		/* The child's file-table copy holds a strong reference to
		 * the same locked OFD. Stay alive long enough for the
		 * parent to drop its own descriptor first. */
		usleep(500 * 1000);
		_exit(0);
	}

	close(fdA); /* parent's last fd for the locked OFD */

	fdC = open_rw();
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == -1 && e == EAGAIN,
		  "flock not preserved by the forked child's inherited "
		  "descriptor after the parent closed its own (rc=%d errno=%d)",
		  rc, e);

	waitpid(pid, NULL, 0);

	/* Child exit drops its file-table entries: the last external
	 * reference drains and the flock must be removed. Exit cleanup
	 * ordering is not contractually tied to waitpid return, so poll
	 * bounded (2s) — a permanently held lock fails, slightly delayed
	 * cleanup is acceptable. */
	int released = 0;

	for (int i = 0; i < 100 && !released; i++) {
		if (flock_ok(fdC, LOCK_EX_OP))
			released = 1;
		else
			usleep(20 * 1000);
	}
	if (released) {
		/* The polling loop acquired the lock on fdC; drop it before
		 * probing that the file is truly free. */
		flock(fdC, LOCK_UN);
	}
	CHECK_MSG(released,
		  "flock survived the child's exit: expired ownership was not "
		  "removed after the last external reference drained");

	if (released) {
		int fdE = open_rw();

		CHECK_MSG(flock_ok(fdE, LOCK_EX_OP),
			  "stale lock still present after the drain");
		flock(fdE, LOCK_UN);
		close(fdE);
	}
	flock(fdC, LOCK_UN);
	close(fdC);
}

/* ------------------------------------------------------------------ */
/* C2: close_range() removal path — the fd is dropped via             */
/* close_files -> ClosedFile -> drop after the table lock; the flock  */
/* must be released synchronously within the close_range syscall      */
/* ------------------------------------------------------------------ */

static void case_close_range_releases(void)
{
#ifdef SYS_close_range
	int fdA = open_rw();
	int fdC;
	int rc, e;

	flock(fdA, LOCK_EX);
	rc = syscall(SYS_close_range, fdA, fdA, 0);
	CHECK_MSG(rc == 0, "close_range failed rc=%d errno=%d", rc, errno);

	fdC = open_rw();
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == 0,
		  "close_range removal did not release the flock "
		  "synchronously inside the syscall (rc=%d errno=%d)", rc, e);
	flock(fdC, LOCK_UN);
	close(fdC);
#else
	printf("[ SKIP ] close_range not available in headers\n");
#endif
}

/* ------------------------------------------------------------------ */
/* C3: dup2() replacement — the replaced fd's locked OFD loses its    */
/* last descriptor in-syscall (dup_exact -> close_file -> ClosedFile); */
/* its flock must be released while the duplicating OFD stays distinct */
/* ------------------------------------------------------------------ */

static void case_dup2_replacement_releases(void)
{
	int fdA = open_rw();
	int fdB = open_rw();
	int fdC;
	int rc, e;

	flock(fdB, LOCK_EX);
	rc = dup2(fdA, fdB); /* fdB now aliases fdA; the locked OFD is gone */
	CHECK_MSG(rc == fdB, "dup2 failed rc=%d errno=%d", rc, errno);

	fdC = open_rw();
	rc = flock_rc(fdC, LOCK_EX_OP, &e);
	CHECK_MSG(rc == 0,
		  "dup2 replacement of the last descriptor did not release the "
		  "replaced OFD's flock synchronously (rc=%d errno=%d)", rc, e);
	flock(fdC, LOCK_UN);

	/* The new fdB (alias of fdA) is a distinct, functional OFD. */
	CHECK_MSG(flock_ok(fdB, LOCK_EX_OP),
		  "the replacing alias could not lock after replacement");
	flock(fdB, LOCK_UN);
	flock(fdC, LOCK_UN);
	close(fdC);
	close(fdB);
	close(fdA);
}

int main(void)
{
	printf("CR-3 OFD reference-lifetime fixture start (pid=%d)\n",
	       (int)getpid());
	fflush(stdout);

	case_alias_preservation();
	case_alias_last_close_releases();
	case_single_close_releases();
	case_closed_fd_ebadf();

	/* The two threaded deferred-release cases, repeated for race
	 * coverage. */
	for (int i = 0; i < 3; i++) {
		printf("--- iteration %d (LOCK_UN release) ---\n", i);
		fflush(stdout);
		case_inflight_close(0);
	}
	for (int i = 0; i < 3; i++) {
		printf("--- iteration %d (close release) ---\n", i);
		fflush(stdout);
		case_inflight_close(1);
	}

	case_fork_reference();
	case_close_range_releases();
	case_dup2_replacement_releases();

	unlink(LOCKFILE);

	printf("CR3 SUMMARY: %d/%d checks passed\n",
	       check_total - check_failures, check_total);
	if (check_failures == 0)
		printf("CR3-RESULT: PASS\n");
	else
		printf("CR3-RESULT: FAIL (%d divergences from Linux contract)\n",
		       check_failures);
	fflush(stdout);

	if (getpid() == 1)
		reboot(RB_POWER_OFF);

	return check_failures ? 1 : 0;
}
