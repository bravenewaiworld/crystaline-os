// SPDX-License-Identifier: GPL-2.0
/*
 * status: placeholder frontend that shows the device's hardware state (battery, CPU, temperatures,
 * memory, network, buttons, headphone jack, sleep statistics) until the real frontend exists. The
 * power button puts the device to sleep; pressing it again wakes it.
 *   status --banner TITLE [[-d] LINE]...
 *                                       the status screen under TITLE (red) and the lines, drawn as
 *                                       --message draws them; frontend-run says with it why this
 *                                       screen shows instead of Specular
 *
 * Draws text straight into the framebuffer (/dev/fb0), so it needs neither the GPU nor SDL. The
 * framebuffer has two screen-sized pages: each frame is drawn into the hidden one, then shown by
 * panning to it. The font is the kernel's 8x16 console font (extracted from the family's kernel
 * source at build time), drawn at double size: 64 columns by 24 rows on a 1024x768 panel.
 * What differs between boards (the buttons' input devices, the power supplies, the board's name)
 * comes from the board's description (BOARD_*; see board()).
 *
 * The other modes serve the boot image's start-up program (initramfs; its recovery menu is in
 * docs/boot.md):
 *   status --message TITLE [[-d] LINE]...
 *                                       show TITLE (in red) and the lines, then exit, leaving them
 *                                       on screen (why the system couldn't start); a line after
 *                                       -d is a detail, in grey
 *   status --held BUTTON...             exit 0 if every BUTTON (a label printed on the device,
 *                                       e.g. MENU; buttons[] lists them) is held now, 1 if not
 *   status --menu TITLE [-n NOTE | -b B-TEXT]... ITEM...
 *                                       a list to choose from with the D-pad; A prints the chosen
 *                                       item's index (from 0) and exits 0, leaving "ITEM..." on
 *                                       screen; B exits 1; 10 minutes without a press exits 2. The
 *                                       notes appear under the title; B-TEXT is what the footer
 *                                       says B does (default "back"). Nothing scrolls: rows past
 *                                       the screen's 24 aren't shown, so keep lists short.
 *   status --task TITLE                 show crystaline-install's progress lines (LOG-FILE, STEP,
 *                                       PROGRESS, DONE, FAIL; docs/install-and-update.md) read
 *                                       from stdin, then wait for A (only A): exit 0 after DONE,
 *                                       1 after FAIL or input ending without either, 2 after 10
 *                                       minutes without a press. Up to 8 steps are listed.
 * Every mode exits 3 if it can't run (no framebuffer, no buttons, bad arguments). --held, --menu
 * and --task read the buttons' input devices (BOARD_KEYS) directly. On the Brick, padbridge takes
 * its device for itself while it runs, so then --menu and --task get no presses: they are for the
 * initramfs, where padbridge doesn't run.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <linux/kd.h>
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
/* Ignore power-button events this long after waking: the press that woke the device arrives
 * once it is running again and must not send it straight back to sleep. */
#define WAKE_GRACE_MS	1500
/* --menu and --task give up after this long without a button press, so a forgotten screen
 * doesn't drain the battery (the initramfs then powers off). */
#define IDLE_MS		(10 * 60 * 1000)

enum { GREY = 0x909090, WHITE = 0xffffff, GREEN = 0x60e060, YELLOW = 0xe0d060, RED = 0xe06060,
       SELECTED = 0x304860 };	/* the background of the chosen menu item */

/* Exit statuses shared by the modes (see the top); 0 and 1 mean what each mode says. */
enum { IDLE = 2, CANT_RUN = 3 };

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

/* Print @text on as many rows as it needs, breaking it at spaces where it can. */
static void wrapped(uint32_t rgb, const char *text)
{
	int cols = var.xres / CELL_W, n;

	while (*text) {
		n = strlen(text);
		if (n > cols) {
			for (n = cols; n > 0 && text[n] != ' '; n--)
				;
			if (!n)
				n = cols;
		}
		line(rgb, "%.*s", n, text);
		for (text += n; *text == ' '; text++)
			;
	}
}

/* Fill the background of the row the next line() draws on, before drawing it. */
static void fill_row(uint32_t rgb)
{
	uint32_t p = pixel(rgb);
	int x, y;

	for (y = row * CELL_H; y < (row + 1) * CELL_H && y < (int)var.yres; y++)
		for (x = 0; x < (int)var.xres; x++)
			page[y * stride + x] = p;
}

/* Start a blank frame, from row 0, on the page not on screen; show_frame() then shows it. */
static void begin_frame(void)
{
	page = (uint32_t *)(fb + (size_t)!var.yoffset * var.yres * stride * 4);
	memset(page, 0, (size_t)var.yres * stride * 4);
	row = 0;
}

static void show_frame(void)
{
	/* Mainline's framebuffer (DRM's emulation of one) copies what was drawn to the screen's memory
	 * some milliseconds later; fsync copies it now, so the page is complete when shown. On the
	 * Brick there is nothing to copy, and fsync fails harmlessly. */
	fsync(fb_fd);
	var.yoffset = var.yoffset ? 0 : var.yres;
	ioctl(fb_fd, FBIOPAN_DISPLAY, &var);
}

/* Start a frame with @title in @rgb on the second row, then leave a blank row. */
static void begin_titled(uint32_t rgb, const char *title)
{
	begin_frame();
	row = 1;
	line(rgb, "%s", title);
	row++;
}

/* Print @text on the bottom row (which buttons do what). */
static void footer(const char *text)
{
	row = var.yres / CELL_H - 1;
	line(GREY, "%s", text);
}

/* Exit with CANT_RUN (see the top), saying why. */
static void cant_run(const char *why)
{
	fprintf(stderr, "status: %s\n", why);
	exit(CANT_RUN);
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

/* @name's value in the board's description (/usr/share/crystaline/boards/<board>.env, plain shell
 * assignments), without the quotes around it; "" if it isn't there. The description is
 * /run/crystaline/board.env, which the system's start-up copies there, or BOARD_ENV if set (the
 * initramfs's init sets it to the file board-env picks). */
static const char *board(const char *name)
{
	const char *file = getenv("BOARD_ENV");
	char buf[256], *v;
	size_t n = strlen(name), len;
	FILE *f = fopen(file ? file : "/run/crystaline/board.env", "r");

	while (f && fgets(buf, sizeof(buf), f)) {
		if (strncmp(buf, name, n) || buf[n] != '=')
			continue;
		v = buf + n + 1;
		v[strcspn(v, "\n")] = 0;
		len = strlen(v);
		if (len >= 2 && (*v == '\'' || *v == '"') && v[len - 1] == *v) {
			v[len - 1] = 0;
			v++;
		}
		fclose(f);
		return strdup(v);
	}
	if (f)
		fclose(f);
	return "";
}

/* The status screen's board names (BOARD_NAME, BOARD_BATTERY, BOARD_CHARGER), read by main(). */
static const char *board_name, *battery, *charger;

/* Power supply @name's property @prop, as readf() reads it ("" if it has none). */
static const char *ps(const char *name, const char *prop)
{
	char path[256];

	snprintf(path, sizeof(path), "/sys/class/power_supply/%s/%s", name, prop);
	return readf(path);
}

/* The battery's property @a, or else @b ("" if it has neither). */
static const char *bat_prop(const char *a, const char *b)
{
	const char *v = ps(battery, a);

	return *v ? v : ps(battery, b);
}

#define CPU "/sys/devices/system/cpu/cpufreq/policy0/"

/* The battery and the charger input. Drivers report different values: the Brick's instantaneous
 * ones (*_now; its current only while charging) and the times to empty and full, the RK817's
 * averages (*_avg). Lines a driver can't fill are left out. */
static void show_power(void)
{
	char text[128] = "", limit[48] = "";
	const char *v;
	long cap = atol(ps(battery, "capacity")), empty;
	int n = 0;

	line(WHITE, "Battery  %ld%%  %s", cap, ps(battery, "status"));
	if (*(v = bat_prop("voltage_now", "voltage_avg")))
		n += snprintf(text + n, sizeof(text) - n, "  %.2f V", atol(v) / 1e6);
	if (*(v = bat_prop("current_now", "current_avg")))
		n += snprintf(text + n, sizeof(text) - n, "  %ld mA", atol(v) / 1000);
	if (*(v = ps(battery, "temp")))
		snprintf(text + n, sizeof(text) - n, "  %.1f C", atol(v) / 10.0);
	if (text[0])
		line(GREY, "%s", text);
	if (*(v = ps(battery, "time_to_empty_now"))) {
		empty = atol(v);	/* before the next ps() reuses readf()'s buffer */
		line(GREY, "  to empty %ld min, to full %ld min", empty / 60,
		     atol(ps(battery, "time_to_full_now")) / 60);
	}
	if (*(v = ps(charger, "input_current_limit")))
		snprintf(limit, sizeof(limit), ", input limit %ld mA", atol(v) / 1000);
	line(GREY, "USB      %s%s", atol(ps(charger, "online")) ? "connected" : "unplugged", limit);
}

/* Thermal zone type without the chip prefix and the "_thermal_zone" or "-thermal" suffix, e.g.
 * "gpu". */
static const char *short_name(const char *type)
{
	static char buf[64];
	char *end;

	if (!strncmp(type, "axp2202-", 8))
		type += 8;
	snprintf(buf, sizeof(buf), "%s", type);
	buf[strcspn(buf, "_")] = 0;
	if ((end = strstr(buf, "-thermal")))
		*end = 0;
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

/* Every input device, opened once by open_inputs(), non-blocking (devices that appear later aren't
 * seen), and whether each is one of the buttons' devices: named in BOARD_KEYS. */
static struct pollfd inputs[MAX_INPUTS];
static char is_keys[MAX_INPUTS];
static int ninputs;
static const char *key_names;	/* BOARD_KEYS */

/* Whether @word is one of the space-separated words in @list. */
static int has_word(const char *list, const char *word)
{
	size_t n = strlen(word);
	const char *p;

	for (p = list; n && (p = strstr(p, word)); p += n)
		if ((p == list || p[-1] == ' ') && (p[n] == ' ' || !p[n]))
			return 1;
	return 0;
}

static void open_inputs(void)
{
	struct dirent *e;
	DIR *d = opendir("/dev/input");

	key_names = board("BOARD_KEYS");
	while (d && (e = readdir(d)) && ninputs < MAX_INPUTS) {
		char path[300], name[64] = "";
		int fd;

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		is_keys[ninputs] = has_word(key_names, name);
		inputs[ninputs++] = (struct pollfd){ .fd = fd, .events = POLLIN };
	}
	if (d)
		closedir(d);
}

/* The buttons, labelled as printed on the devices, and their codes on the buttons' devices. The
 * face buttons' codes go by position (docs/input.md): A is the right one, B the bottom, X the top,
 * Y the left. Not every board has every button: MENU, F1 and F2 are the Brick's only; L3 and R3
 * (the sticks' clicks) the RGB20 Pro's only. */
static const struct { const char *name; int code; } buttons[] = {
	{ "A", BTN_EAST }, { "B", BTN_SOUTH }, { "X", BTN_NORTH }, { "Y", BTN_WEST },
	{ "UP", BTN_DPAD_UP }, { "DOWN", BTN_DPAD_DOWN }, { "LEFT", BTN_DPAD_LEFT },
	{ "RIGHT", BTN_DPAD_RIGHT }, { "L1", BTN_TL }, { "R1", BTN_TR }, { "L2", BTN_TL2 },
	{ "R2", BTN_TR2 }, { "SELECT", BTN_SELECT }, { "START", BTN_START }, { "MENU", BTN_MODE },
	{ "F1", BTN_TRIGGER_HAPPY1 }, { "F2", BTN_TRIGGER_HAPPY2 }, { "L3", BTN_THUMBL },
	{ "R3", BTN_THUMBR }, { "VOL+", KEY_VOLUMEUP }, { "VOL-", KEY_VOLUMEDOWN },
};
#define BUTTON_A	BTN_EAST
#define BUTTON_B	BTN_SOUTH

/* The buttons held now, from all the buttons' devices, into @bits (KEY_MAX / 8 + 1 bytes); returns
 * how many devices were read. The state is current even right after opening (gpio-keys reads the
 * buttons on open), and can be read while padbridge holds the Brick's device exclusively
 * (EVIOCGRAB stops only its events). */
static int keys_held(unsigned char *bits)
{
	unsigned char b[KEY_MAX / 8 + 1];
	int i, n = 0;
	size_t k;

	memset(bits, 0, sizeof(b));
	for (i = 0; i < ninputs; i++) {
		memset(b, 0, sizeof(b));
		if (!is_keys[i] || ioctl(inputs[i].fd, EVIOCGKEY(sizeof(b)), b) < 0)
			continue;
		for (k = 0; k < sizeof(b); k++)
			bits[k] |= b[k];
		n++;
	}
	return n;
}

/* Whether input device @i has the switch @sw; if so, @bits (SW_MAX / 8 + 1 bytes) holds the state
 * of its switches. */
static int switches(int i, int sw, unsigned char *bits)
{
	memset(bits, 0, SW_MAX / 8 + 1);
	return ioctl(inputs[i].fd, EVIOCGBIT(EV_SW, SW_MAX / 8 + 1), bits) >= 0 && TEST(bits, sw) &&
	       ioctl(inputs[i].fd, EVIOCGSW(SW_MAX / 8 + 1), bits) >= 0;
}

/* Held buttons, and the Brick's FN slider (a switch on its buttons' device). */
static void show_buttons(void)
{
	unsigned char kbits[KEY_MAX / 8 + 1], sw[SW_MAX / 8 + 1];
	char text[128] = "";
	size_t i;
	int j;

	if (!keys_held(kbits)) {
		line(RED, "Buttons  can't read them (BOARD_KEYS: \"%s\")", key_names);
		return;
	}
	for (i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++)
		if (TEST(kbits, buttons[i].code))
			strcat(strcat(text, buttons[i].name), " ");
	line(YELLOW, "Buttons  %s", text[0] ? text : "-");
	for (j = 0; j < ninputs; j++)
		if (is_keys[j] && switches(j, SW_TABLET_MODE, sw))
			line(GREY, "  FN switch %s", TEST(sw, SW_TABLET_MODE) ? "on" : "off");
}

/* Headphone jack (the switches of the input device that has SW_HEADPHONE_INSERT) and, on the
 * Brick, whether the speaker amplifier is powered (its enable pin, labelled "SPK" in debugfs's
 * GPIO list). */
static void show_audio(void)
{
	unsigned char sw[SW_MAX / 8 + 1];
	char line_buf[256], amp[32] = "";
	FILE *f = fopen("/sys/kernel/debug/gpio", "r");
	int i;

	while (f && fgets(line_buf, sizeof(line_buf), f))
		if (strstr(line_buf, "|SPK "))
			snprintf(amp, sizeof(amp), ", speaker amp %s", strstr(line_buf, " hi") ? "on" : "off");
	if (f)
		fclose(f);
	for (i = 0; i < ninputs; i++) {
		if (!switches(i, SW_HEADPHONE_INSERT, sw))
			continue;
		line(WHITE, "Audio    headphones %s%s%s", TEST(sw, SW_HEADPHONE_INSERT) ? "in" : "out",
		     TEST(sw, SW_MICROPHONE_INSERT) ? " (with mic)" : "", amp);
		return;
	}
	line(WHITE, "Audio    jack unknown%s", amp);
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

/* --banner's TITLE and lines; nbanner is 0 without --banner. */
static char **banner;
static int nbanner;

/* Print @n lines as --message describes them: a line after "-d" in grey, the others in white. */
static void message_lines(char **lines, int n)
{
	int i;

	for (i = 0; i < n; i++) {
		int detail = !strcmp(lines[i], "-d") && i + 1 < n;

		i += detail;
		if (lines[i][0])
			wrapped(detail ? GREY : WHITE, lines[i]);
		else
			row++;	/* wrapped() draws nothing for "", which callers use as a gap */
	}
}

static void draw(void)
{
	static long next_slow;
	struct timespec up;
	int i;

	begin_frame();
	/* The screen has 24 rows: a banner of up to 4 rows after wrapping, plus the blank row after
	 * it, leaves room for the rest; a longer one pushes the last lines down under the footer. */
	if (nbanner) {
		line(RED, "%s", banner[0]);
		message_lines(banner + 1, nbanner - 1);
		row++;
	}
	clock_gettime(CLOCK_BOOTTIME, &up);
	line(GREEN, "%s status   up %ld:%02ld:%02ld", board_name, up.tv_sec / 3600,
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
	show_buttons();
	show_audio();
	row++;
	show_sleep();
	footer("POWER: sleep / wake");
	show_frame();
}

/* Allwinner display driver ioctl (include/video/sunxi_display2.h), for the Brick, whose kernel has
 * no /sys/class/backlight. Arguments: screen, level (0-255). */
#define DISP_LCD_SET_BRIGHTNESS	0x102

/* Turn the backlight to half: the Brick's bootloader leaves it nearly dark, and the program that
 * last ran may have dimmed it. The first backlight in /sys/class/backlight, or else the Brick's
 * display driver. */
static void set_backlight(void)
{
	struct dirent *e;
	DIR *d = opendir("/sys/class/backlight");
	char path[300];
	FILE *f;
	long max;

	while (d && (e = readdir(d)) && e->d_name[0] == '.')
		;
	if (d && e) {
		snprintf(path, sizeof(path), "/sys/class/backlight/%s/max_brightness", e->d_name);
		max = readn(path);
		snprintf(path, sizeof(path), "/sys/class/backlight/%s/brightness", e->d_name);
		if (max > 0 && (f = fopen(path, "w"))) {
			fprintf(f, "%ld\n", max / 2);
			fclose(f);
		}
	} else {
		unsigned long args[4] = { 0, 128 };	/* screen 0 */
		int fd = open("/dev/disp", O_RDWR);

		if (fd >= 0) {
			ioctl(fd, DISP_LCD_SET_BRIGHTNESS, args);
			close(fd);
		}
	}
	if (d)
		closedir(d);
}

/* Keep the kernel's text console (mainline boards: on the screen) from drawing its cursor and
 * messages over ours. The console stays in graphics mode after status exits, which keeps a
 * --message on screen. */
static void console_off(void)
{
	int fd = open("/dev/tty0", O_RDWR);

	if (fd >= 0) {
		ioctl(fd, KDSETMODE, KD_GRAPHICS);
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

/* --message: show TITLE in red, then the lines. */
static void show_message(char **lines, int n)
{
	begin_titled(RED, lines[0]);
	message_lines(lines + 1, n - 1);
	show_frame();
}

/* Wait until one of the buttons is pressed and return its code (call open_inputs() first); exits with
 * IDLE after IDLE_MS without one. Only presses made after the buttons were opened count. */
static int next_press(void)
{
	struct pollfd p[MAX_INPUTS];
	struct input_event ev;
	long left, deadline = now_ms() + IDLE_MS;
	int i, n = 0;
	ssize_t r;

	for (i = 0; i < ninputs; i++)
		if (is_keys[i])
			p[n++] = inputs[i];
	if (!n)
		cant_run("no buttons: no input device named in BOARD_KEYS");
	for (;;) {
		for (i = 0; i < n; i++) {
			while ((r = read(p[i].fd, &ev, sizeof(ev))) == sizeof(ev))
				if (ev.type == EV_KEY && ev.value == 1)
					return ev.code;
			if (r >= 0 || errno != EAGAIN)
				cant_run("can't read the buttons");
		}
		left = deadline - now_ms();
		if (left <= 0)
			exit(IDLE);
		if (poll(p, n, left) < 0 && errno != EINTR)
			cant_run("can't read the buttons");
	}
}

/* --held: the exit status for the buttons labelled @names (0: all held, 1: not). */
static int held(int n, char **names)
{
	unsigned char bits[KEY_MAX / 8 + 1];
	size_t k, nb = sizeof(buttons) / sizeof(buttons[0]);
	int i, all = 1;

	open_inputs();
	if (!keys_held(bits))
		cant_run("no buttons: no input device named in BOARD_KEYS");
	for (i = 0; i < n; i++) {
		for (k = 0; k < nb && strcmp(buttons[k].name, names[i]); k++)
			;
		if (k == nb)
			cant_run("no such button");
		all &= !!TEST(bits, buttons[k].code);
	}
	return all ? 0 : 1;
}

/* --menu: @argv is TITLE [-n NOTE | -b B-TEXT]... ITEM... */
static int menu(int argc, char **argv)
{
	const char *b_text = "back";
	char foot[128];
	int first = 1, notes = 0, sel = 0, n, code, i;

	while (first + 1 < argc && (!strcmp(argv[first], "-n") || !strcmp(argv[first], "-b"))) {
		if (argv[first][1] == 'b')
			b_text = argv[first + 1];
		else
			notes++;
		first += 2;
	}
	snprintf(foot, sizeof(foot), "D-pad: choose   A: select   B: %s", b_text);
	n = argc - first;
	if (n < 1)
		cant_run("--menu needs at least one item");
	open_inputs();
	for (;;) {
		begin_titled(GREEN, argv[0]);
		for (i = 1; i < first; i += 2)
			if (argv[i][1] == 'n')
				wrapped(YELLOW, argv[i + 1]);
		if (notes)
			row++;
		for (i = 0; i < n; i++) {
			if (i == sel)
				fill_row(SELECTED);
			line(WHITE, "%c %s", i == sel ? '>' : ' ', argv[first + i]);
		}
		/* Above the footer: the caller powers off when status gives up (IDLE). */
		row = var.yres / CELL_H - 2;
		line(GREY, "Turns off after %d minutes without a button press", IDLE_MS / 60000);
		footer(foot);
		show_frame();

		code = next_press();
		if (code == BTN_DPAD_UP)
			sel = (sel + n - 1) % n;
		else if (code == BTN_DPAD_DOWN)
			sel = (sel + 1) % n;
		else if (code == BUTTON_A)
			break;
		else if (code == BUTTON_B)
			return 1;
	}
	/* The choice stays on screen until the caller shows something else. */
	begin_titled(GREEN, argv[0]);
	line(WHITE, "%s...", argv[first + sel]);
	show_frame();
	printf("%d\n", sel);
	return 0;
}

#define MAX_STEPS	8	/* --task lists steps 1 to MAX_STEPS; later ones aren't shown */
#define BAR_W		32	/* --task's progress bar, in characters */

/* What --task has read so far. */
static struct {
	char log[512], steps[MAX_STEPS][64], end[512], hint[512];
	char other[512];	/* the last line that isn't a progress line (e.g. a crash message) */
	int step, nsteps;
	int result;		/* -1 while running, then 0 (DONE) or 1 (FAIL) */
	double done;		/* the step's progress (0-1); below 0 until it reports any */
} t = { .result = -1 };

/* Take in one line of crystaline-install's output. FAIL lines are "FAIL <message>\t<hint>"; TASK
 * lines say nothing worth showing. */
static void task_line(const char *s)
{
	int i, n, at = 0;

	if (!strncmp(s, "LOG-FILE ", 9)) {
		const char *path = s + 9, *card = "/card/";	/* the initramfs's mount of the SD card */

		if (!strncmp(path, card, strlen(card)))
			snprintf(t.log, sizeof(t.log), "Log: %s on the SD card", path + strlen(card));
		else
			snprintf(t.log, sizeof(t.log), "Log: %s", path);
	} else if (sscanf(s, "STEP %d/%d %n", &i, &n, &at) == 2 && at) {
		if (i >= 1 && i <= MAX_STEPS)
			snprintf(t.steps[i - 1], sizeof(t.steps[0]), "%s", s + at);
		t.step = i;
		t.nsteps = n;
		t.done = -1;
	} else if (!strncmp(s, "PROGRESS ", 9)) {
		t.done = atof(s + 9);
	} else if (!strncmp(s, "DONE ", 5)) {
		snprintf(t.end, sizeof(t.end), "%s", s + 5);
		t.result = 0;
	} else if (!strncmp(s, "FAIL ", 5)) {
		n = strcspn(s + 5, "\t");
		snprintf(t.end, sizeof(t.end), "%.*s", n, s + 5);
		snprintf(t.hint, sizeof(t.hint), "%s", s[5 + n] ? s + 6 + n : "");
		t.result = 1;
	} else if (strncmp(s, "TASK ", 5) && s[0]) {
		snprintf(t.other, sizeof(t.other), "%s", s);
	}
}

static void draw_task(const char *title)
{
	char bar[BAR_W + 1];
	int k, w;

	begin_titled(GREEN, title);
	for (k = 1; k <= t.step && k <= MAX_STEPS; k++) {
		int finished = k < t.step || t.result == 0, failed = k == t.step && t.result == 1;

		line(failed ? RED : finished ? GREY : WHITE, "Step %d of %d: %s%s", k, t.nsteps,
		     t.steps[k - 1], finished ? "  done" : "");
		if (k == t.step && t.result < 0 && t.done >= 0) {
			w = t.done > 1 ? BAR_W : (int)(t.done * BAR_W);
			memset(bar, 0xdb, w);			/* the font's full block */
			memset(bar + w, 0xb0, BAR_W - w);	/* and its light shade */
			bar[BAR_W] = 0;
			line(WHITE, "  %s %3.0f%%", bar, t.done * 100);
		}
	}
	row++;
	if (t.result >= 0) {
		wrapped(t.result ? RED : GREEN, t.end);
		wrapped(WHITE, t.hint);
		row++;
	}
	wrapped(GREY, t.log);
	footer(t.result < 0 ? "Working: don't turn the device off" : "A: continue");
	show_frame();
}

/* --task: shows the task until it ends, then waits for A. The buttons are opened only once it
 * has ended, so presses made while it ran don't count, and a missing button device can't make
 * status exit mid-task: crystaline-install, writing into status's input, would then be killed by
 * SIGPIPE. For the same reason main() checks the framebuffer before anything is read. */
static int task(const char *title)
{
	char s[512];

	draw_task(title);
	while (t.result < 0 && fgets(s, sizeof(s), stdin)) {
		s[strcspn(s, "\n")] = 0;
		task_line(s);
		draw_task(title);
	}
	if (t.result < 0) {
		snprintf(t.end, sizeof(t.end), "It stopped without saying whether it worked.");
		snprintf(t.hint, sizeof(t.hint), "%s", t.other);
		t.result = 1;
		draw_task(title);
	}
	open_inputs();
	while (next_press() != BUTTON_A)
		;
	return t.result;
}

int main(int argc, char **argv)
{
	struct fb_fix_screeninfo fix;
	int i;

	if (argc > 2 && !strcmp(argv[1], "--held"))	/* needs no framebuffer */
		return held(argc - 2, argv + 2);
	fb_fd = open("/dev/fb0", O_RDWR);
	if (fb_fd < 0 || ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) < 0 ||
	    ioctl(fb_fd, FBIOGET_FSCREENINFO, &fix) < 0 || var.bits_per_pixel != 32 ||
	    var.yres_virtual < 2 * var.yres)
		cant_run("needs a 32-bit /dev/fb0 with two pages");
	stride = fix.line_length / 4;
	fb = mmap(NULL, (size_t)fix.line_length * var.yres * 2, PROT_READ | PROT_WRITE, MAP_SHARED,
		  fb_fd, 0);
	if (fb == MAP_FAILED)
		cant_run("can't map /dev/fb0");
	console_off();
	set_backlight();
	if (argc > 2 && !strcmp(argv[1], "--message")) {
		show_message(argv + 2, argc - 2);
		return 0;
	}
	if (argc > 2 && !strcmp(argv[1], "--menu"))
		return menu(argc - 2, argv + 2);
	if (argc > 2 && !strcmp(argv[1], "--task"))
		return task(argv[2]);
	if (argc > 2 && !strcmp(argv[1], "--banner")) {
		banner = argv + 2;
		nbanner = argc - 2;
	} else if (argc > 1) {
		cant_run("usage: status [--banner TITLE [[-d] LINE]... | --message TITLE [[-d] LINE]... | "
			 "--held BUTTON... | --menu TITLE [-n NOTE | -b B-TEXT]... ITEM... | --task TITLE]");
	}
	board_name = board("BOARD_NAME");
	battery = board("BOARD_BATTERY");
	charger = board("BOARD_CHARGER");
	open_inputs();

	for (;;) {
		draw();
		if (poll(inputs, ninputs, REFRESH_MS) <= 0)
			continue;
		for (i = 0; i < ninputs; i++) {
			struct input_event ev;

			while (read(inputs[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				if (ev.type != EV_KEY || ev.code != KEY_POWER || ev.value != 1 ||
				    just_woke())
					continue;
				sleep_now();
			}
		}
	}
}
