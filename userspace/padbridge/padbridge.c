// SPDX-License-Identifier: GPL-2.0
/*
 * padbridge: turns the Brick's buttons into the virtual gamepad that NextUI (our frontend),
 * RetroArch, PortMaster and most SDL apps expect. It replaces trimui_inputd, TrimUI's stock input
 * daemon, which read the button pins through /dev/mem.
 *
 * Input: the kernel's standard gpio-keys device "brick-keys" (GPIO-wired buttons as an input
 * device; defined by the device tree). It is grabbed exclusively (EVIOCGRAB), otherwise apps would
 * see every press twice.
 *
 * Output: a virtual input device (created through /dev/uinput) identical to trimui_inputd's: name
 * "TRIMUI Player1" and the Xbox 360 IDs (bus USB, vendor 045e, product 028e, version 0x0114), by
 * which SDL recognises the controller and applies its Xbox mapping. Layout, as trimui_inputd
 * sends it:
 *   face buttons  gpio-keys reports positional codes as Documentation/input/gamepad.rst defines
 *                 them (BTN_NORTH 0x133 = top, BTN_WEST 0x134 = left); SDL's Xbox mapping takes
 *                 0x133 as the left button and 0x134 as the top one, so those two are swapped
 *   L1/R1         BTN_TL/BTN_TR;  L2/R2 as the analog-trigger axes ABS_Z/ABS_RZ, 0 or 255
 *   D-pad         hat axes ABS_HAT0X/ABS_HAT0Y
 *   F1/F2 buttons BTN_THUMBL/BTN_THUMBR;  SELECT/START/MENU (BTN_MODE) and volume keys unchanged
 *   FN slider     switch SW_TABLET_MODE, unchanged
 *
 * Options: trimui_inputd's option files in /tmp/trimui_inputd/, which NextUI creates and deletes;
 * an option is on while its file exists, and they are re-read every second:
 *   turbo_{a,b,x,y,l,r,l2,r2}   auto-fire that button while held (Nintendo labels: a = right)
 *   input_no_dpad               don't report the D-pad
 *   input_dpad_to_joystick      report the D-pad as the left stick (ABS_X/ABS_Y) instead
 *
 * Runs in the foreground under procd, OpenWrt's service supervisor, which restarts it if it exits
 * (but gives up after 5 quick exits, e.g. if the buttons' device is missing). Exits on errors such
 * as the buttons' device disappearing.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define KEYS_NAME	"brick-keys"	/* gpio-keys label in the device tree */
#define OPTIONS_DIR	"/tmp/trimui_inputd/"
#define OPTIONS_POLL_MS	1000
#define TURBO_MS	33	/* auto-fire half-period: about 15 presses a second */
#define STICK_MAX	32767
/* SDL's Xbox X (left) and Y (top) buttons. Raw values: the kernel's names for these codes,
 * BTN_X/BTN_Y, are aliases of BTN_NORTH/BTN_WEST (top/left), the opposite positions. */
#define XBOX_X		0x133
#define XBOX_Y		0x134

/* What a gpio-keys code becomes on the virtual pad. */
enum kind { KEY, TRIGGER, DPAD };
enum { UP, DOWN, LEFT, RIGHT };

struct mapping {
	unsigned short in;	/* gpio-keys code */
	enum kind kind;
	unsigned short out;	/* KEY: pad key code; TRIGGER: ABS_Z/ABS_RZ; DPAD: UP..RIGHT */
	const char *turbo;	/* option file enabling auto-fire, or NULL */
};

static const struct mapping map[] = {
	{ BTN_SOUTH,		KEY,	 BTN_SOUTH,	 "turbo_b" },	/* B, bottom */
	{ BTN_EAST,		KEY,	 BTN_EAST,	 "turbo_a" },	/* A, right */
	{ BTN_NORTH,		KEY,	 XBOX_Y,	 "turbo_x" },	/* X, top */
	{ BTN_WEST,		KEY,	 XBOX_X,	 "turbo_y" },	/* Y, left */
	{ BTN_TL,		KEY,	 BTN_TL,	 "turbo_l" },
	{ BTN_TR,		KEY,	 BTN_TR,	 "turbo_r" },
	{ BTN_TL2,		TRIGGER, ABS_Z,		 "turbo_l2" },
	{ BTN_TR2,		TRIGGER, ABS_RZ,	 "turbo_r2" },
	{ BTN_SELECT,		KEY,	 BTN_SELECT,	 NULL },
	{ BTN_START,		KEY,	 BTN_START,	 NULL },
	{ BTN_MODE,		KEY,	 BTN_MODE,	 NULL },
	{ BTN_TRIGGER_HAPPY1,	KEY,	 BTN_THUMBL,	 NULL },	/* F1 */
	{ BTN_TRIGGER_HAPPY2,	KEY,	 BTN_THUMBR,	 NULL },	/* F2 */
	{ BTN_DPAD_UP,		DPAD,	 UP,		 NULL },
	{ BTN_DPAD_DOWN,	DPAD,	 DOWN,		 NULL },
	{ BTN_DPAD_LEFT,	DPAD,	 LEFT,		 NULL },
	{ BTN_DPAD_RIGHT,	DPAD,	 RIGHT,		 NULL },
	{ KEY_VOLUMEUP,		KEY,	 KEY_VOLUMEUP,	 NULL },
	{ KEY_VOLUMEDOWN,	KEY,	 KEY_VOLUMEDOWN, NULL },
};
#define NMAP (sizeof(map) / sizeof(map[0]))

static int out_fd;
static int held[NMAP];		/* physical state of each mapped button */
static int turbo_on[NMAP];	/* auto-fire enabled by option file */
static int turbo_phase;		/* auto-fire buttons read as pressed while this is 1 */
static int no_dpad, dpad_to_stick;
static int fn_switch;		/* FN slider position */

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

static void emit(int type, int code, int value)
{
	struct input_event ev = { .type = type, .code = code, .value = value };

	if (write(out_fd, &ev, sizeof(ev)) < 0)
		perror("padbridge: write");
}

/* Bring the virtual pad in line with the buttons, options and auto-fire phase. Sends every value;
 * the kernel's input core passes on only those that changed, and drops a report with none (for
 * axes only with our kernel patch "input: drop repeated axis values again"; Allwinner's kernel
 * passes repeats on, waking every reader on each options check). */
static void sync_pad(void)
{
	int dir[4] = { 0 };
	size_t i;

	for (i = 0; i < NMAP; i++) {
		int down = held[i] && (!turbo_on[i] || turbo_phase);

		if (map[i].kind == KEY)
			emit(EV_KEY, map[i].out, down);
		else if (map[i].kind == TRIGGER)
			emit(EV_ABS, map[i].out, down ? 255 : 0);
		else
			dir[map[i].out] = down && !no_dpad;
	}
	emit(EV_ABS, ABS_X, dpad_to_stick ? (dir[RIGHT] - dir[LEFT]) * STICK_MAX : 0);
	emit(EV_ABS, ABS_Y, dpad_to_stick ? (dir[DOWN] - dir[UP]) * STICK_MAX : 0);
	emit(EV_ABS, ABS_HAT0X, dpad_to_stick ? 0 : dir[RIGHT] - dir[LEFT]);
	emit(EV_ABS, ABS_HAT0Y, dpad_to_stick ? 0 : dir[DOWN] - dir[UP]);
	emit(EV_SW, SW_TABLET_MODE, fn_switch);
	emit(EV_SYN, SYN_REPORT, 0);
}

static int option(const char *name)
{
	char path[64];

	snprintf(path, sizeof(path), OPTIONS_DIR "%s", name);
	return access(path, F_OK) == 0;
}

static void read_options(void)
{
	size_t i;

	for (i = 0; i < NMAP; i++)
		turbo_on[i] = map[i].turbo && option(map[i].turbo);
	no_dpad = option("input_no_dpad");
	dpad_to_stick = option("input_dpad_to_joystick");
}

#define BIT_SET(bits, n)	(!!((bits)[(n) / 8] & (1 << ((n) % 8))))

/* Read the buttons' and switch's current state from the device (at start, and if events were
 * dropped). */
static void read_state(int in_fd)
{
	unsigned char keys[KEY_MAX / 8 + 1] = { 0 }, sw[SW_MAX / 8 + 1] = { 0 };
	size_t i;

	ioctl(in_fd, EVIOCGKEY(sizeof(keys)), keys);
	ioctl(in_fd, EVIOCGSW(sizeof(sw)), sw);
	for (i = 0; i < NMAP; i++)
		held[i] = BIT_SET(keys, map[i].in);
	fn_switch = BIT_SET(sw, SW_TABLET_MODE);
}

/* Open the gpio-keys device by name; -1 if it isn't there. */
static int open_keys(void)
{
	DIR *d = opendir("/dev/input");
	struct dirent *e;
	int fd = -1;

	while (d && (e = readdir(d))) {
		char path[300], name[64] = "";

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);	/* the main loop reads until EAGAIN */
		if (fd >= 0 && ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
		    !strcmp(name, KEYS_NAME))
			break;
		if (fd >= 0)
			close(fd);
		fd = -1;
	}
	if (d)
		closedir(d);
	return fd;
}

/* Create the virtual pad with trimui_inputd's capabilities; sets out_fd. */
static int create_pad(void)
{
	static const struct { int code, min, max; } axes[] = {
		{ ABS_X, -STICK_MAX, STICK_MAX }, { ABS_Y, -STICK_MAX, STICK_MAX },
		/* right stick: declared only to match trimui_inputd; never sent */
		{ ABS_RX, -STICK_MAX, STICK_MAX }, { ABS_RY, -STICK_MAX, STICK_MAX },
		{ ABS_Z, 0, 255 }, { ABS_RZ, 0, 255 }, { ABS_HAT0X, -1, 1 }, { ABS_HAT0Y, -1, 1 },
	};
	struct uinput_user_dev dev = { .id = { BUS_USB, 0x045e, 0x028e, 0x0114 } };
	size_t i;
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);

	if (fd < 0)
		return -1;
	strcpy(dev.name, "TRIMUI Player1");
	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	ioctl(fd, UI_SET_EVBIT, EV_SW);
	for (i = 0; i < NMAP; i++)
		if (map[i].kind == KEY)
			ioctl(fd, UI_SET_KEYBIT, map[i].out);
	/* Keyboard F1/F2 keys: declared but never sent, as trimui_inputd does (the F1/F2 buttons
	 * are sent as BTN_THUMBL/BTN_THUMBR). */
	ioctl(fd, UI_SET_KEYBIT, KEY_F1);
	ioctl(fd, UI_SET_KEYBIT, KEY_F2);
	for (i = 0; i < sizeof(axes) / sizeof(axes[0]); i++) {
		ioctl(fd, UI_SET_ABSBIT, axes[i].code);
		dev.absmin[axes[i].code] = axes[i].min;
		dev.absmax[axes[i].code] = axes[i].max;
	}
	ioctl(fd, UI_SET_SWBIT, SW_TABLET_MODE);
	if (write(fd, &dev, sizeof(dev)) != sizeof(dev) || ioctl(fd, UI_DEV_CREATE) < 0) {
		close(fd);
		return -1;
	}
	out_fd = fd;
	return 0;
}

int main(void)
{
	long next_options = 0, next_turbo = 0;	/* the first pass reads options and syncs */
	int in_fd = open_keys();

	if (in_fd < 0) {
		fprintf(stderr, "padbridge: no \"%s\" input device\n", KEYS_NAME);
		return 1;
	}
	if (ioctl(in_fd, EVIOCGRAB, 1) < 0) {
		perror("padbridge: grab " KEYS_NAME);
		return 1;
	}
	read_state(in_fd);
	if (create_pad() < 0) {
		perror("padbridge: create virtual pad");
		return 1;
	}

	for (;;) {
		struct pollfd pfd = { .fd = in_fd, .events = POLLIN };
		struct input_event ev;
		long t = now_ms(), wake;
		int any_turbo = 0, changed = 0;
		size_t i;

		/* Reads don't block; once the device is gone they fail with ENODEV. */
		while (read(in_fd, &ev, sizeof(ev)) == sizeof(ev)) {
			if (ev.type == EV_SYN && ev.code == SYN_DROPPED) {
				read_state(in_fd);	/* events were lost: re-read the state */
				changed = 1;
			} else if (ev.type == EV_SW && ev.code == SW_TABLET_MODE) {
				fn_switch = ev.value;
				changed = 1;
			} else if (ev.type == EV_KEY && ev.value != 2) {	/* 2 = autorepeat */
				for (i = 0; i < NMAP; i++) {
					if (map[i].in != ev.code)
						continue;
					held[i] = ev.value;
					changed = 1;
					if (ev.value && turbo_on[i]) {
						/* A new auto-fire press shows at once and lasts a
						 * full half-period. */
						turbo_phase = 1;
						next_turbo = t + TURBO_MS;
					}
				}
			}
		}
		/* evdev reads return whole events or fail, so errno is from the failed read. */
		if (errno != EAGAIN) {
			perror("padbridge: read " KEYS_NAME);
			return 1;
		}

		if (t >= next_options) {
			read_options();
			next_options = t + OPTIONS_POLL_MS;
			changed = 1;
		}
		for (i = 0; i < NMAP; i++)
			any_turbo |= held[i] && turbo_on[i];
		if (any_turbo && t >= next_turbo) {
			turbo_phase = !turbo_phase;
			next_turbo = t + TURBO_MS;
			changed = 1;
		}
		if (changed)
			sync_pad();

		/* Sleep until the next auto-fire toggle (if a button is auto-firing) or options check;
		 * both are in the future here, so the timeout is positive. */
		wake = any_turbo && next_turbo < next_options ? next_turbo : next_options;
		poll(&pfd, 1, wake - t);
	}
}
