// Canonical repro for finding MC-1 (this session's executed copy).
// Guest build input (byte-identical program body): worktree/test/initramfs/src/regression/io/file_io/specula_repro_mc1.c
// Built into the initramfs by the existing Nix wildcard and run via: make run_kernel AUTO_TEST=mc1repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1 CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1
// Host control: gcc -Wall -O2 -o <bin> test_bugMC-1_readv_prefix_fault.c && ./<bin>

// SPDX-License: MPL-2.0
//
// Reproduction test for finding MC-1: "A later readv fault can hide a
// positive copy prefix" (MC config MC_hunt_s1_partial_progress, invariant
// MCReadReturnCoversCopies).
//
// Mechanism under test: when a readv/writev iovec faults after copying a
// positive prefix, the tuple conversion at kernel/core/src/error.rs:209
// (From<(ostd::Error, usize)>) drops the copied count, InodeHandle::read
// advances the shared offset only on Ok, and the vector loop in
// kernel/core/src/syscall/preadv.rs returns only the earlier iovecs. User
// memory (readv) or the file (writev on ramfs) then holds more data than the
// return value and the shared offset report. Linux instead returns a short
// result that covers the copied prefix and advances the offset by it.
//
// Escalation level 0: public syscalls only (open/pwrite/lseek/mmap/mprotect/
// read/readv/writev/pread), single thread, fully deterministic — the fault
// address is fixed via mprotect(PROT_NONE) on the second page of a mapping,
// mirroring the technique of the existing specula_trace regression test.
//
// v4 diagnostics: raw write() output (no stdio buffering), a version banner,
// and every phase runs in a forked child so that a child death (or a phase
// that kills the kernel) is distinguishable and never takes PID 1 down with
// it before the remaining phases run.

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#define IOV0_LEN 16
#define MC1_VERSION 4

static long page_size;
static size_t unit; /* page_size / 2: the valid prefix inside a fault buffer */

static void wr(const char *s, size_t len)
{
	ssize_t w;

	while (len > 0) {
		w = write(1, s, len);
		if (w <= 0)
			_exit(99);
		s += w;
		len -= (size_t)w;
	}
}

static void out(const char *s)
{
	wr(s, strlen(s));
}

static void out_num(long long v)
{
	char b[32];
	int i = (int)sizeof(b) - 1;
	int neg = v < 0;

	b[i--] = '\n';
	if (v == 0)
		b[i--] = '0';
	while (v != 0 && i >= 0) {
		int d = neg ? -(int)(v % 10) : (int)(v % 10);

		b[i--] = (char)('0' + d);
		v /= 10;
	}
	if (neg && i >= 0)
		b[i--] = '-';
	i++;
	wr(&b[i], sizeof(b) - (size_t)i);
}

static void die(const char *what)
{
	out("MC1_SETUP_ERROR ");
	out(what);
	out(": errno=");
	out_num(errno);
	_exit(98);
}

/* Deterministic file content pattern (aperiodic over multi-page ranges). */
static unsigned char pat(size_t i)
{
	return (unsigned char)(((uint64_t)i * 2654435761u) >> 24);
}

static void write_pattern_file(const char *path, size_t total)
{
	unsigned char *buf = malloc(total);
	int fd;
	size_t done;

	if (!buf)
		die("malloc pattern");
	for (size_t i = 0; i < total; i++)
		buf[i] = pat(i);
	unlink(path);
	fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
	if (fd < 0)
		die("open pattern file");
	done = 0;
	while (done < total) {
		ssize_t w = pwrite(fd, buf + done, total - done, (off_t)done);

		if (w <= 0)
			die("pwrite pattern file");
		done += (size_t)w;
	}
	if (fsync(fd) < 0)
		die("fsync pattern file");
	if (close(fd) < 0)
		die("close pattern file");
	free(buf);
}

struct fault_buf {
	unsigned char *map;
	size_t map_len;
	unsigned char *cursor; /* map + page_size/2: `unit` valid bytes, then fault */
};

static struct fault_buf alloc_fault_buf(unsigned char fill)
{
	struct fault_buf fb;

	fb.map_len = (size_t)page_size * 2;
	fb.map = mmap(NULL, fb.map_len, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (fb.map == MAP_FAILED)
		die("mmap fault buffer");
	memset(fb.map, fill, (size_t)page_size);
	if (mprotect(fb.map + page_size, (size_t)page_size, PROT_NONE) < 0)
		die("mprotect fault page");
	fb.cursor = fb.map + page_size / 2;
	return fb;
}

static void free_fault_buf(struct fault_buf *fb)
{
	munmap(fb->map, fb->map_len);
}

/*
 * Phase 0: plain I/O sanity, no faults — verifies basic file I/O works in
 * this environment before anything touches the fault path.
 */
static void phase_sanity(const char *tag, const char *path)
{
	unsigned char b[64];
	int fd = open(path, O_RDONLY);
	ssize_t r;

	if (fd < 0)
		die("open sanity");
	if (lseek(fd, 0, SEEK_SET) != 0)
		die("lseek sanity");
	r = read(fd, b, sizeof(b));
	if (r != (ssize_t)sizeof(b) || b[0] != pat(0) || b[63] != pat(63))
		die("read sanity");
	if (close(fd) < 0)
		die("close sanity");
	out("MC1_PHASE_RESULT name=sanity tag=");
	out(tag);
	out(" ok=1\n");
}

/*
 * Phase 1: fault-buffer sanity WITHOUT kernel I/O: the valid prefix is
 * readable from userspace and stops exactly at the page boundary.
 */
static void phase_faultbuf_sanity(void)
{
	struct fault_buf fb = alloc_fault_buf(0x5a);
	unsigned char sum = 0;

	for (size_t i = 0; i < unit; i++)
		sum ^= fb.cursor[i];
	free_fault_buf(&fb);
	out("MC1_PHASE_RESULT name=faultbuf_sanity tag=none ok=1 xor=");
	out_num(sum);
}

/*
 * Phase 2 (scalar #711 form): plain read() into the fault buffer. Linux
 * returns `unit` (short read at the fault). If the kernel mishandles the
 * fault this may fail loudly — the child isolates it.
 */
static void phase_read_scalar(const char *tag, const char *path)
{
	struct fault_buf fb = alloc_fault_buf(0xA7);
	int fd = open(path, O_RDONLY);
	ssize_t ret;
	off_t off;

	if (fd < 0)
		die("open scalar");
	if (lseek(fd, 0, SEEK_SET) != 0)
		die("lseek scalar");
	errno = 0;
	ret = read(fd, fb.cursor, (size_t)page_size);
	off = lseek(fd, 0, SEEK_CUR);
	out("MC1_CASE name=read_scalar tag=");
	out(tag);
	out(" ret=");
	out_num(ret);
	out("MC1_CASE_CONT name=read_scalar errno=");
	out_num(errno);
	out("MC1_CASE_CONT name=read_scalar offset=");
	out_num(off);
	out("MC1_CASE_CONT name=read_scalar linux_ret=");
	out_num((long long)unit);
	{
		int prefix_ok = 1;

		for (size_t i = 0; i < unit; i++) {
			if (fb.cursor[i] != pat(i)) {
				prefix_ok = 0;
				break;
			}
		}
		out("MC1_CASE_CONT name=read_scalar prefix_copied=");
		out_num(prefix_ok);
	}
	close(fd);
	free_fault_buf(&fb);
}

/*
 * Phase 3 (the MC-1 counterexample): readv whose LATER iovec copies a
 * positive prefix (file bytes [IOV0_LEN, IOV0_LEN+unit)) into user memory,
 * then faults on the PROT_NONE page.
 *
 * Linux: ret = IOV0_LEN + unit, offset = IOV0_LEN + unit.
 * MC-1 claim: ret = IOV0_LEN, offset = IOV0_LEN, while the prefix bytes sit
 * in user memory beyond ret (copied-but-unreported progress).
 */
static void phase_readv_later(const char *tag, const char *path)
{
	unsigned char iov0[IOV0_LEN];
	struct fault_buf fb = alloc_fault_buf(0xA5);
	struct iovec iov[2];
	int fd = open(path, O_RDONLY);
	ssize_t ret, ret2;
	off_t off;
	int prefix_ok, stopped_at_fault, redeliver = 0;
	unsigned char *tmp;

	if (fd < 0)
		die("open case A");
	if (lseek(fd, 0, SEEK_SET) != 0)
		die("lseek case A");
	memset(iov0, 0, sizeof(iov0));
	iov[0] = (struct iovec){ .iov_base = iov0, .iov_len = sizeof(iov0) };
	iov[1] = (struct iovec){ .iov_base = fb.cursor,
				 .iov_len = (size_t)page_size };

	errno = 0;
	ret = readv(fd, iov, 2);
	off = lseek(fd, 0, SEEK_CUR);

	prefix_ok = 1;
	for (size_t i = 0; i < unit; i++) {
		if (fb.cursor[i] != pat(IOV0_LEN + i)) {
			prefix_ok = 0;
			break;
		}
	}
	stopped_at_fault = prefix_ok && ret != (ssize_t)(IOV0_LEN + (size_t)page_size);

	out("MC1_CASE name=readv_later tag=");
	out(tag);
	out(" ret=");
	out_num(ret);
	out("MC1_CASE_CONT name=readv_later errno=");
	out_num(errno);
	out("MC1_CASE_CONT name=readv_later offset=");
	out_num(off);
	out("MC1_CASE_CONT name=readv_later linux_ret=");
	out_num((long long)(IOV0_LEN + unit));
	out("MC1_CASE_CONT name=readv_later prefix_copied_beyond_ret=");
	out_num(prefix_ok);
	out("MC1_CASE_CONT name=readv_later stopped_at_fault=");
	out_num(stopped_at_fault);

	/* Follow-up: next read at the shared offset re-delivers the prefix? */
	tmp = malloc((size_t)page_size);
	if (!tmp)
		die("malloc follow-up");
	errno = 0;
	ret2 = read(fd, tmp, (size_t)page_size);
	if (ret2 >= (ssize_t)unit)
		redeliver = memcmp(tmp, fb.cursor, unit) == 0;
	out("MC1_CASE_CONT name=readv_later next_read=");
	out_num(ret2);
	out("MC1_CASE_CONT name=readv_later redelivers_prefix_bytes=");
	out_num(redeliver);
	free(tmp);
	close(fd);
	free_fault_buf(&fb);
}

/*
 * Phase 4: readv whose FIRST iovec copies a positive prefix, then faults.
 * total_len == 0 at the fault → EFAULT expected from asterinas while the
 * prefix is already in user memory and the offset unmoved (vectored form of
 * upstream #711). Linux: ret = unit, offset = unit.
 */
static void phase_readv_first(const char *tag, const char *path)
{
	struct fault_buf fb = alloc_fault_buf(0xB4);
	struct iovec iov[1];
	int fd = open(path, O_RDONLY);
	ssize_t ret;
	off_t off;
	int prefix_ok;

	if (fd < 0)
		die("open case B");
	if (lseek(fd, 0, SEEK_SET) != 0)
		die("lseek case B");
	iov[0] = (struct iovec){ .iov_base = fb.cursor,
				 .iov_len = (size_t)page_size };

	errno = 0;
	ret = readv(fd, iov, 1);
	off = lseek(fd, 0, SEEK_CUR);

	prefix_ok = 1;
	for (size_t i = 0; i < unit; i++) {
		if (fb.cursor[i] != pat(i)) {
			prefix_ok = 0;
			break;
		}
	}

	out("MC1_CASE name=readv_first tag=");
	out(tag);
	out(" ret=");
	out_num(ret);
	out("MC1_CASE_CONT name=readv_first errno=");
	out_num(errno);
	out("MC1_CASE_CONT name=readv_first offset=");
	out_num(off);
	out("MC1_CASE_CONT name=readv_first linux_ret=");
	out_num((long long)unit);
	out("MC1_CASE_CONT name=readv_first prefix_copied_despite_efault=");
	out_num(prefix_ok);
	close(fd);
	free_fault_buf(&fb);
}

/*
 * Phase 5 (committed-data form): writev whose LATER iovec has a valid
 * prefix of 'V' bytes followed by the PROT_NONE page. On ramfs the prefix is
 * committed to the file (page cache + size published before the fault) even
 * though the syscall reports only IOV0_LEN. Linux: ret = IOV0_LEN + unit.
 */
static void phase_writev_later(const char *tag, const char *path)
{
	unsigned char iov0[IOV0_LEN];
	struct fault_buf fb = alloc_fault_buf('V');
	struct iovec iov[2];
	int fd = open(path, O_RDWR);
	ssize_t ret;
	off_t off;
	size_t committed = 0;
	size_t total = IOV0_LEN + (size_t)page_size;
	unsigned char *tmp = malloc(total);
	int w_iov0_ok;

	if (fd < 0)
		die("open case C");
	if (!tmp)
		die("malloc case C");
	if (lseek(fd, 0, SEEK_SET) != 0)
		die("lseek case C");
	memset(iov0, 'W', sizeof(iov0));
	iov[0] = (struct iovec){ .iov_base = iov0, .iov_len = sizeof(iov0) };
	iov[1] = (struct iovec){ .iov_base = fb.cursor,
				 .iov_len = (size_t)page_size };

	errno = 0;
	ret = writev(fd, iov, 2);
	off = lseek(fd, 0, SEEK_CUR);

	memset(tmp, 0, total);
	if (pread(fd, tmp, total, 0) == (ssize_t)total) {
		size_t i = IOV0_LEN;

		while (i < total && tmp[i] == 'V') {
			i++;
			committed++;
		}
	}
	w_iov0_ok = tmp[0] == 'W' && tmp[IOV0_LEN - 1] == 'W';

	out("MC1_CASE name=writev_later tag=");
	out(tag);
	out(" ret=");
	out_num(ret);
	out("MC1_CASE_CONT name=writev_later errno=");
	out_num(errno);
	out("MC1_CASE_CONT name=writev_later offset=");
	out_num(off);
	out("MC1_CASE_CONT name=writev_later linux_ret=");
	out_num((long long)(IOV0_LEN + unit));
	out("MC1_CASE_CONT name=writev_later committed_prefix_bytes=");
	out_num((long long)committed);
	out("MC1_CASE_CONT name=writev_later w_iov0_ok=");
	out_num(w_iov0_ok);
	free(tmp);
	close(fd);
	free_fault_buf(&fb);
}

struct phase {
	const char *name;
	void (*fn)(void);
	int uses_ramfs_read;
	int uses_ramfs_write;
	int uses_ext2_read;
	int uses_ext2_write;
};

static const char *ramfs_read_path;
static const char *ramfs_write_path;
static const char *ext2_read_path;
static const char *ext2_write_path;

static void p_sanity_ramfs(void) { phase_sanity("ramfs", ramfs_read_path); }
static void p_sanity_ext2(void) { phase_sanity("ext2", ext2_read_path); }
static void p_read_scalar_ramfs(void) { phase_read_scalar("ramfs", ramfs_read_path); }
static void p_read_scalar_ext2(void) { phase_read_scalar("ext2", ext2_read_path); }
static void p_readv_later_ramfs(void) { phase_readv_later("ramfs", ramfs_read_path); }
static void p_readv_later_ext2(void) { phase_readv_later("ext2", ext2_read_path); }
static void p_readv_first_ramfs(void) { phase_readv_first("ramfs", ramfs_read_path); }
static void p_readv_first_ext2(void) { phase_readv_first("ext2", ext2_read_path); }
static void p_writev_later_ramfs(void) { phase_writev_later("ramfs", ramfs_write_path); }
static void p_writev_later_ext2(void) { phase_writev_later("ext2", ext2_write_path); }

static void run_phase(const char *name, void (*fn)(void))
{
	pid_t pid;
	int st;

	out("MC1_PHASE_START ");
	out(name);
	out("\n");
	pid = fork();
	if (pid < 0)
		die("fork");
	if (pid == 0) {
		fn();
		_exit(0);
	}
	if (waitpid(pid, &st, 0) < 0)
		die("waitpid");
	out("MC1_PHASE_END ");
	out(name);
	out(" status=");
	if (WIFEXITED(st)) {
		out("exit:");
		out_num(WEXITSTATUS(st));
	} else if (WIFSIGNALED(st)) {
		out("signal:");
		out_num(WTERMSIG(st));
	} else {
		out("raw:");
		out_num(st);
	}
}

static int fs_usable(const char *dir)
{
	struct stat st;

	if (stat(dir, &st) < 0 || !S_ISDIR(st.st_mode))
		return 0;
	return access(dir, W_OK) == 0;
}

int main(void)
{
	int ext2;

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0 || page_size % 2 != 0)
		die("sysconf page size");
	unit = (size_t)page_size / 2;

	out("MC1_REPRO_VERSION ");
	out_num(MC1_VERSION);

	ext2 = fs_usable("/ext2");
	out("MC1_SETUP page_size=");
	out_num(page_size);
	out("MC1_SETUP_CONT unit=");
	out_num((long long)unit);
	out("MC1_SETUP_CONT ext2=");
	out_num(ext2);

	ramfs_read_path = "/tmp/mc1_read_ramfs";
	ramfs_write_path = "/tmp/mc1_write_ramfs";
	ext2_read_path = "/ext2/mc1_read_ext2";
	ext2_write_path = "/ext2/mc1_write_ext2";

	/* File preparation (no fault buffers involved). */
	out("MC1_PHASE_START prep_ramfs_read\n");
	write_pattern_file(ramfs_read_path, (size_t)page_size * 3);
	out("MC1_PHASE_END prep_ramfs_read status=ok\n");
	out("MC1_PHASE_START prep_ramfs_write\n");
	write_pattern_file(ramfs_write_path, (size_t)page_size * 3);
	out("MC1_PHASE_END prep_ramfs_write status=ok\n");
	if (ext2) {
		out("MC1_PHASE_START prep_ext2_read\n");
		write_pattern_file(ext2_read_path, (size_t)page_size * 3);
		out("MC1_PHASE_END prep_ext2_read status=ok\n");
		out("MC1_PHASE_START prep_ext2_write\n");
		write_pattern_file(ext2_write_path, (size_t)page_size * 3);
		out("MC1_PHASE_END prep_ext2_write status=ok\n");
	}

	run_phase("faultbuf_sanity", phase_faultbuf_sanity);
	run_phase("sanity_ramfs", p_sanity_ramfs);
	run_phase("read_scalar_ramfs", p_read_scalar_ramfs);
	run_phase("readv_later_ramfs", p_readv_later_ramfs);
	run_phase("readv_first_ramfs", p_readv_first_ramfs);
	run_phase("writev_later_ramfs", p_writev_later_ramfs);

	if (ext2) {
		run_phase("sanity_ext2", p_sanity_ext2);
		run_phase("read_scalar_ext2", p_read_scalar_ext2);
		run_phase("readv_later_ext2", p_readv_later_ext2);
		run_phase("readv_first_ext2", p_readv_first_ext2);
		run_phase("writev_later_ext2", p_writev_later_ext2);
	} else {
		out("MC1_SKIP tag=ext2 reason=/ext2 not usable\n");
	}

	out("MC1_REPRO_DONE\n");
	return 0;
}
