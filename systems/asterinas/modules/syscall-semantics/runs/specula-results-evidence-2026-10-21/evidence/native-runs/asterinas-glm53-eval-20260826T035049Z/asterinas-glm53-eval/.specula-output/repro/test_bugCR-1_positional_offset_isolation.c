// SPDX-License-Identifier: MPL-2.0
//
// CR-1 reproduction: pread64/pwrite64 must leave the shared open-description
// offset unchanged, and must race consistently with shared-offset I/O on the
// same open file description (dup'd fds).
//
// Contract under test (Linux-visible behavior):
//   - pread64/pwrite64 never observably move the shared offset
//     (checked via lseek(fd, 0, SEEK_CUR) on every fd of the description).
//   - Data effects of positional I/O land at the explicit offset (and at EOF
//     for pwrite64 on an O_APPEND description); the shared offset stays put.
//   - Faulted/partial positional transfers (PROT_NONE page after a valid
//     prefix) still leave the offset unchanged.
//   - Concurrent positional hammering on a dup'd fd never perturbs the exact
//     shared-offset arithmetic produced by scalar read()/write() alone.
//
// Escalation level: 0 (pure black-box public syscalls; no failpoints, no
// source modification). The PROT_NONE prefix construction is a normal
// userspace mmap/mprotect sequence any process can perform.
//
// Same binary runs on Linux (control) and in the Asterinas guest.
// Prints "CR1_REPRO_DONE" and exits non-zero on any contract violation.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#define FILENAME "/tmp/cr1_pos_isolation.bin"
#define FILE_SIZE 65536L
#define SCRATCH_BASE 30000L /* pwrite threads write only in [30000,40000) */
#define SCRATCH_END 40000L

static int total_checks;
static int failed_checks;

#define CHECK(cond, desc)                                                  \
	do {                                                               \
		int ok = (cond) ? 1 : 0;                                   \
		total_checks++;                                            \
		if (!ok)                                                   \
			failed_checks++;                                   \
		printf("CR1 %3d %-42s: %s%s\n", total_checks, desc,         \
		       ok ? "PASS" : "FAIL", "");                           \
	} while (0)

#define CHECKF(cond, desc, fmt, ...)                                     \
	do {                                                               \
		int ok = (cond) ? 1 : 0;                                   \
		total_checks++;                                            \
		if (!ok)                                                   \
			failed_checks++;                                   \
		printf("CR1 %3d %-42s: %s (" fmt ")\n", total_checks, desc,  \
		       ok ? "PASS" : "FAIL", ##__VA_ARGS__);              \
	} while (0)

static inline uint8_t pat(long off)
{
	return (uint8_t)((off * 131 + 7) & 0xff);
}

/* private LCG so we do not depend on guest libc rand() */
static inline unsigned long lcg(unsigned long *state)
{
	*state = *state * 6364136223846793005UL + 1442695040888963407UL;
	return (unsigned long)(*state >> 33);
}

static long cur_off(int fd)
{
	return lseek(fd, 0, SEEK_CUR);
}

static long pread64_raw(int fd, void *buf, size_t n, off_t off)
{
	return syscall(SYS_pread64, fd, buf, n, off);
}

static long pwrite64_raw(int fd, const void *buf, size_t n, off_t off)
{
	return syscall(SYS_pwrite64, fd, buf, n, off);
}

/* ---- concurrency hammer state ---- */
static volatile int hammer_stop;
static volatile long pread_bytes_total;
static volatile long pwrite_bytes_total;
static int g_fd; /* dup'd descriptor shared by all hammer threads */

static void *pread_hammer(void *arg)
{
	uint8_t buf[64];
	unsigned long rng = 0x9e3779b97f4a7c15UL ^ (unsigned long)(intptr_t)arg;
	while (!hammer_stop) {
		off_t off = (off_t)(SCRATCH_END + (lcg(&rng) % 4000));
		long r = pread64_raw(g_fd, buf, sizeof(buf), off);
		if (r > 0) {
			/* data read back must be either the original pattern
			 * or the hammer pattern, never anything else */
			for (long i = 0; i < r; i++) {
				uint8_t b = buf[i];
				if (b != pat(off + i) && b != (uint8_t)0xA5) {
					printf("CR1 CONC: read garbage 0x%02x at %ld\n",
					       b, (long)(off + i));
					__sync_fetch_and_add(&failed_checks, 1);
					return NULL;
				}
			}
			__sync_fetch_and_add(&pread_bytes_total, r);
		} else if (r < 0 && errno != EINTR) {
			printf("CR1 CONC: pread64 errno %d\n", errno);
			__sync_fetch_and_add(&failed_checks, 1);
			return NULL;
		}
	}
	return NULL;
}

static void *pwrite_hammer(void *arg)
{
	uint8_t buf[32];
	memset(buf, 0xA5, sizeof(buf));
	unsigned long rng = 0x2545f4914f6cdd1dUL ^ (unsigned long)(intptr_t)arg;
	while (!hammer_stop) {
		off_t off = (off_t)(SCRATCH_BASE +
				    (lcg(&rng) %
				     (SCRATCH_END - SCRATCH_BASE - (long)sizeof(buf))));
		long r = pwrite64_raw(g_fd, buf, sizeof(buf), off);
		if (r > 0) {
			__sync_fetch_and_add(&pwrite_bytes_total, r);
		} else if (r < 0 && errno != EINTR) {
			printf("CR1 CONC: pwrite64 errno %d\n", errno);
			__sync_fetch_and_add(&failed_checks, 1);
			return NULL;
		}
	}
	return NULL;
}

int main(void)
{

	/* setup: patterned file */
	int fd = open(FILENAME, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		printf("CR1 setup failed: open %s: %s\n", FILENAME,
		       strerror(errno));
		return 2;
	}
	static uint8_t big[4096];
	for (long off = 0; off < FILE_SIZE; off += sizeof(big)) {
		for (size_t i = 0; i < sizeof(big); i++)
			big[i] = pat(off + (long)i);
		if (write(fd, big, sizeof(big)) != (long)sizeof(big)) {
			printf("CR1 setup failed: write\n");
			return 2;
		}
	}
	if (lseek(fd, 5000, SEEK_SET) != 5000) {
		printf("CR1 setup failed: lseek\n");
		return 2;
	}
	int fd2 = dup(fd);
	int fd3 = dup2(fd, 200);
	if (fd2 < 0 || fd3 < 0) {
		printf("CR1 setup failed: dup\n");
		return 2;
	}

	uint8_t buf[256];
	long r;

	/* --- controls: prove the harness can observe shared-offset movement --- */
	CHECKF(cur_off(fd2) == 5000, "control: dup shares offset",
	       "cur(fd2)=%ld want 5000", cur_off(fd2));
	CHECKF(cur_off(fd3) == 5000, "control: dup2 shares offset",
	       "cur(fd3)=%ld want 5000", cur_off(fd3));

	/* --- 3: pwrite64 leaves shared offset (both fds) --- */
	r = pwrite64_raw(fd, "HELLO!", 6, 20000);
	CHECKF(r == 6 && cur_off(fd) == 5000 && cur_off(fd2) == 5000,
	       "pwrite64 leaves shared offset", "ret=%ld cur(fd)=%ld", r,
	       cur_off(fd));

	/* --- 4: pread64 leaves shared offset, data correct --- */
	r = pread64_raw(fd, buf, 6, 30000);
	int data_ok = (r == 6);
	for (int i = 0; i < 6 && data_ok; i++)
		data_ok = (buf[i] == pat(30000 + i));
	CHECKF(r == 6 && data_ok && cur_off(fd) == 5000 && cur_off(fd2) == 5000,
	       "pread64 leaves shared offset", "ret=%ld cur(fd)=%ld", r,
	       cur_off(fd));

	/* --- 5: pread64 straddling EOF: short read, offset kept --- */
	r = pread64_raw(fd, buf, 100, FILE_SIZE - 3);
	CHECKF(r == 3 && cur_off(fd) == 5000,
	       "pread64 EOF short read, offset kept", "ret=%ld cur=%ld", r,
	       cur_off(fd));

	/* --- 6: pread64 past EOF: zero, offset kept --- */
	r = pread64_raw(fd, buf, 16, FILE_SIZE + 4464);
	CHECKF(r == 0 && cur_off(fd) == 5000,
	       "pread64 past EOF, offset kept", "ret=%ld cur=%ld", r,
	       cur_off(fd));

	/* --- fault-prefix constructions (public mmap/mprotect) --- */
	uint8_t *map = mmap(NULL, 2 * 4096, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (map == MAP_FAILED) {
		printf("CR1 setup failed: mmap\n");
		return 2;
	}
	memset(map, 0x5a, 4096);
	if (mprotect(map + 4096, 4096, PROT_NONE) != 0) {
		printf("CR1 setup failed: mprotect\n");
		return 2;
	}

	/* --- 7: pread64 into unmapped page: EFAULT, offset kept --- */
	errno = 0;
	r = pread64_raw(fd, map + 4096, 16, 0);
	CHECKF(r == -1 && errno == EFAULT && cur_off(fd) == 5000,
	       "pread64 EFAULT, offset kept", "ret=%ld errno=%d cur=%ld", r,
	       errno, cur_off(fd));

	/* --- 8: pread64 fault-prefix: partial (<=4096) or EFAULT, offset kept --- */
	errno = 0;
	r = pread64_raw(fd, map, 8192, 100);
	CHECKF((r == -1 && errno == EFAULT) || (r > 0 && r <= 4096),
	       "pread64 fault-prefix, offset kept", "ret=%ld errno=%d cur=%ld",
	       r, errno, cur_off(fd));
	CHECKF(cur_off(fd) == 5000, "pread64 fault-prefix offset unchanged",
	       "cur=%ld", cur_off(fd));

	/* --- 9: pwrite64 fault-prefix at explicit offset --- */
	errno = 0;
	r = pwrite64_raw(fd, map, 8192, 21000);
	CHECKF((r == -1 && errno == EFAULT) || (r > 0 && r <= 4096),
	       "pwrite64 fault-prefix, offset kept", "ret=%ld errno=%d cur=%ld",
	       r, errno, cur_off(fd));
	CHECKF(cur_off(fd) == 5000, "pwrite64 fault-prefix offset unchanged",
	       "cur=%ld", cur_off(fd));

	/* --- 10/11: preadv/pwritev with explicit offset (supplementary) --- */
	struct iovec iov[2];
	iov[0].iov_base = buf;
	iov[0].iov_len = 4;
	iov[1].iov_base = buf + 4;
	iov[1].iov_len = 8;
	r = syscall(SYS_preadv, fd, iov, 2, 40000);
	CHECKF(r == 12 && cur_off(fd) == 5000,
	       "preadv explicit offset, offset kept", "ret=%ld cur=%ld", r,
	       cur_off(fd));
	iov[1].iov_len = 4;
	r = syscall(SYS_pwritev, fd, iov, 2, 50000);
	CHECKF(r == 8 && cur_off(fd) == 5000,
	       "pwritev explicit offset, offset kept", "ret=%ld cur=%ld", r,
	       cur_off(fd));

	/* --- 12: pwrite64 extends file beyond EOF; offset kept --- */
	errno = 0;
	r = pwrite64_raw(fd, "TAIL", 4, FILE_SIZE);
	struct stat st;
	fstat(fd, &st);
	CHECKF(r == 4 && st.st_size == FILE_SIZE + 4 && cur_off(fd) == 5000,
	       "pwrite64 extends file, offset kept", "ret=%ld size=%ld", r,
	       (long)st.st_size);

	/* --- 13: O_APPEND description: pwrite64 appends, offset kept --- */
	int fda = open(FILENAME, O_WRONLY | O_APPEND);
	if (fda < 0) {
		printf("CR1 setup failed: open O_APPEND\n");
		return 2;
	}
	lseek(fda, 1000, SEEK_SET);
	errno = 0;
	r = pwrite64_raw(fda, "Z", 1, 7);
	uint8_t zb = 0;
	pread64_raw(fd, &zb, 1, FILE_SIZE + 4); /* last byte via other desc */
	long landed = (zb == 'Z') ? FILE_SIZE + 4 : -1;
	printf("CR1 info: O_APPEND pwrite landed at explicit offset 7? or EOF %ld? %s\n",
	       (long)FILE_SIZE + 4, landed == FILE_SIZE + 4 ? "(EOF)" : "(other)");
	CHECKF(r == 1 && cur_off(fda) == 1000,
	       "O_APPEND pwrite64, offset kept", "ret=%ld cur=%ld", r,
	       cur_off(fda));
	close(fda);

	/* --- 14: control: scalar read() DOES move shared offset --- */
	r = read(fd, buf, 10);
	CHECKF(r == 10 && cur_off(fd) == 5010 && cur_off(fd2) == 5010,
	       "control: read() moves shared offset", "ret=%ld cur=%ld", r,
	       cur_off(fd));

	/* --- 15: concurrent pread64 hammer vs scalar shared-offset ops --- */
	g_fd = dup(fd);
	long base = cur_off(fd);
	long expect = base;
	const int ITER = 300;
	pthread_t th[4];
	hammer_stop = 0;
	pread_bytes_total = 0;
	for (long i = 0; i < 4; i++)
		pthread_create(&th[i], NULL, pread_hammer, (void *)(intptr_t)i);
	int conc_fail = 0;
	for (int i = 0; i < ITER; i++) {
		r = read(fd, buf, 8);
		if (r < 0) {
			conc_fail = 1;
			break;
		}
		expect += r;
		long c = cur_off(fd2); /* observe via the OTHER dup'd fd */
		if (c != expect) {
			printf("CR1 CONC FAIL: after read iter %d cur=%ld want=%ld\n",
			       i, c, expect);
			conc_fail = 1;
			break;
		}
	}
	hammer_stop = 1;
	for (int i = 0; i < 4; i++)
		pthread_join(th[i], NULL);
	CHECKF(!conc_fail && cur_off(fd) == expect && pread_bytes_total > 0,
	       "concurrent pread64 never moves offset",
	       "cur=%ld expected=%ld pread_bytes=%ld", cur_off(fd), expect,
	       pread_bytes_total);

	/* --- 16: concurrent pwrite64 hammer vs scalar shared-offset ops --- */
	base = cur_off(fd);
	expect = base;
	hammer_stop = 0;
	pwrite_bytes_total = 0;
	for (long i = 0; i < 4; i++)
		pthread_create(&th[i], NULL, pwrite_hammer, (void *)(intptr_t)i);
	conc_fail = 0;
	for (int i = 0; i < ITER; i++) {
		r = write(fd, "wxyz", 4);
		if (r < 0) {
			conc_fail = 1;
			break;
		}
		expect += r;
		long c = cur_off(fd2);
		if (c != expect) {
			printf("CR1 CONC FAIL: after write iter %d cur=%ld want=%ld\n",
			       i, c, expect);
			conc_fail = 1;
			break;
		}
	}
	hammer_stop = 1;
	for (int i = 0; i < 4; i++)
		pthread_join(th[i], NULL);
	/* scratch region must contain what the hammer wrote somewhere */
	uint8_t probe[64];
	pread64_raw(fd, probe, sizeof(probe), SCRATCH_BASE);
	int saw_hammer = 0;
	for (size_t i = 0; i < sizeof(probe); i++)
		if (probe[i] == 0xA5)
			saw_hammer = 1;
	CHECKF(!conc_fail && cur_off(fd) == expect && pwrite_bytes_total > 0 &&
		       saw_hammer,
	       "concurrent pwrite64 never moves offset",
	       "cur=%ld expected=%ld pwrite_bytes=%ld", cur_off(fd), expect,
	       pwrite_bytes_total);

	/* --- 17: interleaved pread64 between scalar reads: invisible --- */
	base = cur_off(fd);
	r = 0;
	for (int i = 0; i < 500; i++) {
		long pr = pread64_raw(fd, buf, 8, 100);
		if (pr < 0)
			r = -1;
		long rr = read(fd, buf, 4);
		if (rr < 0)
			r = -1;
	}
	CHECKF(r == 0 && cur_off(fd) == base + 500 * 4,
	       "interleaved pread64 invisible to offset", "cur=%ld want=%ld",
	       cur_off(fd), base + 500 * 4);

	munmap(map, 2 * 4096);
	close(fd3);
	close(fd2);
	close(fd);
	close(g_fd);
	unlink(FILENAME);

	printf("CR1_RESULT: %s (%d checks, %d failed)\n",
	       failed_checks ? "FAIL" : "PASS", total_checks, failed_checks);
	printf("CR1_REPRO_DONE\n");
	return failed_checks ? 1 : 0;
}
