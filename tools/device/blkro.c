/*
 * blkro: mark block devices read-only in the kernel (the BLKROSET ioctl, as `blockdev --setro`,
 * which TrimUI's BusyBox lacks), so nothing can write to them until the device goes away or the
 * flag is cleared.
 * Usage: blkro <device>...
 */
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int failed = 0, ro = 1;

	for (int i = 1; i < argc; i++) {
		int fd = open(argv[i], O_RDONLY);
		if (fd < 0 || ioctl(fd, BLKROSET, &ro) < 0) {
			perror(argv[i]);
			failed = 1;
		}
		if (fd >= 0)
			close(fd);
	}
	return failed;
}
