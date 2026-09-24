// AST-02 minimal: on ramfs/tmpfs a zero-length pwrite past EOF, and a pwrite whose
// user buffer faults before any byte is copied, must not change the file size.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static off_t size_of(int fd) { struct stat st; fstat(fd, &st); return st.st_size; }

int main(int argc, char **argv) {
	const char *path = argc > 1 ? argv[1] : "/min_ast02.bin";
	char page[4096]; memset(page, 0x41, sizeof(page));
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	write(fd, page, sizeof(page));                       // size = 4096
	int bugs = 0;

	// 1. zero-length pwrite at offset 8192 (past EOF)
	ssize_t r = pwrite(fd, page, 0, 8192);
	printf("zero-length pwrite past EOF: ret=%zd errno=%d size=%ld (expected 4096)\n",
	       r, r < 0 ? errno : 0, (long)size_of(fd));
	bugs += size_of(fd) != 4096;

	// 2. pwrite(len=4096) at offset 8192 from a PROT_NONE buffer: EFAULT, zero progress.
	//    Linux grows the file to the write start (pos + copied = 8192); Asterinas grows it
	//    to the requested end (8192 + 4096 = 12288).
	char *bad = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	r = pwrite(fd, bad, 4096, 8192);
	printf("EFAULT pwrite past EOF:      ret=%zd errno=%d size=%ld (Linux: 8192)\n",
	       r, r < 0 ? errno : 0, (long)size_of(fd));
	bugs += size_of(fd) != 8192;

	// 3. bytes of the requested range that were never written must not be readable
	char buf[16]; r = pread(fd, buf, sizeof(buf), 8192);
	printf("pread at 8192:               ret=%zd (Linux: 0)\n", r);
	bugs += r != 0;

	close(fd); unlink(path);
	printf("MIN_AST02 %s\n", bugs ? "BUG" : "OK");
	return 0;
}
