// SPDX-License-Identifier: GPL-2.0
/*
 * memreg: read or write one 32-bit hardware register through /dev/mem, for experiments with
 * registers a kernel driver already owns. Bypasses the driver: a driver that caches register
 * values won't notice the change.
 * Usage: memreg <address> [value]    (numbers in C notation, e.g. 0x0300b340)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned long addr, page = sysconf(_SC_PAGESIZE);
	volatile uint32_t *reg;
	void *map;
	int fd;

	if (argc != 2 && argc != 3) {
		fprintf(stderr, "usage: %s <address> [value]\n", argv[0]);
		return 2;
	}
	addr = strtoul(argv[1], NULL, 0);
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	map = fd < 0 ? MAP_FAILED : mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
					   addr & ~(page - 1));
	if (map == MAP_FAILED) {
		perror("memreg");
		return 1;
	}
	/* an unaligned address is rounded down to its 32-bit register */
	reg = (volatile uint32_t *)((char *)map + (addr & (page - 1) & ~3UL));
	if (argc == 3)
		*reg = strtoul(argv[2], NULL, 0);
	else
		printf("0x%08x\n", *reg);
	return 0;
}
