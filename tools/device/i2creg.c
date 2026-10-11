// SPDX-License-Identifier: GPL-2.0
/*
 * i2creg: read or write one 8-bit register of an I2C chip, for experiments with chips a kernel
 * driver already owns (it uses I2C_SLAVE_FORCE). Bypasses the driver: a driver that caches
 * register values won't notice the change.
 * Usage: i2creg <bus> <address> <register> [value]    (numbers in C notation, e.g. 0x34)
 */
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	union i2c_smbus_data data;
	struct i2c_smbus_ioctl_data cmd = { .size = I2C_SMBUS_BYTE_DATA, .data = &data };
	char dev[32];
	int fd;

	if (argc != 4 && argc != 5) {
		fprintf(stderr, "usage: %s <bus> <address> <register> [value]\n", argv[0]);
		return 2;
	}
	snprintf(dev, sizeof(dev), "/dev/i2c-%s", argv[1]);
	cmd.command = strtoul(argv[3], NULL, 0);
	cmd.read_write = argc == 5 ? I2C_SMBUS_WRITE : I2C_SMBUS_READ;
	data.byte = argc == 5 ? strtoul(argv[4], NULL, 0) : 0;
	fd = open(dev, O_RDWR);
	if (fd < 0 || ioctl(fd, I2C_SLAVE_FORCE, strtoul(argv[2], NULL, 0)) < 0 ||
	    ioctl(fd, I2C_SMBUS, &cmd) < 0) {
		perror("i2creg");
		return 1;
	}
	if (argc == 4)
		printf("0x%02x\n", data.byte);
	return 0;
}
