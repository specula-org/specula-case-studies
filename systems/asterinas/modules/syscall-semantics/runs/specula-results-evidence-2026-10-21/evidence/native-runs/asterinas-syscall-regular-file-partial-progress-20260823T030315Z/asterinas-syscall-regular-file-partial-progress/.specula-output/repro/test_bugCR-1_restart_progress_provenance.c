// SPDX-License-Identifier: MPL-2.0
//
// CR-1: "Restart consumes an errno without progress provenance".
//
// Claim under test: sys_read/sys_write map *any* EINTR from the backend to
// ERESTARTSYS (read.rs:36-39, write.rs:36-39) without consulting how many bytes
// were copied/committed. SA_RESTART delivery then rewinds the instruction
// pointer with the original arguments (signal/mod.rs:145-158), so a backend that
// returned EINTR *after* committing bytes would have that commit replayed.
//
// The claim has two halves; this program measures both from userspace only:
//
//   H1 (precondition) Can a regular-file read/write ever be interrupted, i.e.
//                     can the backend hand EINTR to the wrapper at all?
//                     Measured by PROBE_* with a handler installed WITHOUT
//                     SA_RESTART: every EINTR the backend produces would then
//                     surface verbatim to userspace.
//
//   H2 (consequence)  If a restart happened after committed progress, the
//                     committed effect is replayed. Measured by APPEND/OFFSET:
//                     with a shared open-file description, bytes on disk and the
//                     shared offset must equal the sum of the returned counts.
//                     A replayed commit makes size/offset exceed that sum.
//
// CTRL_PIPE is the positive control: it proves the very same wrapper arm IS
// live and the restart machinery does fire, using a backend that really blocks.
// Without it a "no EINTR on regular files" result would be vacuous.
//
// Escalation Level 0 (public API only) and Level 1 (timing assistance: a
// signal-storm thread, a concurrent fsync/sync thread, O_DIRECT to force real
// block-device waits). No kernel modification, no state injection.
//
// Usage: test_bugCR-1 <dir> <label>     e.g. test_bugCR-1 /ext2 ext2
//        test_bugCR-1 --ctrl            pipe positive/negative controls

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PAGE_BYTES 4096UL
#define CHUNK (256UL * 1024UL) /* 256 KiB: many pages, forces multi-page work */
#define APPEND_CHUNK (64UL * 1024UL)
#define APPEND_ITERS 128
#define OFFSET_ITERS 128
#define PROBE_ITERS 48

static volatile sig_atomic_t g_handler_hits;
static atomic_int g_storm_stop;
static atomic_int g_storm_sent;
static pthread_t g_target;

static void handler(int signum)
{
	(void)signum;
	g_handler_hits++;
}

/* Installs a SIGUSR1 handler. restart != 0 selects SA_RESTART. */
static void install_handler(int restart)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = handler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = restart ? SA_RESTART : 0;
	if (sigaction(SIGUSR1, &sa, NULL) != 0) {
		perror("sigaction");
		exit(1);
	}
}

static void nap_us(long usec)
{
	struct timespec ts = { .tv_sec = usec / 1000000L,
			       .tv_nsec = (usec % 1000000L) * 1000L };
	nanosleep(&ts, NULL);
}

/* Level 1 timing assistance: hammer the I/O thread with SIGUSR1 from another
 * CPU so a signal is pending for as much of each syscall as possible. */
static void *storm(void *arg)
{
	long gap = (long)(intptr_t)arg;
	sigset_t set;

	sigemptyset(&set);
	sigaddset(&set, SIGUSR1);
	pthread_sigmask(SIG_BLOCK, &set, NULL); /* only the target gets it */

	while (!atomic_load(&g_storm_stop)) {
		pthread_kill(g_target, SIGUSR1);
		atomic_fetch_add(&g_storm_sent, 1);
		if (gap > 0)
			nap_us(gap);
	}
	return NULL;
}

struct sync_arg {
	int fd;
};

/* Level 1 timing assistance: keep writeback busy so buffered writes meet a
 * page that is actually under write-back (the uninterruptible wait in
 * vm/page_cache/cache_page.rs:319). */
static void *syncer(void *arg)
{
	struct sync_arg *sa = arg;
	sigset_t set;

	sigemptyset(&set);
	sigaddset(&set, SIGUSR1);
	pthread_sigmask(SIG_BLOCK, &set, NULL);

	while (!atomic_load(&g_storm_stop)) {
		fsync(sa->fd);
		nap_us(200);
	}
	return NULL;
}

static void *xalloc(size_t n)
{
	void *p = NULL;
	if (posix_memalign(&p, PAGE_BYTES, n) != 0 || p == NULL) {
		fprintf(stderr, "posix_memalign(%zu) failed\n", n);
		exit(1);
	}
	return p;
}

/* ------------------------------------------------------------------ H1 probe */

/* Drives PROBE_ITERS chunked writes then reads under the signal storm and
 * counts how often the kernel handed back EINTR. The handler is installed
 * WITHOUT SA_RESTART, so any EINTR the regular-file backend produces reaches
 * userspace unmodified instead of being turned into a silent restart. */
/* mode: 0 = buffered, 1 = O_DIRECT (real bio wait), 2 = O_SYNC (write-back wait
 * on every write). Each mode targets a different uninterruptible wait in the
 * regular-file path. */
static void probe(const char *dir, const char *label, int mode)
{
	char path[256];
	unsigned char *buf = xalloc(CHUNK);
	long wr_eintr = 0, rd_eintr = 0, wr_short = 0, rd_short = 0;
	long wr_ops = 0, rd_ops = 0, other_err = 0;
	int fd, flags;
	pthread_t st, sy;
	struct sync_arg sarg;

	snprintf(path, sizeof(path), "%s/cr1-probe-%s", dir, label);
	memset(buf, 0xA5, CHUNK);

	flags = O_RDWR | O_CREAT | O_TRUNC;
	if (mode == 1)
		flags |= O_DIRECT;
	else if (mode == 2)
		flags |= O_SYNC;
	fd = open(path, flags, 0600);
	if (fd < 0) {
		printf("CR1_PROBE %s SKIP open=%d errno=%d\n", label, fd, errno);
		free(buf);
		return;
	}

	install_handler(0); /* no SA_RESTART: surface EINTR verbatim */
	g_handler_hits = 0;
	atomic_store(&g_storm_stop, 0);
	atomic_store(&g_storm_sent, 0);
	g_target = pthread_self();
	pthread_create(&st, NULL, storm, (void *)(intptr_t)0);
	sarg.fd = fd;
	pthread_create(&sy, NULL, syncer, &sarg);

	for (int i = 0; i < PROBE_ITERS; i++) {
		ssize_t n = write(fd, buf, CHUNK);
		wr_ops++;
		if (n < 0) {
			if (errno == EINTR)
				wr_eintr++;
			else
				other_err++;
		} else if ((size_t)n != CHUNK) {
			wr_short++;
		}
	}
	if (lseek(fd, 0, SEEK_SET) < 0)
		perror("lseek");
	for (int i = 0; i < PROBE_ITERS; i++) {
		ssize_t n = read(fd, buf, CHUNK);
		rd_ops++;
		if (n < 0) {
			if (errno == EINTR)
				rd_eintr++;
			else
				other_err++;
		} else if (n > 0 && (size_t)n != CHUNK) {
			rd_short++;
		}
	}

	atomic_store(&g_storm_stop, 1);
	pthread_join(st, NULL);
	pthread_join(sy, NULL);
	close(fd);
	unlink(path);
	free(buf);

	printf("CR1_PROBE %s mode=%d wr_ops=%ld wr_eintr=%ld wr_short=%ld "
	       "rd_ops=%ld rd_eintr=%ld rd_short=%ld other_err=%ld "
	       "sigs_sent=%d handler_hits=%d verdict=%s\n",
	       label, mode, wr_ops, wr_eintr, wr_short, rd_ops, rd_eintr,
	       rd_short, other_err, atomic_load(&g_storm_sent),
	       (int)g_handler_hits,
	       (wr_eintr + rd_eintr) ? "INTERRUPTIBLE" : "UNINTERRUPTIBLE");
}

/* ------------------------------------------------------- H2 committed replay */

/* O_APPEND on a shared open-file description. Each append commits at the
 * current EOF, so a restart that replays a committed append makes the file
 * longer than the sum of the counts the kernel reported. */
static void append_replay(const char *dir, const char *label)
{
	char path[256];
	unsigned char *buf = xalloc(APPEND_CHUNK);
	long long returned = 0;
	long eintr = 0, fails = 0;
	int fd, fd2;
	pthread_t st;
	struct stat sb;

	snprintf(path, sizeof(path), "%s/cr1-append-%s", dir, label);
	memset(buf, 0x5A, APPEND_CHUNK);
	unlink(path);

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0600);
	if (fd < 0) {
		printf("CR1_APPEND %s SKIP errno=%d\n", label, errno);
		free(buf);
		return;
	}
	fd2 = dup(fd); /* second descriptor, one shared open-file description */

	install_handler(1); /* SA_RESTART: restarts happen silently */
	g_handler_hits = 0;
	atomic_store(&g_storm_stop, 0);
	atomic_store(&g_storm_sent, 0);
	g_target = pthread_self();
	pthread_create(&st, NULL, storm, (void *)(intptr_t)0);

	for (int i = 0; i < APPEND_ITERS; i++) {
		int use = (i & 1) ? fd2 : fd;
		ssize_t n = write(use, buf, APPEND_CHUNK);
		if (n < 0) {
			if (errno == EINTR)
				eintr++;
			else
				fails++;
		} else {
			returned += n;
		}
	}

	atomic_store(&g_storm_stop, 1);
	pthread_join(st, NULL);
	fsync(fd);
	if (fstat(fd, &sb) != 0) {
		perror("fstat");
		sb.st_size = -1;
	}
	close(fd2);
	close(fd);
	unlink(path);
	free(buf);

	printf("CR1_APPEND %s iters=%d returned=%lld size=%lld eintr=%ld "
	       "fails=%ld sigs_sent=%d handler_hits=%d verdict=%s\n",
	       label, APPEND_ITERS, returned, (long long)sb.st_size, eintr,
	       fails, atomic_load(&g_storm_sent), (int)g_handler_hits,
	       ((long long)sb.st_size == returned) ? "NO_REPLAY" :
						     "REPLAYED_COMMIT");
}

/* Plain writes through a shared open-file description: the shared offset must
 * advance by exactly the sum of the reported counts, once per commit. */
static void offset_replay(const char *dir, const char *label)
{
	char path[256];
	unsigned char *buf = xalloc(APPEND_CHUNK);
	long long returned = 0;
	long eintr = 0, fails = 0;
	int fd, fd2;
	off_t final_off;
	pthread_t st;
	struct stat sb;

	snprintf(path, sizeof(path), "%s/cr1-offset-%s", dir, label);
	memset(buf, 0x3C, APPEND_CHUNK);
	unlink(path);

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		printf("CR1_OFFSET %s SKIP errno=%d\n", label, errno);
		free(buf);
		return;
	}
	fd2 = dup(fd);

	install_handler(1);
	g_handler_hits = 0;
	atomic_store(&g_storm_stop, 0);
	atomic_store(&g_storm_sent, 0);
	g_target = pthread_self();
	pthread_create(&st, NULL, storm, (void *)(intptr_t)0);

	for (int i = 0; i < OFFSET_ITERS; i++) {
		int use = (i & 1) ? fd2 : fd;
		ssize_t n = write(use, buf, APPEND_CHUNK);
		if (n < 0) {
			if (errno == EINTR)
				eintr++;
			else
				fails++;
		} else {
			returned += n;
		}
	}

	atomic_store(&g_storm_stop, 1);
	pthread_join(st, NULL);
	final_off = lseek(fd, 0, SEEK_CUR);
	fsync(fd);
	if (fstat(fd, &sb) != 0) {
		perror("fstat");
		sb.st_size = -1;
	}
	close(fd2);
	close(fd);
	unlink(path);
	free(buf);

	printf("CR1_OFFSET %s iters=%d returned=%lld offset=%lld size=%lld "
	       "eintr=%ld fails=%ld sigs_sent=%d handler_hits=%d verdict=%s\n",
	       label, OFFSET_ITERS, returned, (long long)final_off,
	       (long long)sb.st_size, eintr, fails, atomic_load(&g_storm_sent),
	       (int)g_handler_hits,
	       ((long long)final_off == returned &&
		(long long)sb.st_size == returned) ?
		       "NO_DOUBLE_ADVANCE" :
		       "DOUBLE_ADVANCE");
}

/* ------------------------------------------------------------- positive ctrl */

struct feed {
	int fd;
	long delay_us;
};

static void *feeder(void *arg)
{
	struct feed *f = arg;
	sigset_t set;

	sigemptyset(&set);
	sigaddset(&set, SIGUSR1);
	pthread_sigmask(SIG_BLOCK, &set, NULL);

	nap_us(f->delay_us);
	if (write(f->fd, "x", 1) != 1)
		perror("feeder write");
	return NULL;
}

/* Proves the wrapper arm under test is live: a pipe read really blocks, the
 * storm really lands mid-syscall, and read.rs turns the resulting EINTR into
 * ERESTARTSYS (SA_RESTART => transparent restart) or lets it reach userspace
 * as EINTR (no SA_RESTART). If this control did not fire, a clean regular-file
 * result would prove nothing. */
static void ctrl_pipe(int restart)
{
	int pipefd[2];
	char byte = 0;
	ssize_t n;
	pthread_t st, fe;
	struct feed f;

	if (pipe(pipefd) != 0) {
		printf("CR1_CTRL_PIPE restart=%d SKIP pipe errno=%d\n", restart,
		       errno);
		return;
	}

	install_handler(restart);
	g_handler_hits = 0;
	atomic_store(&g_storm_stop, 0);
	atomic_store(&g_storm_sent, 0);
	g_target = pthread_self();
	pthread_create(&st, NULL, storm, (void *)(intptr_t)2000);

	f.fd = pipefd[1];
	f.delay_us = 400000; /* 400 ms of blocked-and-signalled read */
	pthread_create(&fe, NULL, feeder, &f);

	errno = 0;
	n = read(pipefd[0], &byte, 1);
	int saved = errno;

	atomic_store(&g_storm_stop, 1);
	pthread_join(st, NULL);
	pthread_join(fe, NULL);
	close(pipefd[0]);
	close(pipefd[1]);

	printf("CR1_CTRL_PIPE restart=%d ret=%zd errno=%d handler_hits=%d "
	       "sigs_sent=%d verdict=%s\n",
	       restart, n, n < 0 ? saved : 0, (int)g_handler_hits,
	       atomic_load(&g_storm_sent),
	       (n == 1) ? "RESTARTED" :
			  ((n < 0 && saved == EINTR) ? "EINTR" : "OTHER"));
}

int main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "--ctrl") == 0) {
		ctrl_pipe(1); /* SA_RESTART  => read must be restarted */
		ctrl_pipe(0); /* no SA_RESTART => read must fail EINTR */
		printf("CR1_DONE ctrl\n");
		return 0;
	}

	if (argc < 3) {
		fprintf(stderr, "usage: %s <dir> <label> [direct|sync]\n", argv[0]);
		return 2;
	}

	const char *dir = argv[1];
	const char *label = argv[2];
	int mode = 0;
	if (argc >= 4 && strcmp(argv[3], "direct") == 0)
		mode = 1;
	else if (argc >= 4 && strcmp(argv[3], "sync") == 0)
		mode = 2;

	probe(dir, label, mode);
	append_replay(dir, label);
	offset_replay(dir, label);
	printf("CR1_DONE %s\n", label);
	return 0;
}
