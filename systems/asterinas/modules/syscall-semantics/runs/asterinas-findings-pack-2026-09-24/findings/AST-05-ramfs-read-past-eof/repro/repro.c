// SPDX-License-Identifier: MPL-2.0
//
// MC-3 reproduction payload: ramfs/tmpfs read copies past logical EOF.
//
// Counterexample (MC_hunt_scenario_4_positional_offset_bfs.out, state 2-10):
//   MCSysPread64Start(t1,"Ramfs",1) on a file of size 2, request spans EOF.
//   copiedTotal = 2 (bytes made visible in the user buffer) but
//   reportedTotal = 1 (the syscall return value) -> MCReportedCoversVisibleCopy
//   is violated.
//
// Contract under test (Linux / POSIX): read(2), pread(2) and readv(2) may
// return fewer bytes than requested, but they never modify the caller's buffer
// beyond the returned byte count.
//   "If the value of nbyte is greater than the number of bytes remaining in
//    the file, read() shall read the remaining bytes ... and return that
//    number."  -- POSIX read(2)
//
// The payload only uses public syscalls: open, ftruncate, pwrite, pread,
// lseek, read, preadv. Escalation level 0.
//
// Usage: mc3_repro <directory-on-the-filesystem-under-test>

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#define FILL 0x5a
#define BUF_BYTES 8192

static int failures;
static int divergences;

static char buf[BUF_BYTES];
static char aux[BUF_BYTES];

/* Returns the number of bytes in buf[from..to) that are no longer FILL. */
static size_t count_clobbered(const char *b, size_t from, size_t to)
{
	size_t n = 0;
	for (size_t i = from; i < to; i++) {
		if (b[i] != (char)FILL)
			n++;
	}
	return n;
}

static ssize_t first_clobbered(const char *b, size_t from, size_t to)
{
	for (size_t i = from; i < to; i++) {
		if (b[i] != (char)FILL)
			return (ssize_t)i;
	}
	return -1;
}

static void report(const char *name, ssize_t ret, ssize_t want_ret,
		   size_t clobber_from, size_t clobber_to, const char *b)
{
	size_t bad = count_clobbered(b, clobber_from, clobber_to);
	ssize_t at = first_clobbered(b, clobber_from, clobber_to);
	int ret_ok = (ret == want_ret);
	int buf_ok = (bad == 0);

	printf("[%s] ret=%zd (expected %zd) untouched_range=[%zu,%zu) "
	       "clobbered=%zu first_clobbered=%zd -> %s\n",
	       name, ret, want_ret, clobber_from, clobber_to, bad, at,
	       (ret_ok && buf_ok) ? "OK" : "VIOLATION");

	if (!ret_ok)
		failures++;
	if (!buf_ok)
		divergences++;
}

static int open_file_of_size(const char *dir, const char *base, size_t size,
			     const char *pattern, size_t pattern_len)
{
	char path[512];
	snprintf(path, sizeof(path), "%s/%s", dir, base);
	unlink(path);

	int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
	if (fd < 0) {
		printf("FATAL: open(%s): %s\n", path, strerror(errno));
		exit(2);
	}
	if (pattern_len > 0) {
		if (pwrite(fd, pattern, pattern_len, 0) != (ssize_t)pattern_len) {
			printf("FATAL: pwrite(%s): %s\n", path, strerror(errno));
			exit(2);
		}
	}
	if (size != pattern_len) {
		if (ftruncate(fd, (off_t)size) != 0) {
			printf("FATAL: ftruncate(%s): %s\n", path,
			       strerror(errno));
			exit(2);
		}
	}

	struct stat st;
	if (fstat(fd, &st) != 0 || (size_t)st.st_size != size) {
		printf("FATAL: unexpected size for %s\n", path);
		exit(2);
	}
	return fd;
}

int main(int argc, char **argv)
{
	const char *dir = (argc > 1) ? argv[1] : "/tmp";

	printf("MC-3 repro: filesystem under test = %s\n", dir);

	/*
	 * Case 1 - the counterexample itself: 2-byte file, pread at offset 1
	 * with a request that spans EOF.  Linux returns 1 and leaves
	 * buf[1..64) alone.
	 */
	{
		int fd = open_file_of_size(dir, "mc3_a", 2, "AB", 2);
		memset(buf, FILL, sizeof(buf));
		ssize_t ret = pread(fd, buf, 64, 1);
		report("case1 pread(off=1,len=64,size=2)", ret, 1, 1, 64, buf);
		close(fd);
	}

	/*
	 * Case 2 - read starting exactly at EOF.  Linux returns 0 and must not
	 * touch a single byte of the buffer.
	 */
	{
		int fd = open_file_of_size(dir, "mc3_b", 2, "AB", 2);
		memset(buf, FILL, sizeof(buf));
		ssize_t ret = pread(fd, buf, 64, 2);
		report("case2 pread(off=EOF=2,len=64)", ret, 0, 0, 64, buf);
		close(fd);
	}

	/*
	 * Case 3 - the same short read through the shared file offset, which is
	 * the ordinary read(2) path.  Also checks that the OFD offset advances
	 * by the reported length only.
	 */
	{
		int fd = open_file_of_size(dir, "mc3_c", 2, "AB", 2);
		memset(buf, FILL, sizeof(buf));
		if (lseek(fd, 1, SEEK_SET) != 1) {
			printf("FATAL: lseek: %s\n", strerror(errno));
			exit(2);
		}
		ssize_t ret = read(fd, buf, 64);
		report("case3 read(off=1,len=64,size=2)", ret, 1, 1, 64, buf);
		off_t pos = lseek(fd, 0, SEEK_CUR);
		printf("[case3 offset] after read the shared offset is %lld "
		       "(expected 2) -> %s\n",
		       (long long)pos, pos == 2 ? "OK" : "VIOLATION");
		if (pos != 2)
			failures++;
		close(fd);
	}

	/*
	 * Case 4 - readv across EOF.  Entry 0 is short; entry 1 starts at EOF
	 * and must be left completely untouched.
	 */
	{
		int fd = open_file_of_size(dir, "mc3_d", 2, "AB", 2);
		memset(buf, FILL, sizeof(buf));
		memset(aux, FILL, sizeof(aux));
		struct iovec iov[2];
		iov[0].iov_base = buf;
		iov[0].iov_len = 2;
		iov[1].iov_base = aux;
		iov[1].iov_len = 64;
		ssize_t ret = preadv(fd, iov, 2, 1);
		printf("[case4 preadv(off=1, iov=[2,64], size=2)] ret=%zd "
		       "(expected 1)\n",
		       ret);
		if (ret != 1)
			failures++;
		report("case4 entry0 tail", ret, ret, 1, 2, buf);
		report("case4 entry1 (starts at EOF)", ret, ret, 0, 64, aux);
		close(fd);
	}

	/*
	 * Case 5 - magnitude.  A file of 4100 bytes has a page-aligned cache of
	 * 8192 bytes; a 4096-byte read at offset 4096 returns 4 but can scribble
	 * over the rest of the tail page.
	 */
	{
		char *pattern = malloc(4100);
		if (!pattern) {
			printf("FATAL: malloc\n");
			exit(2);
		}
		memset(pattern, 'P', 4100);
		int fd = open_file_of_size(dir, "mc3_e", 4100, pattern, 4100);
		free(pattern);
		memset(buf, FILL, sizeof(buf));
		ssize_t ret = pread(fd, buf, 4096, 4096);
		report("case5 pread(off=4096,len=4096,size=4100)", ret, 4, 4,
		       4096, buf);
		close(fd);
	}

	printf("MC3_SUMMARY wrong_return_values=%d buffers_modified_past_return=%d\n",
	       failures, divergences);
	if (failures == 0 && divergences == 0)
		printf("MC3_RESULT MATCHES_LINUX\n");
	else
		printf("MC3_RESULT DIVERGES_FROM_LINUX\n");
	printf("MC3_SCENARIO_DONE\n");
	fflush(stdout);
	return 0;
}
