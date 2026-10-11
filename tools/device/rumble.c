// SPDX-License-Identifier: GPL-2.0
/*
 * rumble: test the vibration motor through the standard force-feedback interface, as games do.
 * Plays one rumble effect on the given input device, or the first one that supports FF_RUMBLE.
 * Usage: rumble [strength 0-100 [milliseconds [/dev/input/eventN]]]    (defaults: 100, 500)
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int open_rumble(void)
{
	DIR *d = opendir("/dev/input");
	struct dirent *e;

	while (d && (e = readdir(d))) {
		unsigned char ff[FF_MAX / 8 + 1] = { 0 };
		char path[300];
		int fd;

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		fd = open(path, O_RDWR);
		if (fd >= 0 && ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ff)), ff) >= 0 &&
		    ff[FF_RUMBLE / 8] & (1 << (FF_RUMBLE % 8))) {
			closedir(d);
			return fd;
		}
		if (fd >= 0)
			close(fd);
	}
	if (d)
		closedir(d);
	return -1;
}

int main(int argc, char **argv)
{
	int strength = argc > 1 ? atoi(argv[1]) : 100, ms = argc > 2 ? atoi(argv[2]) : 500;
	/* .id = -1: the kernel assigns a new effect id */
	struct ff_effect effect = { .type = FF_RUMBLE, .id = -1 };
	struct input_event play = { .type = EV_FF, .value = 1 };
	int fd = argc > 3 ? open(argv[3], O_RDWR) : open_rumble();

	if (fd < 0) {
		fprintf(stderr, "rumble: no force-feedback input device\n");
		return 1;
	}
	effect.u.rumble.strong_magnitude = strength * 0xffff / 100;
	effect.replay.length = ms;
	if (ioctl(fd, EVIOCSFF, &effect) < 0) {
		perror("rumble: upload effect");
		return 1;
	}
	play.code = effect.id;
	if (write(fd, &play, sizeof(play)) != sizeof(play)) {
		perror("rumble: play");
		return 1;
	}
	usleep((ms + 50) * 1000);	/* the effect stops by itself; removing it early would cut it */
	ioctl(fd, EVIOCRMFF, effect.id);
	return 0;
}
