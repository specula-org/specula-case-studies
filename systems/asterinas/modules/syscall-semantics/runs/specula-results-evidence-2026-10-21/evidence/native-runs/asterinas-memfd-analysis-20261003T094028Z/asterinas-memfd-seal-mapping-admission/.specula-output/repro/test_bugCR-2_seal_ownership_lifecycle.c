// SPDX-License: MPL-2.0
//
// Reproduction test for finding CR-2:
//   "Mapping ownership may not survive split, merge, protection and unmap
//    transitions" (scenario 3: ownership survives representation changes and
//    revocation; the eligibility that blocks F_SEAL_WRITE).
//
// Mechanism under test: the memfd VMO's writable-mapping counter
// (kernel/core/src/vm/page_cache/vmo/mod.rs WritableMappingStatus), as
// maintained through the VMAR representation transitions in
// kernel/core/src/vm/vmar/vm_mapping.rs (split / try_merge / protect / unmap)
// and kernel/core/src/vm/vmar/vmar_impls/mod.rs (insert_try_merge,
// alloc_free_region_exact_truncate), plus the page-fault write admission in
// vmar_impls/page_fault.rs.
//
// Oracle (identical on Linux v6.16 and Asterinas per source audit):
//   A mapping piece is "write-eligible" iff it descends from an mmap that was
//   MAP_SHARED through a writable FD of a memfd that carried neither
//   F_SEAL_WRITE nor F_SEAL_FUTURE_WRITE at mmap time.  Eligibility survives
//   splits, merges, and mprotect down/upgrades; it ends only when the piece
//   is fully unmapped.
//   fcntl(F_ADD_SEALS, F_SEAL_WRITE) must return EBUSY iff at least one live
//   write-eligible piece exists, and must succeed once none exists.  A
//   successful seal must leave no writable path into the file.
//
// The test avoids, by construction, the three known admission-side
// Asterinas/Linux divergences documented for this run (TV-1a: new PROT_READ
// shared mmap after F_SEAL_WRITE; TV-1b: mappings created after
// F_SEAL_FUTURE_WRITE still counted on Asterinas; TV-2: rejected MAP_FIXED
// replacement truncation): no mmap happens after a seal in the same
// sequence, and F_SEAL_FUTURE_WRITE is never used.  Any divergence this
// test reports is therefore a transition-lifetime (CR-2) divergence.
//
// Build: gcc -O2 -static -pthread -o <bin> this_file.c
// The same binary runs (1) as a host Linux reference and (2) as /scenarios
// in the Asterinas guest, where the init program mounts /proc, execs it,
// prints SPECULA_TEST_EXIT and powers off.

#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <time.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#define BASE ((char *)0x40000000UL)

/* Monotonic nanoseconds (clock_gettime to keep the guest happy). */
static long long mono_ns(void)
{
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
		return 0;
	return (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
}

static void spin_ns(long long ns)
{
	long long t0 = mono_ns();
	while (mono_ns() - t0 < ns)
		__asm__ volatile("" ::: "memory");
}
#define PAGE 4096UL
#define NPAGE 4
#define WINSZ (PAGE * NPAGE)

static int total_failures;
static int total_checks;
static char platform[128] = "unknown";

/* Set when a probe got an unexpected SUCCESS while eligible mappings were
 * still live: sequences abort immediately after the harm probe. */
static int sequence_aborted;

#define REPORT(ok, fmt, ...)                                              \
	do {                                                              \
		total_checks++;                                           \
		if (ok) {                                                 \
			printf("[%s] ok   " fmt "\n", platform,              \
			       ##__VA_ARGS__);                               \
		} else {                                                  \
			total_failures++;                                    \
			printf("[%s] FAIL " fmt                              \
			       "  <== CR-2 DIVERGENCE\n",                   \
			       platform, ##__VA_ARGS__);                     \
			fflush(stdout);                                       \
		}                                                         \
	} while (0)

static void die(const char *what)
{
	printf("[%s] FATAL %s: errno=%d (%s)\n", platform, what, errno,
	       strerror(errno));
	fflush(stdout);
	exit(3);
}

/* ---------------- helpers ---------------- */

static void clear_window(void)
{
	for (int i = 0; i < NPAGE; i++)
		munmap(BASE + i * PAGE, PAGE);
}

static int new_memfd(int *fd_rw, int *fd_ro)
{
	*fd_rw = memfd_create("cr2", MFD_ALLOW_SEALING);
	if (*fd_rw < 0)
		die("memfd_create");
	if (ftruncate(*fd_rw, WINSZ) < 0)
		die("ftruncate");
	char path[64];
	snprintf(path, sizeof(path), "/proc/self/fd/%d", *fd_rw);
	*fd_ro = open(path, O_RDONLY);
	if (*fd_ro < 0)
		die("open O_RDONLY via /proc/self/fd");
	clear_window();
	return 0;
}

static void *xmap(long lo, long npage, int prot, int fd)
{
	return mmap(BASE + lo * PAGE, npage * PAGE, prot,
		    MAP_SHARED | MAP_FIXED, fd, lo * PAGE);
}

static int is_write_sealed(int fd)
{
	int seals = fcntl(fd, F_GET_SEALS);
	return seals >= 0 && (seals & F_SEAL_WRITE);
}

/*
 * Seal probe.  expected_busy == 1 -> F_ADD_SEALS(F_SEAL_WRITE) must fail with
 * EBUSY and leave the memfd unsealed; expected_busy == 0 -> it must succeed.
 * An unexpected SUCCESS while eligible windows may remain live means the
 * counter undercounted: probe the real harm (upgrade + write through the
 * remaining mappings + read the sealed file back).
 */
static void seal_probe(int fd, int expected_busy, const char *fmt, ...)
{
	char label[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(label, sizeof(label), fmt, ap);
	va_end(ap);

	errno = 0;
	int r = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE);
	int e = errno;

	if (expected_busy) {
		int ok = (r == -1 && e == EBUSY);
		REPORT(ok, "%s: expect EBUSY, got r=%d errno=%d (%s)", label,
		       r, e, e ? strerror(e) : "0");
		if (!ok && r >= 0) {
			sequence_aborted = 1;
			printf("[%s]      HARM PROBE: seal succeeded while "
			       "eligible mappings may live; trying to write "
			       "through them\n",
			       platform);
			fflush(stdout);
			for (int p = 0; p < NPAGE; p++) {
				errno = 0;
				if (mprotect(BASE + p * PAGE, PAGE,
					     PROT_READ | PROT_WRITE) == 0) {
					BASE[p * PAGE + 128] = (char)(0xA0 + p);
				}
			}
			char buf[WINSZ];
			memset(buf, 0, sizeof(buf));
			pread(fd, buf, WINSZ, 0);
			int harm = 0;
			for (int p = 0; p < NPAGE; p++)
				if (buf[p * PAGE + 128] == (char)(0xA0 + p))
					harm = 1;
			printf("[%s]      HARM PROBE result: %s\n", platform,
			       harm ?
			       "CONTENT MARKER LANDED -- writes into a "
			       "WRITE-sealed memfd (live harm)" :
			       "no marker landed");
			fflush(stdout);
			clear_window();
		}
	} else {
		REPORT(r >= 0 && e == 0,
		       "%s: expect seal success, got r=%d errno=%d (%s)",
		       label, r, e, e ? strerror(e) : "0");
		if (r < 0)
			sequence_aborted = 1; // false EBUSY: leak; bail out
	}
}

/* occupancy oracle: bitmask of window pages covered by eligible mappings */
static unsigned long occ_pages;

/* ---------------- deterministic sequences (Level 0) ---------------- */

static void seq_partial_unmap_split(int fd)
{
	printf("[%s] --- SEQ1 partial-unmap split ---\n", platform);
	REPORT(xmap(0, NPAGE, PROT_READ | PROT_WRITE, fd) == BASE,
	       "S1 mmap RW [0,4)");
	occ_pages = 0xF;
	for (int p = 0; p < NPAGE; p++)
		BASE[p * PAGE] = (char)p; // populate PTEs
	seal_probe(fd, 1, "S1.p1 EBUSY whole RW mapping");
	munmap(BASE + 1 * PAGE, 2 * PAGE);
	occ_pages &= ~(3UL << 1);
	seal_probe(fd, 1, "S1.p2 EBUSY split survivors [0,1)+[3,4)");
	munmap(BASE, PAGE);
	occ_pages &= ~1UL;
	seal_probe(fd, 1, "S1.p3 EBUSY last survivor [3,4)");
	munmap(BASE + 3 * PAGE, PAGE);
	occ_pages &= ~(1UL << 3);
	seal_probe(fd, 0, "S1.p4 seal succeeds after last piece unmapped");
}

static void seq_protect_split_and_reunify(int fd)
{
	printf("[%s] --- SEQ2 protect-split, re-split, merge-back ---\n",
	       platform);
	REPORT(xmap(0, NPAGE, PROT_READ | PROT_WRITE, fd) == BASE,
	       "S2 mmap RW [0,4)");
	occ_pages = 0xF;
	for (int p = 0; p < NPAGE; p++)
		BASE[p * PAGE] = (char)p;
	seal_probe(fd, 1, "S2.p1 EBUSY whole RW mapping");
	REPORT(mprotect(BASE + 1 * PAGE, 2 * PAGE, PROT_READ) == 0,
	       "S2 mprotect [1,3) down to R");
	seal_probe(fd, 1, "S2.p2 EBUSY 3-way split [0,1)W [1,3)R [3,4)W");
	REPORT(mprotect(BASE + 1 * PAGE, PAGE, PROT_READ | PROT_WRITE) == 0,
	       "S2 mprotect [1,2) back to RW (re-split middle)");
	seal_probe(fd, 1, "S2.p3 EBUSY 4 pieces after re-split");
	REPORT(mprotect(BASE + 1 * PAGE, 2 * PAGE, PROT_READ | PROT_WRITE) ==
		       0,
	       "S2 mprotect [1,3) RW (unify + merge)");
	seal_probe(fd, 1, "S2.p4 EBUSY merged mapping (upgrades keep count)");
	for (int p = 0; p < NPAGE; p++) {
		munmap(BASE + p * PAGE, PAGE);
		occ_pages &= ~(1UL << p);
		seal_probe(fd, p != NPAGE - 1, "S2.p%d after unmapping page %d",
			   p + 5, p);
	}
}

static void seq_two_mmapped_pieces_merge(int fd)
{
	printf("[%s] --- SEQ3 two mmaps merged by protect ---\n", platform);
	REPORT(xmap(0, 2, PROT_READ | PROT_WRITE, fd) == BASE,
	       "S3 mmap RW [0,2)");
	REPORT(xmap(2, 2, PROT_READ | PROT_WRITE, fd) == BASE + 2 * PAGE,
	       "S3 mmap RW [2,4)");
	occ_pages = 0xF;
	BASE[0] = 1;
	BASE[2 * PAGE] = 2;
	seal_probe(fd, 1, "S3.p1 EBUSY two eligible mappings");
	REPORT(mprotect(BASE, WINSZ, PROT_READ) == 0,
	       "S3 mprotect [0,4) down to R (merges pieces)");
	seal_probe(fd, 1, "S3.p2 EBUSY merged R mapping still eligible");
	munmap(BASE, 2 * PAGE);
	occ_pages &= ~3UL;
	seal_probe(fd, 1, "S3.p3 EBUSY survivor [2,4)R");
	munmap(BASE + 2 * PAGE, 2 * PAGE);
	occ_pages &= ~0xCUL;
	seal_probe(fd, 0, "S3.p4 seal succeeds after merge traffic ends");
}

static void seq_mixed_eligibility(int fd_rw, int fd_ro)
{
	printf("[%s] --- SEQ4 mixed eligibility adjacency ---\n", platform);
	REPORT(xmap(0, 2, PROT_READ, fd_rw) == BASE,
	       "S4 mmap R via O_RDWR fd [0,2) (eligible)");
	REPORT(xmap(2, 2, PROT_READ, fd_ro) == BASE + 2 * PAGE,
	       "S4 mmap R via O_RDONLY fd [2,4) (ineligible)");
	occ_pages = 0x3;
	seal_probe(fd_rw, 1, "S4.p1 EBUSY eligible [0,2) dominates");
	errno = 0;
	int up = mprotect(BASE, WINSZ, PROT_READ | PROT_WRITE);
	REPORT(up == -1 && errno == EACCES,
	       "S4 mprotect [0,4) up RW rejected with EACCES (errno=%d)",
	       errno);
	if (up == 0)
		mprotect(BASE, WINSZ, PROT_READ);
	seal_probe(fd_rw, 1, "S4.p2 EBUSY still after failed cross-upgrade");
	munmap(BASE, 2 * PAGE);
	occ_pages &= ~3UL;
	seal_probe(fd_rw, 0,
		   "S4.p3 seal must SUCCEED while ineligible [2,4) stays live");
	errno = 0;
	int up2 = mprotect(BASE + 2 * PAGE, 2 * PAGE, PROT_READ | PROT_WRITE);
	REPORT(up2 == -1 && errno == EACCES,
	       "S4 ineligible piece cannot be upgraded (errno=%d)", errno);
	munmap(BASE + 2 * PAGE, 2 * PAGE);
}

static void seq_downgrade_retains(int fd)
{
	printf("[%s] --- SEQ5 downgrade retains eligibility ---\n", platform);
	REPORT(xmap(0, NPAGE, PROT_READ | PROT_WRITE, fd) == BASE,
	       "S5 mmap RW [0,4)");
	occ_pages = 0xF;
	BASE[0] = 7;
	seal_probe(fd, 1, "S5.p1 EBUSY RW mapping");
	REPORT(mprotect(BASE, WINSZ, PROT_READ) == 0, "S5 downgrade to R");
	seal_probe(fd, 1, "S5.p2 EBUSY downgraded mapping still eligible");
	REPORT(mprotect(BASE, PAGE, PROT_READ | PROT_WRITE) == 0,
	       "S5 upgrade [0,1) back to RW");
	BASE[3] = 8;
	seal_probe(fd, 1, "S5.p3 EBUSY upgraded piece");
	munmap(BASE + 2 * PAGE, 2 * PAGE);
	occ_pages &= ~0xCUL;
	seal_probe(fd, 1, "S5.p4 EBUSY half gone");
	munmap(BASE, 2 * PAGE);
	occ_pages &= ~3UL;
	seal_probe(fd, 0, "S5.p5 seal succeeds");
}

static void seq_mapfixed_replace_middle(int fd)
{
	printf("[%s] --- SEQ6 MAP_FIXED interior replacement ---\n", platform);
	REPORT(xmap(0, NPAGE, PROT_READ | PROT_WRITE, fd) == BASE,
	       "S6 mmap RW [0,4)");
	occ_pages = 0xF;
	BASE[1 * PAGE] = 9;
	seal_probe(fd, 1, "S6.p1 EBUSY whole mapping");
	REPORT(xmap(1, 1, PROT_READ, fd) == BASE + PAGE,
	       "S6 MAP_FIXED R replacement of page 1 (split + re-admission)");
	seal_probe(fd, 1, "S6.p2 EBUSY survivors + replacement");
	munmap(BASE + PAGE, PAGE);
	occ_pages &= ~(1UL << 1);
	seal_probe(fd, 1, "S6.p3 EBUSY survivors [0,1)+[2,4)");
	munmap(BASE, PAGE);
	occ_pages &= ~1UL;
	munmap(BASE + 2 * PAGE, 2 * PAGE);
	occ_pages &= ~0xCUL;
	seal_probe(fd, 0, "S6.p4 seal succeeds");
}

static void seq_protect_across_hole(int fd)
{
	printf("[%s] --- SEQ7 protect across hole ---\n", platform);
	REPORT(xmap(0, 2, PROT_READ | PROT_WRITE, fd) == BASE,
	       "S7 mmap RW [0,2)");
	occ_pages = 0x3;
	BASE[0] = 10;
	seal_probe(fd, 1, "S7.p1 EBUSY");
	errno = 0;
	int r = mprotect(BASE, WINSZ, PROT_READ);
	REPORT(r == -1 && errno == ENOMEM,
	       "S7 mprotect [0,4) hits hole with ENOMEM (errno=%d)", errno);
	mprotect(BASE, 2 * PAGE, PROT_READ | PROT_WRITE); // uniform state
	seal_probe(fd, 1, "S7.p2 EBUSY after failed cross-hole protect");
	REPORT(mprotect(BASE + PAGE, PAGE, PROT_READ) == 0,
	       "S7 partial downgrade of survivor half");
	seal_probe(fd, 1, "S7.p3 EBUSY split halves of survivor");
	munmap(BASE, 2 * PAGE);
	occ_pages &= ~3UL;
	seal_probe(fd, 0, "S7.p4 seal succeeds after all pieces gone");
}

/* ---------------- pseudorandom transition stress (Level 0) ---------- */

static unsigned long long lcg_state;
static unsigned long long lcg_next(void)
{
	lcg_state = lcg_state * 6364136223846793005ULL +
		    1442695040888963407ULL;
	return lcg_state >> 17;
}

static void stress_transitions(int rounds)
{
	printf("[%s] --- STRESS deterministic op mix, %d rounds ---\n",
	       platform, rounds);
	for (int round = 0; round < rounds; round++) {
		int fd, fd_ro;
		new_memfd(&fd, &fd_ro);
		if (xmap(0, NPAGE, PROT_READ | PROT_WRITE, fd) != BASE) {
			REPORT(0, "R%02d initial mmap failed", round);
			return;
		}
		occ_pages = 0xF;
		for (int p = 0; p < NPAGE; p++)
			BASE[p * PAGE] = (char)(round * 16 + p);
		lcg_state = 0x9E3779B97F4A7C15ULL * (unsigned)(round + 1);
		int done = 0;
		for (int op = 0; op < 24 && !done && !sequence_aborted; op++) {
			unsigned long long choice = lcg_next() % 3;
			long a = (long)(lcg_next() % NPAGE);
			long len = 1 + (long)(lcg_next() % (NPAGE - a));
			char label[96];
			if (choice == 0) {
				snprintf(label, sizeof(label),
					 "R%02d.%02d munmap [%ld,%ld)", round,
					 op, a, a + len);
				munmap(BASE + a * PAGE, len * PAGE);
				occ_pages &= ~(((1UL << len) - 1UL) << a);
			} else if (choice == 1) {
				int to_ro = (int)(lcg_next() & 1);
				snprintf(label, sizeof(label),
					 "R%02d.%02d mprotect [%ld,%ld) %s",
					 round, op, a, a + len,
					 to_ro ? "R" : "RW");
				mprotect(BASE + a * PAGE, len * PAGE,
					 to_ro ? PROT_READ :
						 (PROT_READ | PROT_WRITE));
			} else {
				snprintf(label, sizeof(label),
					 "R%02d.%02d MAP_FIXED R [%ld,%ld)",
					 round, op, a, a + len);
				REPORT(xmap(a, len, PROT_READ, fd) ==
					       BASE + a * PAGE,
				       "%s admitted", label);
				occ_pages |= ((1UL << len) - 1UL) << a;
			}
			if (occ_pages) {
				seal_probe(fd, 1, label);
			} else {
				seal_probe(fd, 0, label);
				done = 1;
			}
		}
		if (!done && !sequence_aborted && occ_pages) {
			for (int p = 0; p < NPAGE; p++)
				if ((occ_pages >> p) & 1UL)
					munmap(BASE + p * PAGE, PAGE);
			occ_pages = 0;
			char label[32];
			snprintf(label, sizeof(label), "R%02d cleanup", round);
			seal_probe(fd, 0, label);
		}
		close(fd);
		close(fd_ro);
		if (sequence_aborted)
			return;
	}
}

/* ---------------- Level 1: racing final unmap vs seal ---------------- */

struct race_ctx {
	int fd;
	volatile int go;
	volatile long writer_seq;
	pthread_barrier_t bar;
};

static sigjmp_buf writer_jmp;
static volatile sig_atomic_t writer_armed;

static void writer_sigsegv(int sig)
{
	(void)sig;
	if (writer_armed)
		siglongjmp(writer_jmp, 1);
	_exit(4);
}

static void *race_writer(void *arg)
{
	struct race_ctx *ctx = arg;
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(1, &set);
	sched_setaffinity(0, sizeof(set), &set);
	pthread_barrier_wait(&ctx->bar);
	long seq = 0;
	writer_armed = 1;
	if (sigsetjmp(writer_jmp, 1) == 0) {
		for (;;) {
			seq++;
			ctx->writer_seq = seq;
			((volatile long *)BASE)[0] = seq;
		}
	}
	writer_armed = 0;
	return NULL;
}

static void *race_sealer(void *arg)
{
	struct race_ctx *ctx = arg;
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(1, &set);
	sched_setaffinity(0, sizeof(set), &set);
	pthread_barrier_wait(&ctx->bar);
	while (!ctx->go)
		sched_yield();
	long r;
	do {
		errno = 0;
		r = fcntl(ctx->fd, F_ADD_SEALS, F_SEAL_WRITE);
	} while (r == -1 && errno == EBUSY);
	if (r == -1)
		return (void *)(long)errno;
	return NULL;
}

static void race_round(int round)
{
	struct race_ctx ctx;
	ctx.fd = -1;
	ctx.go = 0;
	ctx.writer_seq = 0;
	/* All three participants (writer, sealer, main) sync on this. */
	if (pthread_barrier_init(&ctx.bar, NULL, 3) != 0)
		die("barrier init");
	int fd = memfd_create("cr2r", MFD_ALLOW_SEALING);
	if (fd < 0)
		die("race memfd_create");
	if (ftruncate(fd, WINSZ) < 0)
		die("race ftruncate");
	clear_window();
	if (mmap(BASE, WINSZ, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED,
		 fd, 0) != BASE)
		die("race mmap");
	((volatile long *)BASE)[0] = 0;
	ctx.fd = fd;

	pthread_t w, s;
	if (pthread_create(&w, NULL, race_writer, &ctx) != 0)
		die("writer spawn");
	if (pthread_create(&s, NULL, race_sealer, &ctx) != 0)
		die("sealer spawn");
	pthread_barrier_wait(&ctx.bar);

	spin_ns(500000); // let the writer get up to speed
	ctx.go = 1; // release the sealer's retry loop
	long long t0 = mono_ns();
	long um = munmap(BASE, WINSZ); // final unmap races the seal attempt
	long long t1 = mono_ns();

	long sealer_err = 0;
	pthread_join(s, (void **)&sealer_err);
	pthread_join(w, NULL);

	long long um_us = (t1 - t0) / 1000;
	long written = ctx.writer_seq;
	long landed = -1;
	{
		char buf[64];
		memset(buf, 0, sizeof(buf));
		ssize_t n = pread(fd, buf, sizeof(buf), 0);
		if (n >= (ssize_t)sizeof(long))
			landed = *(long *)(void *)buf;
	}
	/* If the sealer still saw EBUSY after the unmap returned, the
	 * counter must have reached zero by now: retrying must succeed. */
	int late_sealed = -1;
	if (sealer_err == EBUSY) {
		errno = 0;
		late_sealed = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE) == 0;
	}
	int ok = (um == 0) && ((sealer_err == 0) || (sealer_err == EBUSY));
	REPORT(ok, "L1 round %d: munmap r=%ld (%lld us), writer issued=%ld "
		   "landed=%ld, seal errno=%ld late_retry_ok=%d",
	       round, um, um_us, written, landed, sealer_err, late_sealed);
	if (late_sealed == 0)
		REPORT(0, "L1 round %d: seal still EBUSY after unmap joined "
			  "-- counter never reached zero (leak)",
		       round);
	REPORT(is_write_sealed(fd), "L1 round %d: memfd ends WRITE-sealed",
	       round);
	pthread_barrier_destroy(&ctx.bar);
	close(fd);
}

static void level1_race(int rounds)
{
	printf("[%s] --- L1 racing final unmap vs F_ADD_SEALS vs writer "
	       "(%d rounds) ---\n",
	       platform, rounds);
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = writer_sigsegv;
	sigaction(SIGSEGV, &sa, NULL);
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(0, &set);
	sched_setaffinity(0, sizeof(set), &set);
	for (int r = 0; r < rounds; r++)
		race_round(r);
	clear_window();
}

/* ---------------- main ---------------- */

static int run_as_init(void)
{
	return getpid() == 1;
}

int main(void)
{
	struct utsname u;
	if (uname(&u) == 0)
		snprintf(platform, sizeof(platform), "%s", u.release);
	printf("[%s] CR-2 reproduction: ownership of write eligibility across "
	       "split/merge/protect/unmap\n",
	       platform);
	fflush(stdout);

	if (run_as_init()) {
		mkdir("/proc", 0755);
		if (mount("proc", "/proc", "proc", 0, NULL))
			printf("[%s] note: /proc mount errno=%d\n", platform,
			       errno);
	}

	int fd, fd_ro;

	new_memfd(&fd, &fd_ro);
	seq_partial_unmap_split(fd);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	new_memfd(&fd, &fd_ro);
	seq_protect_split_and_reunify(fd);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	new_memfd(&fd, &fd_ro);
	seq_two_mmapped_pieces_merge(fd);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	new_memfd(&fd, &fd_ro);
	seq_mixed_eligibility(fd, fd_ro);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	new_memfd(&fd, &fd_ro);
	seq_downgrade_retains(fd);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	new_memfd(&fd, &fd_ro);
	seq_mapfixed_replace_middle(fd);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	new_memfd(&fd, &fd_ro);
	seq_protect_across_hole(fd);
	if (sequence_aborted)
		goto out;
	close(fd);
	close(fd_ro);

	stress_transitions(24);
	if (sequence_aborted)
		goto out;

	level1_race(48);

out:
	printf("[%s] CR2_TOTAL_CHECKS=%d CR2_FAILURES=%d\n", platform,
	       total_checks, total_failures);
	printf("CR2_RESULT: %s\n",
	       total_failures ? "FAILURES DETECTED" :
				"all expectations met on both protocol directions");
	fflush(stdout);

	if (run_as_init()) {
		printf("SPECULA_TEST_EXIT %d\n", total_failures ? 1 : 0);
		fflush(stdout);
		sync();
		reboot(RB_POWER_OFF);
	}
	return total_failures ? 1 : 0;
}
