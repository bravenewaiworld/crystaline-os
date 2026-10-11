/*
 * memdump: print 32-bit words of physical memory (hardware registers) via /dev/mem.
 * Usage: memdump <address> <length-in-bytes>    (both accept 0x-prefixed hex)
 * Output: one "0xADDRESS 0xVALUE" line per word. The address is rounded down to
 * a multiple of 4. Needs root.
 *
 * Read-only. Reading a register block whose clock is gated or held in reset can
 * hang the bus, so callers must check the block's clock gate first.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <address> <length>\n", argv[0]);
		return 2;
	}
	uint64_t addr = strtoull(argv[1], NULL, 0) & ~3ULL;
	size_t len = strtoull(argv[2], NULL, 0);
	long page = sysconf(_SC_PAGESIZE);
	uint64_t base = addr & ~(uint64_t)(page - 1);
	size_t span = (addr - base) + len;

	/* O_SYNC gives an uncached mapping, which register reads require. read()
	 * can't be used: the kernel refuses it for addresses outside RAM. */
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}
	volatile uint8_t *map = mmap(NULL, span, PROT_READ, MAP_SHARED, fd, base);
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (size_t off = 0; off < len; off += 4)
		printf("0x%08llx 0x%08x\n", (unsigned long long)(addr + off),
		       *(volatile uint32_t *)(map + (addr - base) + off));
	return 0;
}
