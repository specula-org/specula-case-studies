// SPDX-License-Identifier: MPL-2.0
//
// MC-5: vectored I/O is not atomic on a shared open file description.
//
// Contract under test (Linux, man 2 readv): "the data transfers performed by
// readv() and writev() are atomic".  Linux implements this by holding
// file->f_pos_lock for the whole vectored call -- fdget_pos() takes it when
// FMODE_ATOMIC_POS is set (every regular file) and file_count(file) > 1 (true
// once the descriptor has been dup()ed).  Two observable consequences:
//
//   * one readv() returns exactly ONE contiguous file range;
//   * one writev() deposits exactly ONE contiguous file range.
//
// Asterinas releases the shared-offset lock after every iovec entry
// (do_sys_readv/do_sys_writev loop over FileLike::read/write, and
// InodeHandle::read/write lock kernel/core/src/fs/file/inode_handle.rs:285/308
// for exactly one backend call), so a competing operation on the same open file
// description can be granted the offset between two entries.
//
// Escalation level 0: public syscalls only (open/dup/readv/writev/read/write/
// lseek/ftruncate/pread), no failpoint, no injected state, no kernel change.
//
// Detection is purely by the Linux-visible contract:
//   CASE A  readv  vs competing read   -> A's returned bytes must be contiguous
//   CASE B  readv  vs competing write  -> same (this is the MC counterexample:
//                                         a SharedWrite intervenes mid-vector)
//   CASE C  writev vs competing write  -> A's written bytes must be contiguous
//
// Usage: mc5_vector_atomicity <dir>

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#define ENTRIES 64
#define ENTRY_BYTES 4096
#define VEC_BYTES ((size_t)ENTRIES * ENTRY_BYTES) /* 256 KiB per vector call */
#define COMP_BYTES 64                             /* competitor transfer size */
#define ROUNDS 100

#define READ_FILE_BYTES (4u << 20) /* CASE A: never mutated, 4 MiB */
#define RW_FILE_BYTES (1u << 20)   /* CASE B: pattern restored every round */
#define BACK_BYTES (8u << 20)      /* CASE C read-back scratch */

enum comp_mode { COMP_READ, COMP_WRITE, COMP_NONE };

static int shared_fd;   /* thread A's descriptor */
static int comp_fd;     /* dup() of shared_fd: same open file description */
static int comp_mode;   /* what the competitor does this round */
static int round_active; /* competitor spins while non-zero */
static int all_done;
static unsigned long comp_ops;
static unsigned long comp_bytes;
static unsigned long comp_errors;

static pthread_barrier_t bar_start;
static pthread_barrier_t bar_end;

static unsigned char *vecbuf;   /* ENTRIES * ENTRY_BYTES */
static unsigned char *pattern;  /* RW_FILE_BYTES */
static unsigned char *backbuf;  /* BACK_BYTES */
static struct iovec iov[ENTRIES];

static void die(const char *what)
{
	fprintf(stderr, "MC5_FATAL %s: %s\n", what, strerror(errno));
	fflush(stderr);
	_exit(2);
}

static void pin_to_cpu(int cpu)
{
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	/* Best effort: a uniprocessor guest simply keeps both threads on CPU 0. */
	(void)sched_setaffinity(0, sizeof(set), &set);
}

/* Word i of the pattern is the little-endian value i, so any 4 aligned bytes
 * read out of the file identify the exact file offset they came from. */
static void fill_pattern(unsigned char *dst, size_t bytes)
{
	uint32_t i;

	for (i = 0; i < bytes / 4; i++)
		memcpy(dst + (size_t)i * 4, &i, 4);
}

static int create_pattern_file(const char *path, size_t bytes)
{
	unsigned char *chunk;
	size_t done = 0;
	int fd;

	chunk = malloc(RW_FILE_BYTES);
	if (chunk == NULL)
		die("malloc chunk");

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		die("open pattern file");

	while (done < bytes) {
		size_t n = bytes - done;
		size_t k;

		if (n > RW_FILE_BYTES)
			n = RW_FILE_BYTES;
		for (k = 0; k < n / 4; k++) {
			uint32_t w = (uint32_t)((done + k * 4) / 4);

			memcpy(chunk + k * 4, &w, 4);
		}
		if (write(fd, chunk, n) != (ssize_t)n)
			die("write pattern file");
		done += n;
	}
	free(chunk);
	return fd;
}

static void *competitor_fn(void *unused)
{
	unsigned char buf[COMP_BYTES];

	(void)unused;
	memset(buf, 'C', sizeof(buf));
	pin_to_cpu(1);

	for (;;) {
		pthread_barrier_wait(&bar_start);
		if (__atomic_load_n(&all_done, __ATOMIC_ACQUIRE))
			return NULL;

		while (__atomic_load_n(&round_active, __ATOMIC_ACQUIRE)) {
			ssize_t r;

			if (comp_mode == COMP_READ)
				r = read(comp_fd, buf, sizeof(buf));
			else if (comp_mode == COMP_WRITE)
				r = write(comp_fd, buf, sizeof(buf));
			else
				break;

			if (r > 0) {
				comp_ops++;
				comp_bytes += (unsigned long)r;
			} else if (r < 0) {
				comp_errors++;
			}
			/* r == 0 means EOF for the reader; keep spinning, the
			 * round is short and the file is far larger than what
			 * one round consumes. */
		}

		pthread_barrier_wait(&bar_end);
	}
}

/* Returns the number of non-contiguity gaps inside one readv result, and
 * reports the first one. */
static int check_readv_contiguous(ssize_t n, int *first_entry, long long *first_gap,
				  int *corrupt)
{
	long long prev_end = -1;
	int gaps = 0;
	int k;

	*corrupt = 0;
	for (k = 0; k < ENTRIES; k++) {
		size_t base = (size_t)k * ENTRY_BYTES;
		size_t len;
		uint32_t word;
		long long start;

		if (n <= (ssize_t)base)
			break;
		len = (size_t)n - base;
		if (len > ENTRY_BYTES)
			len = ENTRY_BYTES;
		if (len < 4)
			break;

		memcpy(&word, vecbuf + base, 4);
		start = (long long)word * 4;
		if (start < 0 || start > (long long)READ_FILE_BYTES) {
			(*corrupt)++;
			break;
		}

		if (prev_end >= 0 && start != prev_end) {
			if (gaps == 0) {
				*first_entry = k;
				*first_gap = start - prev_end;
			}
			gaps++;
		}
		prev_end = start + (long long)len;
	}
	return gaps;
}

/* Positive control: exactly what do_sys_readv does internally -- one scalar
 * read() per iovec entry, with the shared offset released in between.  Run on
 * Linux this must tear, which proves the detector below is not blind. */
static ssize_t readv_as_per_entry_loop(void)
{
	ssize_t total = 0;
	int k;

	for (k = 0; k < ENTRIES; k++) {
		ssize_t r = read(shared_fd, vecbuf + (size_t)k * ENTRY_BYTES,
				 ENTRY_BYTES);

		if (r < 0) {
			if (total > 0)
				break;
			die("emulated per-entry read");
		}
		total += r;
		if (r < (ssize_t)ENTRY_BYTES)
			break;
	}
	return total;
}

static void run_readv_case(const char *tag, const char *path, size_t file_bytes,
			   int mode, int restore_pattern, int emulate_loop)
{
	unsigned long total_gaps = 0, rounds_with_gap = 0, usable_rounds = 0;
	int first_entry = -1, corrupt_rounds = 0;
	long long first_gap = 0;
	long long min_ret = -1, max_ret = -1;
	int r;

	shared_fd = create_pattern_file(path, file_bytes);
	comp_fd = dup(shared_fd);
	if (comp_fd < 0)
		die("dup");

	if (restore_pattern)
		fill_pattern(pattern, RW_FILE_BYTES);

	comp_ops = 0;
	comp_bytes = 0;
	comp_errors = 0;
	comp_mode = mode;

	for (r = 0; r < ROUNDS; r++) {
		ssize_t n;
		int fe = -1, corrupt = 0, gaps;
		long long fg = 0;

		if (restore_pattern) {
			/* pwrite is positional: it does not touch the shared
			 * offset that the test is about. */
			if (pwrite(shared_fd, pattern, file_bytes, 0) !=
			    (ssize_t)file_bytes)
				die("restore pattern");
		}
		if (lseek(shared_fd, 0, SEEK_SET) != 0)
			die("lseek");
		memset(vecbuf, 0, VEC_BYTES);

		__atomic_store_n(&round_active, 1, __ATOMIC_RELEASE);
		pthread_barrier_wait(&bar_start);

		n = emulate_loop ? readv_as_per_entry_loop()
				 : readv(shared_fd, iov, ENTRIES);

		__atomic_store_n(&round_active, 0, __ATOMIC_RELEASE);
		pthread_barrier_wait(&bar_end);

		if (n < 0)
			die("readv");
		if (min_ret < 0 || n < min_ret)
			min_ret = n;
		if (n > max_ret)
			max_ret = n;
		if (n <= (ssize_t)ENTRY_BYTES)
			continue; /* only one entry filled: no boundary to check */
		usable_rounds++;

		gaps = check_readv_contiguous(n, &fe, &fg, &corrupt);
		corrupt_rounds += (corrupt != 0);
		if (gaps > 0) {
			total_gaps += (unsigned long)gaps;
			rounds_with_gap++;
			if (first_entry < 0) {
				first_entry = fe;
				first_gap = fg;
			}
		}
	}

	printf("CASE %s %s_vs_%s: rounds=%d checked=%lu ret_min=%lld ret_max=%lld "
	       "noncontiguous_rounds=%lu total_gaps=%lu first_gap_entry=%d "
	       "first_gap_bytes=%lld competitor_ops=%lu competitor_bytes=%lu "
	       "corrupt_rounds=%d linux_expected_noncontiguous_rounds=0 VERDICT=%s\n",
	       tag, emulate_loop ? "per_entry_read_loop" : "readv",
	       mode == COMP_READ ? "read" : "write", ROUNDS, usable_rounds,
	       min_ret, max_ret, rounds_with_gap, total_gaps, first_entry,
	       first_gap, comp_ops, comp_bytes, corrupt_rounds,
	       rounds_with_gap ? "VECTOR_TORN" : "ATOMIC");

	close(comp_fd);
	close(shared_fd);
	unlink(path);
}

/* CASE C: writev must deposit one contiguous run of 'A' bytes. */
static void run_writev_case(const char *tag, const char *path)
{
	unsigned long rounds_with_split = 0, total_embedded = 0, usable_rounds = 0;
	long long first_embedded = 0;
	int first_round = -1;
	int r;

	shared_fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (shared_fd < 0)
		die("open writev file");
	comp_fd = dup(shared_fd);
	if (comp_fd < 0)
		die("dup");

	comp_ops = 0;
	comp_bytes = 0;
	comp_errors = 0;
	comp_mode = COMP_WRITE;
	memset(vecbuf, 'A', VEC_BYTES);

	for (r = 0; r < ROUNDS; r++) {
		struct stat st;
		ssize_t n, got;
		long long first_a = -1, last_a = -1, embedded = 0, i;

		if (ftruncate(shared_fd, 0) != 0)
			die("ftruncate");
		if (lseek(shared_fd, 0, SEEK_SET) != 0)
			die("lseek");

		__atomic_store_n(&round_active, 1, __ATOMIC_RELEASE);
		pthread_barrier_wait(&bar_start);

		n = writev(shared_fd, iov, ENTRIES);

		__atomic_store_n(&round_active, 0, __ATOMIC_RELEASE);
		pthread_barrier_wait(&bar_end);

		if (n < 0)
			die("writev");
		if (n <= (ssize_t)ENTRY_BYTES)
			continue;
		usable_rounds++;

		if (fstat(shared_fd, &st) != 0)
			die("fstat");
		if ((size_t)st.st_size > BACK_BYTES)
			die("file grew past the read-back buffer");
		got = pread(shared_fd, backbuf, (size_t)st.st_size, 0);
		if (got != st.st_size)
			die("pread back");

		for (i = 0; i < got; i++) {
			if (backbuf[i] == 'A') {
				if (first_a < 0)
					first_a = i;
				last_a = i;
			}
		}
		if (first_a < 0)
			continue;
		for (i = first_a; i <= last_a; i++)
			if (backbuf[i] != 'A')
				embedded++;

		if (embedded > 0) {
			rounds_with_split++;
			total_embedded += (unsigned long)embedded;
			if (first_round < 0) {
				first_round = r;
				first_embedded = embedded;
			}
		}
	}

	printf("CASE %s writev_vs_write: rounds=%d checked=%lu split_rounds=%lu "
	       "total_foreign_bytes_inside=%lu first_split_round=%d "
	       "first_split_bytes=%lld competitor_ops=%lu competitor_bytes=%lu "
	       "linux_expected_split_rounds=0 VERDICT=%s\n",
	       tag, ROUNDS, usable_rounds, rounds_with_split, total_embedded,
	       first_round, first_embedded, comp_ops, comp_bytes,
	       rounds_with_split ? "VECTOR_TORN" : "ATOMIC");

	close(comp_fd);
	close(shared_fd);
	unlink(path);
}

/* CASE E: the counterexample's other conjunct -- a LATER iovec entry faults
 * after positive copy progress (MCFileOpsReadAtCopyFaultPositive at CE state
 * 19, reportedTotal=2 vs copiedTotal=3 at CE state 23).  Single threaded: no
 * competitor, no injected kernel state, just a user buffer whose second page
 * is PROT_NONE, which any process may create with mprotect(2).
 *
 * Contract: the value readv() returns must equal the number of bytes actually
 * deposited in the user buffers, and the shared offset must advance by exactly
 * that many bytes. */
static void run_later_iovec_fault_case(const char *tag, const char *path)
{
	unsigned char *region, *entry0;
	struct iovec fiov[2];
	long long deposited0 = 0, deposited1 = 0, off_after;
	uint32_t w;
	ssize_t n;
	int fd, err;
	long long i;

	fd = create_pattern_file(path, RW_FILE_BYTES);

	entry0 = malloc(ENTRY_BYTES);
	if (entry0 == NULL)
		die("malloc entry0");
	memset(entry0, 0xEE, ENTRY_BYTES);

	region = mmap(NULL, 2 * ENTRY_BYTES, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (region == MAP_FAILED)
		die("mmap");
	memset(region, 0xEE, 2 * ENTRY_BYTES);
	if (mprotect(region + ENTRY_BYTES, ENTRY_BYTES, PROT_NONE) != 0)
		die("mprotect");

	fiov[0].iov_base = entry0;
	fiov[0].iov_len = ENTRY_BYTES;
	fiov[1].iov_base = region;
	fiov[1].iov_len = 2 * ENTRY_BYTES; /* second half is unreachable */

	if (lseek(fd, 0, SEEK_SET) != 0)
		die("lseek");

	errno = 0;
	n = readv(fd, fiov, 2);
	err = errno;
	off_after = lseek(fd, 0, SEEK_CUR);

	/* Deposited prefix of each entry = leading bytes that match the file
	 * pattern the entry was supposed to receive. */
	for (i = 0; i + 4 <= ENTRY_BYTES; i += 4) {
		memcpy(&w, entry0 + i, 4);
		if ((long long)w * 4 != i)
			break;
		deposited0 = i + 4;
	}
	for (i = 0; i + 4 <= ENTRY_BYTES; i += 4) {
		memcpy(&w, region + i, 4);
		if ((long long)w * 4 != ENTRY_BYTES + i)
			break;
		deposited1 = i + 4;
	}

	printf("CASE %s later_iovec_fault: ret=%lld errno=%d "
	       "deposited_entry0=%lld deposited_entry1=%lld deposited_total=%lld "
	       "offset_after=%lld linux_expected_ret=%lld VERDICT=%s\n",
	       tag, (long long)n, n < 0 ? err : 0, deposited0, deposited1,
	       deposited0 + deposited1, off_after, deposited0 + deposited1,
	       (n == deposited0 + deposited1 && off_after == (long long)n)
		       ? "RESULT_MATCHES_EFFECT"
		       : "RESULT_UNDERREPORTS_EFFECT");

	munmap(region, 2 * ENTRY_BYTES);
	free(entry0);
	close(fd);
	unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/";
	char pa[256], pb[256], pc[256];
	pthread_t comp;
	int k;

	setvbuf(stdout, NULL, _IOLBF, 0);

	snprintf(pa, sizeof(pa), "%s/mc5_a.bin", dir);
	snprintf(pb, sizeof(pb), "%s/mc5_b.bin", dir);
	snprintf(pc, sizeof(pc), "%s/mc5_c.bin", dir);

	vecbuf = malloc(VEC_BYTES);
	pattern = malloc(RW_FILE_BYTES);
	backbuf = malloc(BACK_BYTES);
	if (vecbuf == NULL || pattern == NULL || backbuf == NULL)
		die("malloc");

	for (k = 0; k < ENTRIES; k++) {
		iov[k].iov_base = vecbuf + (size_t)k * ENTRY_BYTES;
		iov[k].iov_len = ENTRY_BYTES;
	}

	if (pthread_barrier_init(&bar_start, NULL, 2) != 0 ||
	    pthread_barrier_init(&bar_end, NULL, 2) != 0)
		die("barrier_init");
	if (pthread_create(&comp, NULL, competitor_fn, NULL) != 0)
		die("pthread_create");

	pin_to_cpu(0);

	printf("MC5_BEGIN os=%s dir=%s entries=%d entry_bytes=%d rounds=%d\n",
#ifdef __asterinas__
	       "asterinas",
#else
	       "linux",
#endif
	       dir, ENTRIES, ENTRY_BYTES, ROUNDS);

	run_readv_case("A", pa, READ_FILE_BYTES, COMP_READ, 0, 0);
	run_readv_case("B", pb, RW_FILE_BYTES, COMP_WRITE, 1, 0);
	run_writev_case("C", pc);
	/* Positive control for the CASE A detector. */
	run_readv_case("D", pa, READ_FILE_BYTES, COMP_READ, 0, 1);
	run_later_iovec_fault_case("E", pb);

	__atomic_store_n(&all_done, 1, __ATOMIC_RELEASE);
	pthread_barrier_wait(&bar_start);
	pthread_join(comp, NULL);

	printf("MC5_DONE\n");
	return 0;
}
