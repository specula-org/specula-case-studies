// SPDX-License-Identifier: MPL-2.0
//
// MC-7 reproduction: an O_APPEND write that fails leaves the shared
// open-file-description offset parked at EOF.
//
// kernel/core/src/fs/file/inode_handle.rs:308-320 (pristine baseline)
//
//     let mut offset = self.offset.lock();
//     if status_flags.contains(StatusFlags::O_APPEND) && self.open_file.is_none() {
//         *offset = self.path().size();          // <-- published before the write
//     }
//     let len = file_ops.write_at(*offset, reader, status_flags)?;   // <-- `?` bails
//     *offset += len;
//
// The `?` returns while `*offset` already holds EOF, and nothing restores the
// pre-write value. Linux keeps the O_APPEND target position in the local
// `kiocb.ki_pos` (generic_write_checks) and copies it back into `file->f_pos`
// only when the write reported progress (fs/read_write.c: `if (ret > 0) *ppos =
// kiocb.ki_pos;` then `if (ret >= 0 && ppos) file->f_pos = pos;`), so a failed
// O_APPEND write never moves f_pos.
//
// Level 0: public syscalls only (open/dup/mmap/mprotect/write/lseek/read).
// No failpoint, no injected state, no kernel modification.
//
// Usage: mc7_append_offset_on_fault <dir>
// Every case prints one MC7 line; the driver greps for them.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#define PAGE_BYTES 4096
#define SEED_BYTES 4096
#define PROBE_BYTES 16

static int failures;

/* A buffer whose first page is PROT_NONE: the copy faults having moved zero
 * bytes, which is the counterexample's MCFileOpsWriteAtCopyFaultZero step. */
static char *fault_zero_buffer(void)
{
	char *map = mmap(NULL, 2 * PAGE_BYTES, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (map == MAP_FAILED)
		return NULL;
	memset(map, 'Z', 2 * PAGE_BYTES);
	if (mprotect(map, PAGE_BYTES, PROT_NONE) != 0)
		return NULL;
	return map;
}

/* Readable first page, PROT_NONE second page: the copy moves a positive prefix
 * and then faults. */
static char *fault_after_prefix_buffer(void)
{
	char *map = mmap(NULL, 2 * PAGE_BYTES, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (map == MAP_FAILED)
		return NULL;
	memset(map, 'P', 2 * PAGE_BYTES);
	if (mprotect(map + PAGE_BYTES, PAGE_BYTES, PROT_NONE) != 0)
		return NULL;
	return map;
}

static char *valid_buffer(void)
{
	char *map = mmap(NULL, 2 * PAGE_BYTES, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (map == MAP_FAILED)
		return NULL;
	memset(map, 'V', 2 * PAGE_BYTES);
	return map;
}

/* Create <dir>/<name> holding SEED_BYTES of 'A'. */
static int seed_file(const char *dir, const char *name, char *path,
		     size_t path_len)
{
	char seed[SEED_BYTES];
	int fd;
	ssize_t written;

	snprintf(path, path_len, "%s/%s", dir, name);
	(void)unlink(path);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		printf("MC7_SETUP_FAIL open %s errno=%d\n", path, errno);
		return -1;
	}
	memset(seed, 'A', sizeof(seed));
	written = write(fd, seed, sizeof(seed));
	if (written != (ssize_t)sizeof(seed)) {
		printf("MC7_SETUP_FAIL seed %s wrote=%ld errno=%d\n", path,
		       (long)written, errno);
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

static long file_size(const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return -1;
	return (long)st.st_size;
}

/*
 * One case: open the seeded file, rewind the shared offset to 0, attempt a
 * write from `buf`, then look at the offset through a *duplicated* descriptor
 * (same open-file description) and try to read the data that lives there.
 *
 * `expect_rc` < 0 means the write is expected to fail.
 */
static void run_case(const char *label, const char *dir, const char *name,
		     int extra_open_flags, char *buf, size_t len,
		     int expect_fail)
{
	char path[256];
	char probe[PROBE_BYTES + 1];
	int fd, dupfd;
	long size_before, size_after, off_before, off_after, off_expected;
	ssize_t rc, nread;
	int write_errno;
	int bug = 0;

	if (seed_file(dir, name, path, sizeof(path)) != 0)
		return;

	fd = open(path, O_RDWR | extra_open_flags);
	if (fd < 0) {
		printf("MC7_SETUP_FAIL reopen %s errno=%d\n", path, errno);
		return;
	}
	/* A second descriptor onto the SAME open-file description; this is what
	 * dup()/fork() hand to a cooperating thread or child. */
	dupfd = dup(fd);
	if (dupfd < 0) {
		printf("MC7_SETUP_FAIL dup errno=%d\n", errno);
		close(fd);
		return;
	}

	if (lseek(fd, 0, SEEK_SET) != 0) {
		printf("MC7_SETUP_FAIL rewind errno=%d\n", errno);
		close(fd);
		close(dupfd);
		return;
	}

	size_before = file_size(path);
	off_before = (long)lseek(dupfd, 0, SEEK_CUR);

	errno = 0;
	rc = write(fd, buf, len);
	write_errno = errno;

	off_after = (long)lseek(dupfd, 0, SEEK_CUR);
	size_after = file_size(path);

	/* Linux contract: a write that reports no progress leaves f_pos alone;
	 * one that reports n advances it by exactly n from where it wrote. */
	if (rc <= 0)
		off_expected = off_before;
	else if (extra_open_flags & O_APPEND)
		off_expected = size_before + rc;
	else
		off_expected = off_before + rc;

	memset(probe, 0, sizeof(probe));
	nread = read(dupfd, probe, PROBE_BYTES);

	printf("MC7_CASE %s dir=%s append=%d req=%ld rc=%ld errno=%d "
	       "size_before=%ld size_after=%ld off_before=%ld off_after=%ld "
	       "off_expected=%ld dupfd_read=%ld dupfd_bytes=[%s]\n",
	       label, dir, (extra_open_flags & O_APPEND) ? 1 : 0, (long)len,
	       (long)rc, write_errno, size_before, size_after, off_before,
	       off_after,
	       off_expected, (long)nread, probe);

	if (expect_fail && rc >= 0) {
		printf("MC7_NOTE %s write unexpectedly succeeded (rc=%ld)\n",
		       label, (long)rc);
	}
	if (off_after != off_expected) {
		printf("MC7_BUG %s shared_offset_moved off_before=%ld "
		       "off_after=%ld expected=%ld reported=%ld\n",
		       label, off_before, off_after, off_expected, (long)rc);
		bug = 1;
	}
	if (rc < 0 && off_before == 0 && nread == 0) {
		printf("MC7_BUG %s consumer_sees_eof dupfd_read=0 "
		       "expected=%d bytes of file data\n",
		       label, PROBE_BYTES);
		bug = 1;
	}
	if (bug)
		failures++;
	else
		printf("MC7_OK %s\n", label);

	close(fd);
	close(dupfd);
	(void)unlink(path);
}

int main(int argc, char **argv)
{
	const char *dir = (argc > 1) ? argv[1] : "/tmp";
	char *fz = fault_zero_buffer();
	char *fp = fault_after_prefix_buffer();
	char *ok = valid_buffer();

	if (!fz || !fp || !ok) {
		printf("MC7_SETUP_FAIL buffers errno=%d\n", errno);
		return 1;
	}

	printf("MC7_BEGIN dir=%s\n", dir);

	/* The counterexample: O_APPEND + a copy that faults with zero progress.
	 * MC trace: ofdOffset 0 -> 2 at ChooseAppendStart, CopyFaultZero, then
	 * SyscallDispatch with reported="Zero" and ofdOffset still 2. */
	run_case("A_append_zero_fault", dir, "mc7_a", O_APPEND, fz,
		 PAGE_BYTES, 1);

	/* Control: same fault without O_APPEND. The offset must not move, and
	 * it does not, which isolates the append assignment as the cause. */
	run_case("B_plain_zero_fault", dir, "mc7_b", 0, fz, PAGE_BYTES, 1);

	/* Control: O_APPEND that succeeds. The offset must land on the new EOF. */
	run_case("C_append_success", dir, "mc7_c", O_APPEND, ok,
		 PAGE_BYTES, 0);

	/* O_APPEND with a positive copy prefix before the fault. */
	run_case("D_append_prefix_fault", dir, "mc7_d", O_APPEND, fp,
		 2 * PAGE_BYTES, 1);

	printf("MC7_END dir=%s bugs=%d\n", dir, failures);
	return 0;
}
