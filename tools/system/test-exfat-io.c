/*
 * File operations for test-exfat-guest.sh that BusyBox has no command for. Built for the device
 * by test-exfat.sh. Exits non-zero, with the reason on stderr, when an operation fails.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(const char *what)
{
	perror(what);
	return 1;
}

/* Writes "MMAP" at offset (within the file) through a shared mapping of the whole file. */
static int mmap_write(const char *path, off_t offset)
{
	int fd = open(path, O_RDWR);
	struct stat st;
	char *p;

	if (fd < 0 || fstat(fd, &st))
		return fail("open");
	if (offset < 0 || offset + 4 > st.st_size) {
		fprintf(stderr, "offset past the end of the file\n");
		return 1;
	}
	p = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED)
		return fail("mmap");
	memcpy(p + offset, "MMAP", 4);
	if (msync(p, st.st_size, MS_SYNC))
		return fail("msync");
	munmap(p, st.st_size);
	return close(fd) ? fail("close") : 0;
}

/* Copies len bytes at offset to stdout, read with O_DIRECT (both multiples of 512). */
static int direct_read(const char *path, off_t offset, size_t len)
{
	int fd = open(path, O_RDONLY | O_DIRECT);
	void *buf;
	ssize_t n;

	if (fd < 0)
		return fail("open O_DIRECT");
	if (posix_memalign(&buf, 4096, len))
		return fail("posix_memalign");
	n = pread(fd, buf, len, offset);
	if (n < 0)
		return fail("pread");
	fwrite(buf, 1, n, stdout);
	return 0;
}

/*
 * Saves as a game should, count times (forever if 0): write dir/save.tmp, fsync it, rename it
 * over dir/save.dat. Each save is 8192 bytes and starts with "save <number>\n".
 */
static int save(const char *dir, int count)
{
	char tmp[512], dst[512], data[8192];
	int i;

	snprintf(tmp, sizeof(tmp), "%s/save.tmp", dir);
	snprintf(dst, sizeof(dst), "%s/save.dat", dir);
	for (i = 0; count <= 0 || i < count; i++) {
		int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		size_t k;

		if (fd < 0)
			return fail("open save.tmp");
		for (k = 0; k < sizeof(data); k++)
			data[k] = 'a' + (i + k) % 26;
		snprintf(data, 32, "save %08d\n", i);	/* the NUL after it is just data */
		if (write(fd, data, sizeof(data)) != sizeof(data) || fsync(fd) || close(fd))
			return fail("write save.tmp");
		if (rename(tmp, dst))
			return fail("rename");
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "mmap-write"))
		return mmap_write(argv[2], atoll(argv[3]));
	if (argc == 5 && !strcmp(argv[1], "direct-read"))
		return direct_read(argv[2], atoll(argv[3]), atoll(argv[4]));
	if (argc == 4 && !strcmp(argv[1], "save"))
		return save(argv[2], atoi(argv[3]));
	/* Unlike BusyBox's mount, passes exactly the given options. */
	if (argc == 4 && !strcmp(argv[1], "remount-ro"))
		return mount(NULL, argv[2], NULL, MS_REMOUNT | MS_RDONLY, argv[3]) ?
			fail("remount") : 0;
	fprintf(stderr, "usage: %s mmap-write FILE OFFSET | direct-read FILE OFFSET LEN |\n"
		"       save DIR COUNT | remount-ro DIR OPTIONS\n", argv[0]);
	return 2;
}
