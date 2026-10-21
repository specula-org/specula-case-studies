// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding CR-1: "OFD identity and compatible ownership
// across independent opens and dup aliases" (Asterinas local flock).
//
// Runs as the guest init (or as a normal process on Linux as a control).
// Exercises the flock(2) identity contract purely through public syscalls
// (open/dup/dup2/close/flock), probing lock state only with LOCK_NB so no
// check depends on waiter wake-up behavior (that is other findings' ground):
//
//   A. independent opens are distinct OFDs (SH+SH compatible, EX conflicts)
//   B. dup aliases share one OFD (conversion via alias, unlock via either)
//   C. closing one descriptor of an aliased OFD keeps the lock; closing the
//      last descriptor releases it without a stale item
//   D. fd-number reuse does not transfer or hijack ownership
//   E. dup2 onto a locked fd releases the replaced OFD's lock in-syscall
//   F. conversion loops never deadlock on the same OFD nor leave stale items
//   G. the same contract holds from multiple threads (shared file table,
//      get_file_fast! slow path) incl. a real blocking acquisition
//
// Every check prints "[ PASS ]" or "[FAIL..]" with the observed values.
// Exit status 0 iff every check passed. As PID 1 the fixture ends with
// reboot(RB_POWER_OFF) so the QEMU run terminates cleanly.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <sys/file.h>

#define LOCK_SH_OP (LOCK_SH | LOCK_NB)
#define LOCK_EX_OP (LOCK_EX | LOCK_NB)

static const char *LOCKFILE = "/tmp/cr1_flock_identity.file";

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

/* Expect flock() to succeed (ret 0). */
static int flock_ok(int fd, int op)
{
	errno = 0;
	int r = flock(fd, op);
	return r == 0;
}

/* Expect flock() to fail with EAGAIN. */
static int flock_eagain(int fd, int op)
{
	errno = 0;
	int r = flock(fd, op);
	return r == -1 && errno == EAGAIN;
}

/* ------------------------------------------------------------------ */
/* A. Independent opens are distinct open file descriptions            */
/* ------------------------------------------------------------------ */

static int fdA, fdB, fdC; /* independent opens */
static int alias;         /* dup alias of fdA */

static void section_A(void)
{
	fdA = open(LOCKFILE, O_RDWR | O_CREAT, 0600);
	fdB = open(LOCKFILE, O_RDWR);
	fdC = open(LOCKFILE, O_RDWR);
	if (fdA < 0 || fdB < 0 || fdC < 0) {
		printf("FATAL: open failed: %s\n", strerror(errno));
		exit(3);
	}
}

static void a1_sh_sh_compatible_across_ofds(void)
{
	CHECK_MSG(flock_ok(fdA, LOCK_SH) && flock_ok(fdB, LOCK_SH_OP) &&
		      flock_ok(fdA, LOCK_UN) && flock_ok(fdB, LOCK_UN),
		  "two independent SH locks must be compatible");
}

static void a2_ex_conflicts_across_ofds(void)
{
	int r1 = flock_ok(fdA, LOCK_EX);
	int r2 = flock_eagain(fdB, LOCK_SH_OP);
	int r3 = flock_eagain(fdB, LOCK_EX_OP);
	int r4 = flock_ok(fdA, LOCK_UN);
	int r5 = flock_ok(fdB, LOCK_EX_OP);
	int r6 = flock_ok(fdB, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4 && r5 && r6,
		  "EX via one open must block SH and EX via an independent open");
}

/* ------------------------------------------------------------------ */
/* B. dup aliases share one OFD                                        */
/* ------------------------------------------------------------------ */

static void b1_alias_conversion_ex_over_sh(void)
{
	alias = dup(fdA);
	int r1 = alias >= 0;
	int r2 = flock_ok(fdA, LOCK_SH);
	/* Same OFD: EX via the alias converts the SH held via fdA (no
	 * self-conflict). If dup produced a distinct OFD this is EAGAIN. */
	int r3 = flock_ok(alias, LOCK_EX_OP);
	int r4 = flock_ok(alias, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4,
		  "dup alias must share the OFD: EX via alias converts SH via fd (alias=%d r3=%d)",
		  alias, r3);
}

static void b2_conversion_back_via_original_fd(void)
{
	int r1 = flock_ok(alias, LOCK_SH);
	int r2 = flock_ok(fdA, LOCK_EX_OP); /* same OFD, downgrade via fdA */
	int r3 = flock_ok(fdA, LOCK_SH_OP); /* and back up via fdA */
	int r4 = flock_ok(alias, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4,
		  "conversion must work through whichever descriptor is used");
}

static void b3_unlock_via_alias_clears_all(void)
{
	int r1 = flock_ok(fdA, LOCK_SH);
	int r2 = flock_ok(alias, LOCK_UN);
	int r3 = flock_ok(fdC, LOCK_EX_OP); /* lock fully gone */
	int r4 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4,
		  "LOCK_UN via one alias must clear the single OFD lock");
}

/* ------------------------------------------------------------------ */
/* C. Descriptor close semantics                                       */
/* ------------------------------------------------------------------ */

static void c1_close_one_alias_keeps_lock(void)
{
	int r1 = flock_ok(fdA, LOCK_EX);
	close(fdA); /* original descriptor of the aliased OFD */
	int r2 = flock_eagain(fdC, LOCK_EX_OP); /* still held via alias */
	int r3 = flock_ok(alias, LOCK_UN);
	int r4 = flock_ok(fdC, LOCK_EX_OP);
	int r5 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4 && r5,
		  "closing one descriptor of an aliased OFD must keep the flock");
}

static void c2_last_close_releases_lock(void)
{
	/* Re-open fdA (it was closed in c1). */
	fdA = open(LOCKFILE, O_RDWR);
	int r1 = fdA >= 0;
	int r2 = flock_ok(fdA, LOCK_EX);
	close(fdA); /* last descriptor of this OFD (no alias) */
	int r3 = flock_ok(fdC, LOCK_EX_OP); /* no stale item may survive */
	int r4 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4,
		  "closing the last descriptor must release the flock synchronously");
}

static void c3_last_close_of_aliased_ofd_releases(void)
{
	fdA = open(LOCKFILE, O_RDWR);
	alias = dup(fdA);
	int r1 = flock_ok(alias, LOCK_EX);
	close(fdA);
	int r2 = flock_eagain(fdC, LOCK_EX_OP); /* survives first close */
	close(alias); /* last descriptor */
	int r3 = flock_ok(fdC, LOCK_EX_OP); /* released at last close */
	int r4 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4,
		  "lock must persist until the last aliased descriptor closes");
}

/* ------------------------------------------------------------------ */
/* D. fd-number reuse does not transfer ownership                      */
/* ------------------------------------------------------------------ */

static void d1_reused_fd_number_is_a_new_owner(void)
{
	/* Close every test fd so the descriptor space below is compact. */
	close(fdA);
	close(fdB);
	close(fdC);
	close(alias);
	fdA = fdB = fdC = alias = -1;

	fdA = open(LOCKFILE, O_RDWR); /* lowest free, e.g. 3 */
	int r1 = fdA >= 0;
	alias = dup(fdA); /* next free */
	int r2 = alias >= 0 && alias != fdA;
	int r3 = flock_ok(fdA, LOCK_EX);
	close(fdA); /* number free again, OFD alive via alias */

	int newfd = open(LOCKFILE, O_RDWR);
	int r4 = newfd >= 0;
	/* SlotVec reuse: the same number must come back. */
	int r5 = newfd == fdA;
	/* The reused number is a different OFD: it must still conflict with
	 * the EX lock held (via the alias) on the old OFD. An implementation
	 * keying locks by fd number would treat newfd as the owner and
	 * succeed here. */
	int r6 = flock_eagain(newfd, LOCK_SH_OP);
	int r7 = flock_ok(alias, LOCK_UN);
	int r8 = flock_ok(newfd, LOCK_SH_OP); /* now a free file */
	int r9 = flock_ok(newfd, LOCK_UN);
	close(newfd);
	CHECK_MSG(r1 && r2 && r3 && r4 && r5 && r6 && r7 && r8 && r9,
		  "reused fd number (%d==%d) must be a new owner: SH r6=%d (want EAGAIN)",
		  newfd, fdA, r6);
}

static void d2_freed_ofd_allocation_leaves_no_stale_item(void)
{
	/* Repeatedly destroy and recreate OFDs so the kernel heap reuses
	 * InodeHandle allocations; after every close the file must be
	 * immediately lockable again (no lingering item, no ABA misfire). */
	int ok = 1;
	for (int i = 0; i < 64 && ok; i++) {
		int x = open(LOCKFILE, O_RDWR);
		int a = dup(x);
		if (x < 0 || a < 0 || !flock_ok(x, LOCK_EX)) {
			ok = 0;
			break;
		}
		close(x); /* keep alias first */
		int y = open(LOCKFILE, O_RDWR);
		if (!flock_eagain(y, LOCK_EX_OP)) { /* old lock alive via a */
			close(y);
			close(a);
			ok = 0;
			break;
		}
		close(y);
		close(a); /* last descriptor of the locked OFD */
		int z = open(LOCKFILE, O_RDWR);
		if (z < 0 || !flock_ok(z, LOCK_EX_OP)) { /* no stale lock */
			if (z >= 0)
				close(z);
			ok = 0;
			break;
		}
		flock(z, LOCK_UN);
		close(z);
	}
	CHECK_MSG(ok, "freed OFD allocations must leave no stale/ABA flock item");
}

/* ------------------------------------------------------------------ */
/* E. dup2 onto a locked fd releases the replaced OFD's lock           */
/* ------------------------------------------------------------------ */

static void e1_dup2_replaces_locked_ofd(void)
{
	fdA = open(LOCKFILE, O_RDWR);
	fdB = open(LOCKFILE, O_RDWR);
	fdC = open(LOCKFILE, O_RDWR);
	int r1 = fdA >= 0 && fdB >= 0 && fdC >= 0;
	int r2 = flock_ok(fdA, LOCK_EX);
	int ret = dup2(fdB, fdA);
	int r3 = ret == fdA;
	/* fdA's old OFD had the last reference replaced away: its EX lock
	 * must be gone within the dup2 syscall. */
	int r4 = flock_ok(fdC, LOCK_EX_OP);
	int r5 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4 && r5,
		  "dup2 must drop the replaced OFD's flock in-syscall (ret=%d r4=%d)",
		  ret, r4);
}

static void e2_dup2_alias_shares_ofd(void)
{
	int r1 = flock_ok(fdB, LOCK_EX);
	int r2 = flock_ok(fdA, LOCK_SH_OP); /* conversion via the dup2 alias */
	int r3 = flock_ok(fdA, LOCK_UN);
	int r4 = flock_ok(fdC, LOCK_EX_OP); /* nothing left */
	int r5 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(r1 && r2 && r3 && r4 && r5,
		  "fdA must alias fdB's OFD after dup2 (conversion via fdA r2=%d)",
		  r2);
}

/* ------------------------------------------------------------------ */
/* F. Conversion loops: no self-deadlock, no stale/duplicate items     */
/* ------------------------------------------------------------------ */

static void f1_solo_conversion_loop(void)
{
	int ok = 1;
	for (int i = 0; i < 200 && ok; i++) {
		int op = (i % 2) ? LOCK_SH_OP : LOCK_EX_OP;
		if (flock(fdA, op) != 0)
			ok = 0;
	}
	int r2 = flock_ok(fdA, LOCK_UN);
	int r3 = flock_ok(fdC, LOCK_EX_OP); /* no stale item after the loop */
	int r4 = flock_ok(fdC, LOCK_UN);
	CHECK_MSG(ok && r2 && r3 && r4,
		  "200 solo SH/EX conversions must all succeed and leave no item");
}

static void f2_conversion_blocked_by_other_ofd(void)
{
	/* fdA aliases fdB's OFD since the dup2 in e1, so open two
	 * genuinely independent descriptors for this section. */
	int fdx = open(LOCKFILE, O_RDWR);
	int fdy = open(LOCKFILE, O_RDWR);
	int r0 = fdx >= 0 && fdy >= 0;
	int r1 = flock_ok(fdx, LOCK_SH);
	int r2 = flock_ok(fdy, LOCK_SH);
	int ok = 1;
	for (int i = 0; i < 100 && ok; i++) {
		/* EX conversion of fdx's OFD must be denied while the
		 * independent fdy OFD holds SH. */
		if (!flock_eagain(fdx, LOCK_EX_OP))
			ok = 0;
		if (flock(fdx, LOCK_SH_OP) != 0)
			ok = 0;
	}
	int r3 = flock_ok(fdy, LOCK_UN);
	int r4 = flock_ok(fdx, LOCK_EX_OP); /* conversion succeeds now */
	int r5 = flock_ok(fdx, LOCK_UN);
	close(fdx);
	close(fdy);
	CHECK_MSG(r0 && r1 && r2 && ok && r3 && r4 && r5,
		  "conversion conflict must come only from other OFDs (loop ok=%d)",
		  ok);
}

/* ------------------------------------------------------------------ */
/* G. Threaded variants: shared file table (get_file_fast! slow path)  */
/* ------------------------------------------------------------------ */

static volatile int seq_a, seq_b, seq_c, seq_d;

static void msleep(int ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

static void spin_until(volatile int *p, int v)
{
	for (int i = 0; i < 2000000; i++) {
		if (*p == v)
			return;
		sched_yield();
	}
}

/* G1: independent OFD locked from another thread. */
static void *g1_thread(void *arg)
{
	(void)arg;
	int fd = open(LOCKFILE, O_RDWR);
	if (fd < 0 || !flock_ok(fd, LOCK_SH))
		return (void *)1;
	seq_a = 1;
	spin_until(&seq_b, 1);
	flock(fd, LOCK_UN);
	close(fd);
	seq_c = 1;
	return NULL;
}

static void g1_thread_independent_ofd(void)
{
	pthread_t t;
	seq_a = seq_b = seq_c = 0;
	void *ret = NULL;
	int r0 = pthread_create(&t, NULL, g1_thread, NULL);
	spin_until(&seq_a, 1);
	int r1 = flock_eagain(fdC, LOCK_EX_OP); /* thread's OFD holds SH */
	seq_b = 1;
	spin_until(&seq_c, 1);
	int r2 = flock_ok(fdC, LOCK_EX_OP); /* free after its unlock */
	int r3 = flock_ok(fdC, LOCK_UN);
	pthread_join(t, &ret);
	CHECK_MSG(r0 == 0 && ret == NULL && r1 && r2 && r3,
		  "independent OFD from another thread must conflict then clear (r1=%d r2=%d)",
		  r1, r2);
}

/* G2: same OFD (dup alias) converted from another thread. */
static void *g2_thread(void *arg)
{
	int a = (int)(intptr_t)arg;
	/* Same OFD as main's fdM: EX via the alias converts main's SH. */
	if (!flock_ok(a, LOCK_EX_OP))
		return (void *)1;
	seq_a = 1;
	spin_until(&seq_b, 1);
	flock(a, LOCK_UN);
	close(a);
	seq_c = 1;
	return NULL;
}

static void g2_alias_conversion_across_threads(void)
{
	pthread_t t;
	int fdM = open(LOCKFILE, O_RDWR);
	int a = dup(fdM);
	seq_a = seq_b = seq_c = 0;
	void *ret = NULL;
	int r0 = fdM >= 0 && a >= 0;
	int r1 = flock_ok(fdM, LOCK_SH);
	int r2 = pthread_create(&t, NULL, g2_thread, (void *)(intptr_t)a);
	spin_until(&seq_a, 1);
	int r3 = flock_eagain(fdC, LOCK_SH_OP); /* EX now held via thread */
	seq_b = 1;
	spin_until(&seq_c, 1);
	int r4 = flock_ok(fdC, LOCK_SH_OP); /* free after alias unlock */
	int r5 = flock_ok(fdC, LOCK_UN);
	pthread_join(t, &ret);
	close(fdM);
	CHECK_MSG(r0 && r1 == 1 && r2 == 0 && ret == NULL && r3 && r4 && r5,
		  "alias conversion across threads must keep one OFD (r3=%d r4=%d)",
		  r3, r4);
}

/* G3: another thread closes an alias; the surviving descriptor keeps the lock. */
static void *g3_thread(void *arg)
{
	int a = (int)(intptr_t)arg;
	close(a);
	seq_a = 1;
	return NULL;
}

static void g3_thread_closes_alias(void)
{
	pthread_t t;
	int fdM = open(LOCKFILE, O_RDWR);
	int a = dup(fdM);
	seq_a = 0;
	void *ret = NULL;
	int r0 = fdM >= 0 && a >= 0;
	int r1 = flock_ok(fdM, LOCK_EX);
	int r2 = pthread_create(&t, NULL, g3_thread, (void *)(intptr_t)a);
	spin_until(&seq_a, 1);
	pthread_join(t, &ret);
	int r3 = flock_eagain(fdC, LOCK_EX_OP); /* OFD alive via fdM */
	int r4 = flock_ok(fdM, LOCK_UN);
	int r5 = flock_ok(fdC, LOCK_EX_OP);
	int r6 = flock_ok(fdC, LOCK_UN);
	close(fdM);
	CHECK_MSG(r0 && r1 && r2 == 0 && ret == NULL && r3 && r4 && r5 && r6,
		  "thread closing one alias must not drop the OFD lock (r3=%d)",
		  r3);
}

/* G4: a real blocking acquisition — the waiter's own OFD must own the
 * resulting lock (unlocked later through the same OFD, and visible as a
 * conflict to a third independent open). Wake comes from an explicit
 * LOCK_UN on a live handle (not from last-close), so this check does not
 * depend on the death-close wake behavior of other findings. */
static void *g4_thread(void *arg)
{
	int fd = open(LOCKFILE, O_RDWR);
	(void)arg;
	if (fd < 0)
		return (void *)1;
	/* Blocks until main unlocks. */
	if (flock(fd, LOCK_EX) != 0)
		return (void *)2;
	seq_a = 1;
	spin_until(&seq_b, 1);
	flock(fd, LOCK_UN);
	close(fd);
	seq_c = 1;
	return NULL;
}

static void g4_blocking_acquisition_owned_by_waiter_ofd(void)
{
	pthread_t t;
	int fdM = open(LOCKFILE, O_RDWR);
	seq_a = seq_b = seq_c = 0;
	void *ret = NULL;
	int r0 = fdM >= 0;
	int r1 = flock_ok(fdM, LOCK_EX);
	int r2 = pthread_create(&t, NULL, g4_thread, NULL);
	msleep(200); /* give the thread time to block */
	int r3 = seq_a == 0; /* still blocked while we hold EX */
	int r4 = flock_eagain(fdC, LOCK_SH_OP);
	int r5 = flock_ok(fdM, LOCK_UN); /* wake the waiter */
	spin_until(&seq_a, 1);
	int r6 = flock_eagain(fdC, LOCK_SH_OP); /* waiter's EX now held */
	seq_b = 1;
	spin_until(&seq_c, 1);
	int r7 = flock_ok(fdC, LOCK_SH_OP); /* released by waiter */
	int r8 = flock_ok(fdC, LOCK_UN);
	pthread_join(t, &ret);
	close(fdM);
	CHECK_MSG(r0 && r1 && r2 == 0 && ret == NULL && r3 && r4 && r5 && r6 &&
		      r7 && r8,
		  "blocking flock must install a lock owned by the waiter's OFD (r3=%d r6=%d r7=%d)",
		  r3, r6, r7);
}

/* ------------------------------------------------------------------ */

int main(void)
{
	printf("CR-1 flock OFD identity reproduction test\n");
	printf("kernel: %s\n", "guest");

	int fd = open(LOCKFILE, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		printf("FATAL: cannot create %s: %s\n", LOCKFILE,
		       strerror(errno));
		goto out;
	}
	close(fd);

	section_A();
	a1_sh_sh_compatible_across_ofds();
	a2_ex_conflicts_across_ofds();
	b1_alias_conversion_ex_over_sh();
	b2_conversion_back_via_original_fd();
	b3_unlock_via_alias_clears_all();
	c1_close_one_alias_keeps_lock();
	c2_last_close_releases_lock();
	c3_last_close_of_aliased_ofd_releases();
	d1_reused_fd_number_is_a_new_owner();
	d2_freed_ofd_allocation_leaves_no_stale_item();
	e1_dup2_replaces_locked_ofd();
	e2_dup2_alias_shares_ofd();
	f1_solo_conversion_loop();
	f2_conversion_blocked_by_other_ofd();
	g1_thread_independent_ofd();
	g2_alias_conversion_across_threads();
	g3_thread_closes_alias();
	g4_blocking_acquisition_owned_by_waiter_ofd();

out:
	printf("=== CR1 SUMMARY: %d checks, %d failures ===\n", check_total,
	       check_failures);
	if (check_failures == 0)
		printf("CR1-RESULT: PASS (identity contract holds)\n");
	else
		printf("CR1-RESULT: FAIL (%d divergences from Linux contract)\n",
		       check_failures);

	if (getpid() == 1) {
		sync();
		reboot(RB_POWER_OFF);
	}
	return check_failures == 0 ? 0 : 1;
}
