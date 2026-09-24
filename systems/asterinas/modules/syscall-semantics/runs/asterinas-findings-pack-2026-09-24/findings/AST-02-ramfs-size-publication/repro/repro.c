// SPDX-License-Identifier: MPL-2.0
//
// MC-4: ramfs publishes the new inode size before the fallible user copy.
//
// `RamInode::write_at` (kernel/core/src/fs/fs_impls/ramfs/fs.rs:721-756) sets
// `inode_meta.size = offset + reader.remain()` and stamps mtime/ctime *before*
// calling `page_cache.write(offset, reader)`, which is where the user copy can
// fault. On a fault nothing rolls the size back, so a write that copied and
// committed zero bytes still grows the file.
//
// The same source is compiled separately on Linux and Asterinas. Each case
// encodes the observed Linux tmpfs size semantics as its control. Every case
// uses only public syscalls -- no failpoints, no injected kernel state.
//
// Usage: test_bugMC-4_ramfs_size_publication [dir]   (default "/")

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE_BYTES 4096
#define BODY_BYTES (2 * PAGE_BYTES) /* 8192: initial file size */

static int deviations;
static int failures;

static void fail(const char *what, int code)
{
	printf("MC4_FAIL %s errno=%d\n", what, code);
	failures++;
}

/* Three pages with the first one PROT_NONE: a copy from ptr faults on its
 * very first byte, so the kernel copies zero bytes. This is the
 * `MCFileOpsWriteAtCopyFaultZero` step of the counterexample. */
static char *fault_at_byte_zero(void)
{
	size_t len = 3 * PAGE_BYTES;
	char *m = mmap(NULL, len, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (m == MAP_FAILED)
		return NULL;
	memset(m, 0x41, len);
	if (mprotect(m, PAGE_BYTES, PROT_NONE) != 0)
		return NULL;
	return m;
}

static char *valid_buffer(void)
{
	char *b = malloc(BODY_BYTES);

	if (b)
		memset(b, 0x31, BODY_BYTES);
	return b;
}

static long file_size(int fd)
{
	struct stat st;

	if (fstat(fd, &st) != 0)
		return -1;
	return (long)st.st_size;
}

/* Fresh file of exactly BODY_BYTES bytes. */
static int make_target(const char *dir, const char *name, char *valid,
		       char *path_out, size_t path_len)
{
	int fd;

	snprintf(path_out, path_len, "%s%s%s", dir,
		 dir[strlen(dir) - 1] == '/' ? "" : "/", name);
	unlink(path_out);
	fd = open(path_out, O_CREAT | O_TRUNC | O_RDWR, 0600);
	if (fd < 0) {
		fail("open", errno);
		return -1;
	}
	if (pwrite(fd, valid, BODY_BYTES, 0) != BODY_BYTES) {
		fail("seed_pwrite", errno);
		close(fd);
		return -1;
	}
	if (file_size(fd) != BODY_BYTES) {
		fail("seed_size", 0);
		close(fd);
		return -1;
	}
	return fd;
}

static void report(const char *tag, const char *op, long ret, int err,
		   long before, long after, long expected)
{
	const char *verdict = (after == expected) ? "OK" : "SIZE_GREW";

	if (after != expected)
		deviations++;
	printf("CASE %s %s: ret=%ld errno=%d size_before=%ld size_after=%ld "
	       "linux_expected=%ld VERDICT=%s\n",
	       tag, op, ret, err, before, after, expected, verdict);
}

/* Case A -- the counterexample itself: an extending pwrite64 whose user copy
 * faults having copied zero bytes. */
static void case_a(const char *dir, char *valid, char *faulting)
{
	char path[256];
	long before, after, reopened;
	ssize_t ret;
	int err;
	int fd = make_target(dir, "mc4-a", valid, path, sizeof(path));

	if (fd < 0)
		return;

	before = file_size(fd);
	errno = 0;
	ret = pwrite(fd, faulting, BODY_BYTES, BODY_BYTES);
	err = errno;
	after = file_size(fd);
	report("A", "pwrite64_extending_zero_copy_fault", (long)ret, err, before,
	       after, BODY_BYTES);

	if (ret != -1 || err != EFAULT)
		fail("case_a_expected_EFAULT", err);

	/* Consequences a normal caller sees. */
	printf("CASE A lseek_end=%ld\n", (long)lseek(fd, 0, SEEK_END));
	{
		char sink[PAGE_BYTES];
		ssize_t got = pread(fd, sink, sizeof(sink), BODY_BYTES);
		int nonzero = 0;

		for (ssize_t i = 0; i < (got > 0 ? got : 0); i++)
			if (sink[i] != 0)
				nonzero = 1;
		printf("CASE A pread_past_old_eof: ret=%ld nonzero_bytes=%d "
		       "linux_expected_ret=0\n",
		       (long)got, nonzero);
	}

	close(fd);
	fd = open(path, O_RDONLY);
	reopened = fd >= 0 ? file_size(fd) : -1;
	printf("CASE A size_after_close_reopen=%ld linux_expected=%d\n",
	       reopened, BODY_BYTES);
	if (fd >= 0)
		close(fd);
	unlink(path);
}

/* Case B -- zero-length write past EOF: same publication ordering, no fault at
 * all. `write_len` is 0, so `new_size = offset` is published and nothing is
 * ever copied. */
static void case_b(const char *dir, char *valid)
{
	char path[256];
	long before, after;
	ssize_t ret;
	int err;
	int fd = make_target(dir, "mc4-b", valid, path, sizeof(path));

	if (fd < 0)
		return;

	before = file_size(fd);
	errno = 0;
	ret = pwrite(fd, valid, 0, 4 * PAGE_BYTES);
	err = errno;
	after = file_size(fd);
	report("B", "pwrite64_zero_length_past_eof", (long)ret, err, before,
	       after, BODY_BYTES);

	if (ret != 0)
		fail("case_b_expected_ret_0", err);
	close(fd);
	unlink(path);
}

/* Case C -- the shared-offset path: O_APPEND write whose copy faults at byte
 * zero. Reaches the same `RamInode::write_at` publication. */
static void case_c(const char *dir, char *valid, char *faulting)
{
	char path[256];
	long before, after;
	ssize_t ret;
	int err, flags;
	int fd = make_target(dir, "mc4-c", valid, path, sizeof(path));

	if (fd < 0)
		return;

	flags = fcntl(fd, F_GETFL);
	if (flags < 0 || fcntl(fd, F_SETFL, flags | O_APPEND) != 0) {
		fail("set_o_append", errno);
		close(fd);
		return;
	}

	before = file_size(fd);
	errno = 0;
	ret = write(fd, faulting, BODY_BYTES);
	err = errno;
	after = file_size(fd);
	report("C", "write_o_append_zero_copy_fault", (long)ret, err, before,
	       after, BODY_BYTES);

	if (ret != -1 || err != EFAULT)
		fail("case_c_expected_EFAULT", err);
	close(fd);
	unlink(path);
}

/* Case D -- plain write() at a shared offset seeked past EOF, copy faults at
 * byte zero.
 *
 * Reference measured on Linux tmpfs: `shmem_write_end` runs with copied == 0
 * and sets i_size to `pos + copied`, so the file grows to the write START
 * offset (16384) -- never to `pos + len` (24576). Asterinas publishes
 * `offset + reader.remain()`, i.e. the requested end. */
static void case_d(const char *dir, char *valid, char *faulting)
{
	char path[256];
	long before, after, off_after;
	ssize_t ret;
	int err;
	int fd = make_target(dir, "mc4-d", valid, path, sizeof(path));

	if (fd < 0)
		return;

	if (lseek(fd, 4 * PAGE_BYTES, SEEK_SET) != 4 * PAGE_BYTES) {
		fail("lseek_past_eof", errno);
		close(fd);
		return;
	}

	before = file_size(fd);
	errno = 0;
	ret = write(fd, faulting, BODY_BYTES);
	err = errno;
	after = file_size(fd);
	off_after = lseek(fd, 0, SEEK_CUR);
	report("D", "write_at_seeked_offset_zero_copy_fault", (long)ret, err,
	       before, after, 4 * PAGE_BYTES);
	printf("CASE D offset_after=%ld linux_expected=%d\n", off_after,
	       4 * PAGE_BYTES);

	if (ret != -1 || err != EFAULT)
		fail("case_d_expected_EFAULT", err);
	close(fd);
	unlink(path);
}

/* Case E -- the counterexample geometry exactly: the write STARTS INSIDE the
 * file (offset < size) and extends past EOF, and the copy faults at byte zero.
 * CE state: explicitOffset=1, fileSize=2, plannedEnd=3, copied="Zero" =>
 * fileSize becomes 3 while expectedFileSize stays 2.
 *
 * Linux reference: copied == 0 so i_size moves to `pos + copied` = 4096, which
 * is below the current 8192 -- the size does not move at all. */
static void case_e(const char *dir, char *valid, char *faulting)
{
	char path[256];
	long before, after;
	ssize_t ret;
	int err;
	int fd = make_target(dir, "mc4-e", valid, path, sizeof(path));

	if (fd < 0)
		return;

	before = file_size(fd);
	errno = 0;
	ret = pwrite(fd, faulting, BODY_BYTES, PAGE_BYTES);
	err = errno;
	after = file_size(fd);
	report("E", "pwrite64_overlapping_eof_zero_copy_fault", (long)ret, err,
	       before, after, BODY_BYTES);

	if (ret != -1 || err != EFAULT)
		fail("case_e_expected_EFAULT", err);

	/* The bytes that were never written must not have become readable. */
	{
		char sink[PAGE_BYTES];
		ssize_t got = pread(fd, sink, sizeof(sink), BODY_BYTES);

		printf("CASE E pread_past_old_eof: ret=%ld linux_expected_ret=0\n",
		       (long)got);
	}
	close(fd);
	unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/";
	char *valid = valid_buffer();
	char *faulting = fault_at_byte_zero();

#ifdef __asterinas__
	const char *os = "asterinas";
#else
	const char *os = "linux";
#endif

	printf("MC4_BEGIN os=%s dir=%s\n", os, dir);
	if (!valid || !faulting) {
		printf("MC4_FAIL buffer_setup errno=%d\n", errno);
		printf("MC4_SUMMARY os=%s deviations=-1 failures=1\n", os);
		printf("MC4_DONE\n");
		fflush(stdout);
		return 0;
	}

	case_a(dir, valid, faulting);
	case_b(dir, valid);
	case_c(dir, valid, faulting);
	case_d(dir, valid, faulting);
	case_e(dir, valid, faulting);

	printf("MC4_SUMMARY os=%s deviations=%d failures=%d\n", os, deviations,
	       failures);
	printf("MC4_DONE\n");
	fflush(stdout);
	return 0;
}
