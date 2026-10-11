// SPDX-License-Identifier: GPL-2.0
/*
 * status: placeholder frontend that shows the device's hardware state (battery, CPU, temperatures,
 * memory, network, buttons, headphone jack, sleep statistics) until the real frontend exists. The
 * power button puts the device to sleep; pressing it again wakes it.
 *
 * Draws text straight into the framebuffer (/dev/fb0), so it needs neither the GPU nor SDL. The
 * framebuffer has two screen-sized pages: each frame is drawn into the hidden one, then shown by
 * panning to it. The font is the kernel's 8x16 console font (extracted from linux/ at build time),
 * drawn at double size: 64 columns by 24 rows on the 1024x768 panel.
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "font8x16.h"	/* static const unsigned char font8x16[256 * 16] */

#define SCALE		2
#define CELL_W		(8 * SCALE)
#define CELL_H		(16 * SCALE)
#define MAX_INPUTS	16
#define REFRESH_MS	500
/* Battery, USB and temperature readings each take many I2C transfers to the power chip (about 300
 * interrupts for a full battery read), so they are refreshed this often rather than every frame;
 * the battery driver itself only updates every 10 s. */
#define SLOW_REFRESH_MS	5000
#define BACKLIGHT	128	/* 0-255; the bootloader leaves it nearly dark */
/* Ignore power-button events this long after waking: the press that woke the device arrives
 * once it is running again and must not send it straight back to sleep. */
#define WAKE_GRACE_MS	1500

/* Allwinner display driver ioctl (include/video/sunxi_display2.h); this kernel has no
 * /sys/class/backlight. Arguments: screen, level. */
#define DISP_LCD_SET_BRIGHTNESS	0x102

enum { GREY = 0x909090, WHITE = 0xffffff, GREEN = 0x60e060, YELLOW = 0xe0d060, RED = 0xe06060 };

static struct fb_var_screeninfo var;
static uint8_t *fb;		/* both pages, mapped */
static uint32_t *page;		/* the hidden page being drawn */
static int fb_fd, stride;	/* stride in pixels */
static int row;			/* next text row */
/* Lines the power and CPU sections drew at their last refresh, redrawn on the frames in between
 * (at most 16; any more appear only on refresh frames). */
static struct { uint32_t rgb; int row; char text[128]; } slow[16];
static int nslow, recording;

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_BOOTTIME, &ts);	/* includes time asleep */
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

/* Convert 0xRRGGBB to the framebuffer's pixel layout. */
static uint32_t pixel(uint32_t rgb)
{
	uint32_t p = ((rgb >> 16 & 0xff) << var.red.offset) | ((rgb >> 8 & 0xff) << var.green.offset) |
		     ((rgb & 0xff) << var.blue.offset);

	return var.transp.length ? p | (0xffu << var.transp.offset) : p;
}

static void draw_char(int x, int y, unsigned char c, uint32_t color)
{
	int r, b, dy, dx;

	for (r = 0; r < 16; r++)
		for (b = 0; b < 8; b++) {
			if (!(font8x16[c * 16 + r] & (0x80 >> b)))
				continue;
			for (dy = 0; dy < SCALE; dy++)
				for (dx = 0; dx < SCALE; dx++)
					page[(y + r * SCALE + dy) * stride + x + b * SCALE + dx] = color;
		}
}

/* Print one line of text in @rgb colour on the next row; longer lines are cut at the edge. */
static void line(uint32_t rgb, const char *fmt, ...)
{
	char buf[128];
	va_list ap;
	int i;

	if ((row + 1) * CELL_H > (int)var.yres)
		return;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (recording && nslow < (int)(sizeof(slow) / sizeof(slow[0]))) {
		slow[nslow].rgb = rgb;
		slow[nslow].row = row;
		strcpy(slow[nslow++].text, buf);
	}
	for (i = 0; buf[i] && (i + 1) * CELL_W <= (int)var.xres; i++)
		draw_char(i * CELL_W, row * CELL_H, buf[i], pixel(rgb));
	row++;
}

/* First line of a file, without the newline; "" if it can't be read. */
static const char *readf(const char *path)
{
	static char buf[256];
	FILE *f = fopen(path, "r");

	buf[0] = 0;
	if (f) {
		if (fgets(buf, sizeof(buf), f))
			buf[strcspn(buf, "\n")] = 0;
		fclose(f);
	}
	return buf;
}

static long readn(const char *path)
{
	return atol(readf(path));
}

#define BAT "/sys/class/power_supply/axp2202-battery/"
#define USB "/sys/class/power_supply/axp2202-usb/"
#define CPU "/sys/devices/system/cpu/cpufreq/policy0/"

static void show_power(void)
{
	long cap = readn(BAT "capacity");

	line(WHITE, "Battery  %ld%%  %s", cap, readf(BAT "status"));
	/* The driver reports only the charge current. */
	line(GREY, "  %.2f V  %ld mA charging  %.1f C", readn(BAT "voltage_now") / 1e6,
	     readn(BAT "current_now") / 1000, readn(BAT "temp") / 10.0);
	line(GREY, "  to empty %ld min, to full %ld min", readn(BAT "time_to_empty_now") / 60,
	     readn(BAT "time_to_full_now") / 60);
	line(GREY, "USB      %s, input limit %ld mA", readn(USB "online") ? "connected" : "unplugged",
	     readn(USB "input_current_limit") / 1000);
}

/* Thermal zone type without the chip prefix and "_thermal_zone" suffix, e.g. "gpu". */
static const char *short_name(const char *type)
{
	static char buf[64];

	if (!strncmp(type, "axp2202-", 8))
		type += 8;
	snprintf(buf, sizeof(buf), "%s", type);
	buf[strcspn(buf, "_")] = 0;
	return buf;
}

static void show_cpu(void)
{
	char temps[128] = "";
	struct dirent *e;
	DIR *d;

	line(WHITE, "CPU      %ld MHz (%ld-%ld)  %s", readn(CPU "scaling_cur_freq") / 1000,
	     readn(CPU "scaling_min_freq") / 1000, readn(CPU "scaling_max_freq") / 1000,
	     readf(CPU "scaling_governor"));
	line(GREY, "  load   %s", readf("/proc/loadavg"));
	d = opendir("/sys/class/thermal");
	while (d && (e = readdir(d))) {
		char path[300];
		size_t n = strlen(temps);

		if (strncmp(e->d_name, "thermal_zone", 12))
			continue;
		snprintf(path, sizeof(path), "/sys/class/thermal/%s/type", e->d_name);
		snprintf(temps + n, sizeof(temps) - n, "%s ", short_name(readf(path)));
		n = strlen(temps);
		snprintf(path, sizeof(path), "/sys/class/thermal/%s/temp", e->d_name);
		snprintf(temps + n, sizeof(temps) - n, "%.0fC  ", readn(path) / 1000.0);
	}
	if (d)
		closedir(d);
	line(GREY, "  temp   %s", temps);
}

static void show_memory(void)
{
	long total = 0, avail = 0;
	char key[64];
	long kb;
	FILE *f = fopen("/proc/meminfo", "r");

	while (f && fscanf(f, "%63s %ld kB\n", key, &kb) == 2) {
		if (!strcmp(key, "MemTotal:"))
			total = kb;
		else if (!strcmp(key, "MemAvailable:"))
			avail = kb;
	}
	if (f)
		fclose(f);
	line(WHITE, "Memory   %ld of %ld MB in use", (total - avail) / 1024, total / 1024);
}

static void show_network(void)
{
	static const char *const ifs[] = { "usb0", "wlan0" };
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	char text[128] = "";
	size_t i;

	for (i = 0; i < sizeof(ifs) / sizeof(ifs[0]); i++) {
		struct ifreq ifr = { 0 };
		size_t n = strlen(text);

		strncpy(ifr.ifr_name, ifs[i], IFNAMSIZ - 1);
		if (s >= 0 && ioctl(s, SIOCGIFADDR, &ifr) == 0)
			snprintf(text + n, sizeof(text) - n, "%s %s  ", ifs[i],
				 inet_ntoa(((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr));
		else
			snprintf(text + n, sizeof(text) - n, "%s -  ", ifs[i]);
	}
	if (s >= 0)
		close(s);
	line(WHITE, "Network  %s", text);
}

/* Bit n of an evdev bitmask. */
#define TEST(bits, n)	((bits)[(n) / 8] & (1 << ((n) % 8)))

/* Held buttons, read from padbridge's virtual gamepad ("TRIMUI Player1"), labelled as printed
 * on the Brick. Codes as padbridge sends them (see userspace/padbridge/padbridge.c). */
static void show_buttons(int pad_fd)
{
	/* padbridge sends the Brick's X (top) as SDL's Xbox Y (0x134) and Y (left) as 0x133. */
	static const struct { int code; const char *name; } keys[] = {
		{ BTN_EAST, "A" }, { BTN_SOUTH, "B" }, { 0x134, "X" }, { 0x133, "Y" },
		{ BTN_TL, "L1" }, { BTN_TR, "R1" }, { BTN_SELECT, "SELECT" }, { BTN_START, "START" },
		{ BTN_MODE, "MENU" }, { BTN_THUMBL, "F1" }, { BTN_THUMBR, "F2" },
		{ KEY_VOLUMEUP, "VOL+" }, { KEY_VOLUMEDOWN, "VOL-" },
	};
	unsigned char kbits[KEY_MAX / 8 + 1] = { 0 }, sbits[SW_MAX / 8 + 1] = { 0 };
	struct input_absinfo a;
	char text[128] = "";
	size_t i;

	if (pad_fd < 0) {
		line(RED, "Buttons  no gamepad (is padbridge running?)");
		return;
	}
	ioctl(pad_fd, EVIOCGKEY(sizeof(kbits)), kbits);
	ioctl(pad_fd, EVIOCGSW(sizeof(sbits)), sbits);
	for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
		if (TEST(kbits, keys[i].code))
			strcat(strcat(text, keys[i].name), " ");
	if (ioctl(pad_fd, EVIOCGABS(ABS_Z), &a) == 0 && a.value)
		strcat(text, "L2 ");
	if (ioctl(pad_fd, EVIOCGABS(ABS_RZ), &a) == 0 && a.value)
		strcat(text, "R2 ");
	if (ioctl(pad_fd, EVIOCGABS(ABS_HAT0X), &a) == 0 && a.value)
		strcat(text, a.value < 0 ? "LEFT " : "RIGHT ");
	if (ioctl(pad_fd, EVIOCGABS(ABS_HAT0Y), &a) == 0 && a.value)
		strcat(text, a.value < 0 ? "UP " : "DOWN ");
	line(YELLOW, "Buttons  %s", text[0] ? text : "-");
	line(GREY, "  FN switch %s", TEST(sbits, SW_TABLET_MODE) ? "on" : "off");
}

/* Headphone jack (its input device's switches) and whether the speaker amplifier is powered (its
 * enable pin, labelled "SPK" in debugfs's GPIO list). */
static void show_audio(int jack_fd)
{
	unsigned char sbits[SW_MAX / 8 + 1] = { 0 };
	char line_buf[256];
	const char *amp = "?";
	FILE *f = fopen("/sys/kernel/debug/gpio", "r");

	while (f && fgets(line_buf, sizeof(line_buf), f))
		if (strstr(line_buf, "|SPK "))
			amp = strstr(line_buf, " hi") ? "on" : "off";
	if (f)
		fclose(f);
	if (jack_fd < 0 || ioctl(jack_fd, EVIOCGSW(sizeof(sbits)), sbits) < 0) {
		line(WHITE, "Audio    jack unknown, speaker amp %s", amp);
		return;
	}
	line(WHITE, "Audio    headphones %s%s, speaker amp %s",
	     TEST(sbits, SW_HEADPHONE_INSERT) ? "in" : "out",
	     TEST(sbits, SW_MICROPHONE_INSERT) ? " (with mic)" : "", amp);
}

static void show_sleep(void)
{
	char text[128] = "";
	char key[64], val[64];
	FILE *f = fopen("/sys/kernel/debug/suspend_stats", "r");

	while (f && fscanf(f, "%63[^:]: %63s\n", key, val) == 2)
		if (!strcmp(key, "success") || !strcmp(key, "fail"))
			snprintf(text + strlen(text), sizeof(text) - strlen(text), "%s %s  ", key, val);
	if (f)
		fclose(f);
	line(WHITE, "Sleep    %s", text[0] ? text : "(no statistics)");
}

static void draw(int pad_fd, int jack_fd)
{
	static long next_slow;
	struct timespec up;
	int back = !var.yoffset, i;

	page = (uint32_t *)(fb + (size_t)back * var.yres * stride * 4);
	memset(page, 0, (size_t)var.yres * stride * 4);
	row = 0;
	clock_gettime(CLOCK_BOOTTIME, &up);
	line(GREEN, "Brick status          up %ld:%02ld:%02ld", up.tv_sec / 3600,
	     up.tv_sec / 60 % 60, up.tv_sec % 60);
	row++;
	/* Every SLOW_REFRESH_MS read power and CPU afresh (each read wakes the power chip's I2C bus);
	 * otherwise redraw the saved lines. */
	if (now_ms() >= next_slow) {
		nslow = 0;
		recording = 1;
		show_power();
		row++;
		show_cpu();
		recording = 0;
		next_slow = now_ms() + SLOW_REFRESH_MS;
	} else {
		for (i = 0; i < nslow; i++) {
			row = slow[i].row;
			line(slow[i].rgb, "%s", slow[i].text);
		}
	}
	show_memory();
	show_network();
	row++;
	show_buttons(pad_fd);
	show_audio(jack_fd);
	row++;
	show_sleep();
	row++;
	line(GREY, "POWER: sleep / wake");

	var.yoffset = back * var.yres;
	ioctl(fb_fd, FBIOPAN_DISPLAY, &var);
}

static void set_backlight(int level)
{
	unsigned long args[4] = { 0, (unsigned long)level };	/* screen 0 */
	int fd = open("/dev/disp", O_RDWR);

	if (fd >= 0) {
		ioctl(fd, DISP_LCD_SET_BRIGHTNESS, args);
		close(fd);
	}
}

/* True within WAKE_GRACE_MS of the device waking from sleep, whoever put it to sleep (e.g. the
 * powertest tool). Time spent asleep shows as CLOCK_BOOTTIME pulling ahead of CLOCK_MONOTONIC. */
static int just_woke(void)
{
	static long asleep, woke_at = -WAKE_GRACE_MS;
	struct timespec m;
	long now = now_ms(), a;

	clock_gettime(CLOCK_MONOTONIC, &m);
	a = now - (m.tv_sec * 1000L + m.tv_nsec / 1000000);
	if (a > asleep + 100) {		/* margin: the two clocks are read a moment apart */
		asleep = a;
		woke_at = now;
	}
	return now - woke_at < WAKE_GRACE_MS;
}

/* Put the device to sleep (see tools/device/sleepnow); returns once it has woken up again. */
static void sleep_now(void)
{
	if (system("/usr/bin/sleepnow") != 0)
		fprintf(stderr, "status: sleepnow failed\n");
}

/* Open every input device; returns how many, and the fds of the virtual gamepad in @pad and the
 * headphone jack in @jack (-1 if absent). Opened once: devices that appear later aren't seen. */
static int open_inputs(struct pollfd *fds, int *pad, int *jack)
{
	struct dirent *e;
	DIR *d = opendir("/dev/input");
	int n = 0;

	*pad = *jack = -1;
	while (d && (e = readdir(d)) && n < MAX_INPUTS) {
		char path[300], name[64] = "";
		int fd;

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		if (!strcmp(name, "TRIMUI Player1"))
			*pad = fd;
		else if (strstr(name, "Audio Jack"))
			*jack = fd;
		fds[n].fd = fd;
		fds[n++].events = POLLIN;
	}
	if (d)
		closedir(d);
	return n;
}

int main(void)
{
	struct fb_fix_screeninfo fix;
	struct pollfd fds[MAX_INPUTS];
	int nfds, pad, jack, i;

	fb_fd = open("/dev/fb0", O_RDWR);
	if (fb_fd < 0 || ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) < 0 ||
	    ioctl(fb_fd, FBIOGET_FSCREENINFO, &fix) < 0 || var.bits_per_pixel != 32 ||
	    var.yres_virtual < 2 * var.yres) {
		fprintf(stderr, "status: needs a 32-bit /dev/fb0 with two pages\n");
		return 1;
	}
	stride = fix.line_length / 4;
	fb = mmap(NULL, (size_t)fix.line_length * var.yres * 2, PROT_READ | PROT_WRITE, MAP_SHARED,
		  fb_fd, 0);
	if (fb == MAP_FAILED) {
		perror("status: mmap");
		return 1;
	}
	set_backlight(BACKLIGHT);
	nfds = open_inputs(fds, &pad, &jack);

	for (;;) {
		draw(pad, jack);
		if (poll(fds, nfds, REFRESH_MS) <= 0)
			continue;
		for (i = 0; i < nfds; i++) {
			struct input_event ev;

			while (read(fds[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				if (ev.type != EV_KEY || ev.code != KEY_POWER || ev.value != 1 ||
				    just_woke())
					continue;
				sleep_now();
			}
		}
	}
}
