// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * xr829-attach: starts the Bluetooth side of the Brick's XR829 chip and hands it to the kernel's
 * Bluetooth stack, as hci0. The protocol follows Xradio's hciattach_xradio.c (Copyright (C) 2018
 * Xradio Technology Co., Ltd., GPL-2.0-or-later), as used by BlueZ's hciattach on Allwinner's
 * systems; this is our own rewrite of it.
 *
 * The chip's Bluetooth side starts in a boot ROM on serial port ttyS1 and has no address of its
 * own. Start-up:
 *   1. power-cycle it (its rfkill switch "sunxi-bt"), assert its wake pin, turn the kernel's
 *      Bluetooth sleep handling (LPM) off
 *   2. boot ROM, 115200 baud, no flow control: sync (send 0x55 until it answers "OK"), switch
 *      to 1.5 Mbaud, sync again, upload FIRMWARE, jump to it
 *   3. firmware, 115200 baud with RTS/CTS: HCI Reset, switch to 1.5 Mbaud (vendor command), set the
 *      address (vendor command; a second HCI Reset makes the controller use it), log the
 *      controller's version
 *   4. attach: hand the port to the kernel's HCI UART driver (line discipline N_HCI, H4 framing),
 *      which creates hci0, and stay running until SIGTERM, SIGINT or SIGHUP; then detach (back
 *      to N_TTY), which removes hci0. The port's settings are never touched after attaching: the
 *      controller stays at 1.5 Mbaud with flow control.
 * Steps 1-2 get up to BOOT_TRIES tries in all, each retry after a longer power-off; a failure
 * from step 3 on isn't retried: it exits. Every read has a timeout, and the whole start-up is bounded by
 * ATTACH_TIMEOUT_S.
 *
 * Address: ADDR_FILE if it holds a valid one (a unit that already has an address keeps it, and
 * with it its pairings), else derived from the SoC's chip ID like the WiFi MAC address (see
 * derive_address) and saved there.
 *
 * Logs one line per step to stderr; on failure, one line saying which step failed and why, then
 * exits 1, so its runit service (/etc/sv/xr829-attach) starts it again.
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* The PC test (tools/system/test-xr829-attach.sh) builds with every path under a fake root. */
#ifndef TEST_ROOT
#define TEST_ROOT	""
#endif
#define PORT		TEST_ROOT "/dev/ttyS1"
#define FIRMWARE	TEST_ROOT "/lib/firmware/fw_xr829_bt.bin"
#define ADDR_FILE	TEST_ROOT "/var/state/bluetooth/xr_bt.conf"
/* The SoC's one-time-programmable fuses, read-only; their first 16 bytes are the chip ID, as the
 * kernel's sunxi_get_soc_chipid() returns it. */
#define CHIP_ID_FILE	TEST_ROOT "/sys/bus/nvmem/devices/sunxi-sid0/nvmem"
#define RFKILLS		TEST_ROOT "/sys/class/rfkill/rfkill*/name"
#define RFKILL_NAME	"sunxi-bt"
/* The kernel's Xradio Bluetooth sleep driver (xradio_btlpm.c): btwake 1 drives the chip's wake
 * pin active; lpm 0 keeps the driver from putting the chip to sleep. */
#define BT_WAKE		TEST_ROOT "/proc/bluetooth/sleep/btwake"
#define BT_LPM		TEST_ROOT "/proc/bluetooth/sleep/lpm"

#define ATTACH_TIMEOUT_S	20
#define BOOT_TRIES		3
#define SYNC_TRIES		16
#define SYNC_MS			20	/* wait for the boot ROM's answer to each sync byte */
#define REPLY_MS		500	/* wait for a boot ROM reply or an HCI event */
#define CHUNK			1024	/* firmware upload chunk, as the vendor sends it */
#define FAST_BAUD		1500000
#define STR(x)			STR_(x)
#define STR_(x)			#x

/* From the kernel's drivers/bluetooth/hci_uart.h (not exported to userspace). */
#define N_HCI		15
#define HCIUARTSETPROTO	_IOW('U', 200, int)	/* the protocol is passed by value */
#define HCI_UART_H4	0

/* Boot ROM commands: write to memory, set the baud rate, jump to an address. Header flags;
 * CHECKED: the header carries a checksum. */
enum { BROM_SEQWR = 0x09, BROM_SETUART = 0x10, BROM_SETPC = 0x13 };
enum { BROM_ERROR = 1 << 0, BROM_ACK = 1 << 1, BROM_CHECKED = 1 << 2 };

/* HCI over H4: packet types, events and the commands we send (0xfcxx: Xradio's own). */
enum { H4_COMMAND = 0x01, H4_EVENT = 0x04 };
enum { EV_COMMAND_COMPLETE = 0x0e, EV_COMMAND_STATUS = 0x0f };
enum { HCI_RESET = 0x0c03, HCI_READ_VERSION = 0x1001, XR_SET_BAUD = 0xfc18, XR_SET_ADDR = 0xfc0a };

/* What is being done, for the failure message; on_timeout prints it too. */
static const char *step = "start";

/* One log line. fail() logs "<step>: <message>" and evaluates to -1, for `return fail(...)`. */
#define say(fmt, ...)	fprintf(stderr, "xr829-attach: " fmt "\n", ##__VA_ARGS__)
#define fail(fmt, ...)	(say("%s: " fmt, step, ##__VA_ARGS__), -1)

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

static void on_timeout(int sig)
{
	static const char msg[] = "xr829-attach: gave up: not attached within "
				  STR(ATTACH_TIMEOUT_S) " s; last step: ";

	(void)sig;
	write(2, msg, sizeof(msg) - 1);
	write(2, step, strlen(step));
	write(2, "\n", 1);
	_exit(1);
}

/* Bytes as hex, for error messages; the result lasts until the next call. */
static const char *hex(const uint8_t *p, ssize_t n)
{
	static char s[3 * 32 + 1];
	ssize_t i;

	s[0] = 0;
	for (i = 0; i < n && i < 32; i++)
		sprintf(s + 3 * i, " %02x", p[i]);
	return s[0] ? s + 1 : s;
}

/* Read up to `size` bytes of a file; -1 (with errno) if it can't be opened or read. */
static ssize_t read_file(const char *path, void *buf, size_t size)
{
	int fd = open(path, O_RDONLY);
	ssize_t n = fd >= 0 ? read(fd, buf, size) : -1;

	if (fd >= 0)
		close(fd);
	return n;
}

static int write_file(const char *path, const char *text)
{
	int fd = open(path, O_WRONLY);
	int ok = fd >= 0 && write(fd, text, strlen(text)) == (ssize_t)strlen(text);

	if (fd >= 0)
		close(fd);
	return ok ? 0 : fail("write %s: %m", path);
}

/* --- Address ---------------------------------------------------------------------------------
 * a[0] is the most significant byte, as stored in ADDR_FILE and logged; the set-address command
 * takes them the other way round. */

/* Not all zero, and the LAP (the low three bytes) not one of the inquiry access codes
 * 9e8b00-9e8b3f, which Bluetooth reserves. */
static int valid_address(const uint8_t a[6])
{
	return memcmp(a, (uint8_t[6]){ 0 }, 6) && !(a[3] == 0x9e && a[4] == 0x8b && a[5] < 0x40);
}

/*
 * The WiFi driver's method (xradio_chipid_macaddr() in the kernel submodule, commit 1c92aa495),
 * salted 'B' instead of 'W': FNV-1a over the 16-byte chip ID and the salt, the low 48 bits,
 * marked as a locally administered unicast address. The two addresses always differ, but as only
 * the last byte hashed differs, they share most of their bytes.
 */
static int derive_address(uint8_t a[6])
{
	uint64_t h = 0xcbf29ce484222325ULL;
	uint8_t id[17];
	ssize_t n = read_file(CHIP_ID_FILE, id, 16);
	int i;

	if (n != 16)
		return fail("read the chip ID from " CHIP_ID_FILE ": %s",
			    n < 0 ? strerror(errno) : "too short");
	if (!memcmp(id, (uint8_t[16]){ 0 }, 16))
		return fail("the chip ID in " CHIP_ID_FILE " is all zero");
	id[16] = 'B';
	for (i = 0; i < 17; i++)
		h = (h ^ id[i]) * 0x100000001b3ULL;
	for (i = 0; i < 6; i++)
		a[i] = h >> (40 - 8 * i);
	a[0] = (a[0] & ~0x01) | 0x02;
	if (!valid_address(a))
		a[5] |= 0x40;	/* out of the reserved range; about 1 chip in 260 000 */
	return 0;
}

/* ADDR_FILE: "%02x " per byte, most significant first, nothing else: 18 characters with a
 * trailing space. TrimUI's stock hciattach wrote the same format. */
static int parse_address(const char *s, ssize_t len, uint8_t a[6])
{
	int i;

	if (len != 18)
		return -1;
	for (i = 0; i < 6; i++, s += 3) {
		if (!isxdigit((unsigned char)s[0]) || !isxdigit((unsigned char)s[1]) || s[2] != ' ')
			return -1;
		a[i] = strtol((char[]){ s[0], s[1], 0 }, NULL, 16);
	}
	return valid_address(a) ? 0 : -1;
}

/* Write ADDR_FILE atomically. A failure is only a warning: the derived address is the same
 * next time. */
static void save_address(const uint8_t a[6])
{
	FILE *f = fopen(ADDR_FILE ".new", "w");
	int bad = !f || fprintf(f, "%02x %02x %02x %02x %02x %02x ", a[0], a[1], a[2], a[3], a[4],
				a[5]) < 0 || fflush(f) || fsync(fileno(f));

	if ((f && fclose(f)) || bad || rename(ADDR_FILE ".new", ADDR_FILE))
		say("warning: could not save the address to " ADDR_FILE ": %m");
}

static int get_address(uint8_t a[6])
{
	char text[32] = "";
	ssize_t n = read_file(ADDR_FILE, text, sizeof(text) - 1);
	const char *from = ADDR_FILE;

	step = "address";
	if (n < 0 && errno != ENOENT)
		return fail("read " ADDR_FILE ": %m");
	if (parse_address(text, n, a)) {
		if (n >= 0)
			say("warning: " ADDR_FILE " holds no valid address (\"%s\"): replacing it",
			    text);
		if (derive_address(a) < 0)
			return -1;
		save_address(a);
		from = "the chip ID";
	}
	say("address %02x:%02x:%02x:%02x:%02x:%02x, from %s", a[0], a[1], a[2], a[3], a[4], a[5],
	    from);
	return 0;
}

/* --- Serial port ----------------------------------------------------------------------------- */

static int set_port(int fd, speed_t speed, int flow_control)
{
	struct termios t;

	if (tcgetattr(fd, &t) < 0)
		return fail("get port settings: %m");
	cfmakeraw(&t);
	if (flow_control)
		t.c_cflag |= CRTSCTS;
	else
		t.c_cflag &= ~CRTSCTS;
	cfsetspeed(&t, speed);
	if (tcsetattr(fd, TCSANOW, &t) < 0)
		return fail("set port settings: %m");
	return 0;
}

/* Blocking: with flow control on, a controller that never lets data through is caught by the
 * ATTACH_TIMEOUT_S alarm. */
static int write_all(int fd, const uint8_t *p, size_t n)
{
	return write(fd, p, n) == (ssize_t)n ? 0 : fail("write: %m");
}

/* Read n bytes, waiting at most ms; returns how many arrived (fewer on a time-out or error). */
static ssize_t read_upto(int fd, uint8_t *p, size_t n, int ms)
{
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	long end = now_ms() + ms, left;
	size_t done = 0;
	ssize_t r;

	while (done < n && (left = end - now_ms()) > 0 && poll(&pfd, 1, left) > 0 &&
	       (r = read(fd, p + done, n - done)) > 0)
		done += r;
	return done;
}

/* --- Boot ROM -------------------------------------------------------------------------------- */

/* The sum of the 16-bit little-endian words; an odd last byte counts as a word's low byte. */
static uint16_t sum16(const uint8_t *p, size_t n)
{
	uint16_t s = 0;
	size_t i;

	for (i = 0; i + 1 < n; i += 2)
		s += p[i] | p[i + 1] << 8;
	if (n & 1)
		s += p[n - 1];
	return s;
}

/* Store v as `size` bytes, in either byte order. */
static void put(uint8_t *p, uint32_t v, int size, int big_endian)
{
	int i;

	for (i = 0; i < size; i++)
		p[big_endian ? size - 1 - i : i] = v >> (8 * i);
}

/* "KO" is also accepted: the read started mid-answer, with the K of one "OK" and the O of the
 * next. */
static int brom_sync(int fd)
{
	int i;

	for (i = 0; i < SYNC_TRIES; i++) {
		uint8_t r[2];

		if (write_all(fd, (uint8_t[]){ 0x55 }, 1) < 0)
			return -1;
		if (read_upto(fd, r, 2, SYNC_MS) == 2 && (!memcmp(r, "OK", 2) || !memcmp(r, "KO", 2)))
			return 0;
	}
	return fail("no answer to %d sync bytes", SYNC_TRIES);
}

/* A reply is a header (see brom_command) with the ack flag and no payload, or with the error flag
 * and a 1-byte error code. */
static int brom_reply(int fd)
{
	static const char *const errors[] = { "?", "unknown command", "timed out", "bad checksum",
					      "invalid", "out of memory" };
	uint8_t h[13];
	ssize_t n = read_upto(fd, h, 12, REPLY_MS);

	if (n != 12 || memcmp(h, "BROM", 4))
		return fail("bad reply (%zd bytes: %s)", n, hex(h, n));
	if (h[4] & BROM_ERROR) {
		int e = read_upto(fd, h + 12, 1, REPLY_MS) == 1 ? h[12] : -1;

		return fail("boot ROM error %d (%s)", e,
			    e >= 0 && e < (int)(sizeof(errors) / sizeof(errors[0])) ? errors[e] : "?");
	}
	/* The checksum arrives big-endian; in little-endian order, the header sums to 0xffff. */
	put(h + 6, h[6] << 8 | h[7], 2, 0);
	if (!(h[4] & BROM_ACK) || memcmp(h + 8, (uint8_t[4]){ 0 }, 4) ||
	    ((h[4] & BROM_CHECKED) && sum16(h, 12) != 0xffff))
		return fail("bad reply (%s)", hex(h, 12));
	return 0;
}

/*
 * Send a command and wait for its reply. A command is a 12-byte header: "BROM", [4] flags,
 * [5] version 0, [6-7] checksum, [8-11] payload length; then the payload: the command byte and
 * `n` numbers of size[i] bytes. All numbers go out big-endian, but the checksum (the bitwise NOT
 * of sum16 over header and payload) is computed over their little-endian form, with the checksum
 * field 0.
 */
static int brom_command(int fd, uint8_t command, const uint32_t *value, const int *size, int n)
{
	uint8_t c[32] = { 'B', 'R', 'O', 'M', BROM_CHECKED, 0, 0, 0, 0, 0, 0, 0, command };
	uint16_t sum = 0;
	int len, i, big;

	for (big = 0; big <= 1; big++) {	/* little-endian for the checksum, then big */
		for (i = 0, len = 13; i < n; len += size[i++])
			put(c + len, value[i], size[i], big);
		put(c + 8, len - 12, 4, big);
		if (!big)
			sum = ~sum16(c, len);
		put(c + 6, sum, 2, big);
	}
	tcflush(fd, TCIFLUSH);
	return write_all(fd, c, len) < 0 ? -1 : brom_reply(fd);
}

/* Each chunk is a SEQWR command (address, length, ~sum16 of the data), then the data; the boot
 * ROM replies to both. */
static int upload_firmware(int fd)
{
	static char chunk_step[48];	/* `step` points here */
	uint8_t data[CHUNK];
	uint32_t addr = 0;
	long start = now_ms();
	int fw = open(FIRMWARE, O_RDONLY), n;

	step = "firmware upload";
	if (fw < 0)
		return fail("open " FIRMWARE ": %m");
	while ((n = read(fw, data, CHUNK)) > 0) {
		uint32_t field[3] = { addr, n, (uint16_t)~sum16(data, n) };

		snprintf(chunk_step, sizeof(chunk_step), "firmware upload at byte %u", addr);
		step = chunk_step;
		if (brom_command(fd, BROM_SEQWR, field, (int[]){ 4, 4, 2 }, 3) < 0 ||
		    write_all(fd, data, n) < 0 || brom_reply(fd) < 0)
			break;
		addr += n;
	}
	close(fw);
	if (n > 0)
		return -1;	/* a chunk failed, already logged */
	if (n < 0 || !addr)
		return fail("read " FIRMWARE ": %s", n < 0 ? strerror(errno) : "empty");
	say("firmware: %u bytes uploaded in %ld ms", addr, now_ms() - start);
	return 0;
}

static int boot(int fd)
{
	step = "boot ROM sync at 115200 baud";
	if (set_port(fd, B115200, 0) < 0 || brom_sync(fd) < 0)
		return -1;
	/* Top byte 3: the line settings, as the vendor sends them (presumably 8 data bits). */
	step = "boot ROM switch to 1.5 Mbaud";
	if (brom_command(fd, BROM_SETUART, (uint32_t[]){ FAST_BAUD | 3 << 24 }, (int[]){ 4 }, 1) < 0)
		return -1;
	step = "boot ROM sync at 1.5 Mbaud";
	if (set_port(fd, B1500000, 0) < 0 || brom_sync(fd) < 0 || upload_firmware(fd) < 0)
		return -1;
	step = "start the firmware";
	return brom_command(fd, BROM_SETPC, (uint32_t[]){ 0 }, (int[]){ 4 }, 1);
}

/* --- Power ----------------------------------------------------------------------------------- */

static char rfkill_state[256];	/* the state file of the chip's rfkill switch */

static int find_rfkill(void)
{
	glob_t g;
	size_t i;

	step = "power";
	if (glob(RFKILLS, 0, NULL, &g))
		return fail("no rfkill switches");
	for (i = 0; i < g.gl_pathc && !rfkill_state[0]; i++) {
		char name[32] = "";
		const char *path = g.gl_pathv[i];

		if (read_file(path, name, sizeof(name) - 1) >= 0 && !strcmp(name, RFKILL_NAME "\n"))
			snprintf(rfkill_state, sizeof(rfkill_state), "%.*sstate",
				 (int)strlen(path) - 4, path);	/* .../name -> .../state */
	}
	globfree(&g);
	return rfkill_state[0] ? 0 : fail("no rfkill switch named \"" RFKILL_NAME "\"");
}

/* Power the chip's Bluetooth side off for off_ms and on again, which starts its boot ROM; then
 * assert its wake pin and turn LPM off (see BT_WAKE). The other pauses are the vendor's. */
static int power_up(long off_ms)
{
	step = "power";
	if (write_file(rfkill_state, "0") < 0)
		return -1;
	usleep(off_ms * 1000);
	if (write_file(rfkill_state, "1") < 0)
		return -1;
	usleep(20000);
	if (write_file(BT_WAKE, "1") < 0 || write_file(BT_LPM, "0") < 0)
		return -1;
	usleep(5000);
	return 0;
}

/* --- HCI ------------------------------------------------------------------------------------- */

/* Send an HCI command (as step `what`) and wait for its Command Complete event; copies up to `len`
 * bytes of its return parameters (after the status) to `ret`. Other events are logged and
 * skipped. */
static int hci_command(int fd, const char *what, uint16_t opcode, const uint8_t *param,
		       uint8_t plen, uint8_t *ret, size_t len)
{
	uint8_t c[4 + 255] = { H4_COMMAND, opcode, opcode >> 8, plen }, e[3 + 255];

	step = what;
	if (plen)
		memcpy(c + 4, param, plen);
	tcflush(fd, TCIFLUSH);
	if (write_all(fd, c, 4 + plen) < 0)
		return -1;
	for (;;) {
		ssize_t n = read_upto(fd, e, 3, REPLY_MS);	/* type, event, length */

		if (n == 3 && e[0] == H4_EVENT)
			n += read_upto(fd, e + 3, e[2], REPLY_MS);
		if (n < 3 || e[0] != H4_EVENT || n != 3 + e[2])
			return fail("bad reply (%zd bytes: %s)", n, hex(e, n));
		/* Command Status: status, credits, opcode. For our opcode with a non-zero status, the
		 * controller refused the command. */
		if (e[1] == EV_COMMAND_STATUS && n >= 7 && (e[5] | e[6] << 8) == opcode && e[3])
			return fail("command 0x%04x refused: status 0x%02x", opcode, e[3]);
		/* Command Complete: credits, opcode, status, return parameters. */
		if (e[1] != EV_COMMAND_COMPLETE || n < 7 || (e[4] | e[5] << 8) != opcode) {
			say("%s: skipped HCI event %s", step, hex(e, n));
			continue;
		}
		if (e[6])
			return fail("command 0x%04x failed: status 0x%02x", opcode, e[6]);
		if (ret)
			memcpy(ret, e + 7, len < (size_t)n - 7 ? len : (size_t)n - 7);
		return 0;
	}
}

/* v: the return parameters of HCI Read Local Version Information. */
static void log_version(const uint8_t v[8])
{
	static const char *const names[] = { "1.0b", "1.1", "1.2", "2.0", "2.1", "3.0", "4.0",
					     "4.1", "4.2", "5.0", "5.1", "5.2", "5.3", "5.4",
					     "6.0" };

	say("controller: Bluetooth %s (HCI version %d, revision 0x%04x), LMP version %d, "
	    "subversion 0x%04x, manufacturer 0x%04x",
	    v[0] < sizeof(names) / sizeof(names[0]) ? names[v[0]] : "?", v[0], v[1] | v[2] << 8,
	    v[3], v[6] | v[7] << 8, v[4] | v[5] << 8);
}

static int start_hci(int fd, const uint8_t a[6])
{
	uint8_t baud[4], version[8] = { 0 };
	/* Xradio's set-address parameters: 02 00 06, then the address. */
	uint8_t set_addr[9] = { 0x02, 0x00, 0x06, a[5], a[4], a[3], a[2], a[1], a[0] };

	put(baud, FAST_BAUD, 4, 0);
	/* The vendor's pauses for the firmware to start (5 ms + 20 ms). */
	usleep(5000);
	step = "firmware start-up";
	if (set_port(fd, B115200, 1) < 0)
		return -1;
	usleep(20000);
	if (hci_command(fd, "HCI reset", HCI_RESET, NULL, 0, NULL, 0) < 0 ||
	    hci_command(fd, "HCI switch to 1.5 Mbaud", XR_SET_BAUD, baud, 4, NULL, 0) < 0 ||
	    set_port(fd, B1500000, 1) < 0)
		return -1;
	usleep(100000);	/* the vendor's pause after the switch */
	if (hci_command(fd, "set the address", XR_SET_ADDR, set_addr, 9, NULL, 0) < 0 ||
	    hci_command(fd, "HCI reset after setting the address", HCI_RESET, NULL, 0, NULL, 0) < 0 ||
	    hci_command(fd, "read the controller's version", HCI_READ_VERSION, NULL, 0, version, 8) < 0)
		return -1;
	log_version(version);
	step = "attach";
	if (ioctl(fd, TIOCSETD, &(int){ N_HCI }) < 0)
		return fail("set line discipline N_HCI: %m");
	if (ioctl(fd, HCIUARTSETPROTO, HCI_UART_H4) < 0)
		return fail("set protocol H4: %m");
	return 0;
}

int main(void)
{
	long start = now_ms();
	sigset_t stops;
	uint8_t addr[6];
	int fd, try, sig;

	signal(SIGALRM, on_timeout);
	alarm(ATTACH_TIMEOUT_S);
	if (get_address(addr) < 0 || find_rfkill() < 0)
		return 1;
	fd = open(PORT, O_RDWR | O_NOCTTY);
	if (fd < 0) {
		say("open " PORT ": %m");
		return 1;
	}
	for (try = 1; ; try++) {
		/* The first power-off is short; retries use the vendor's 500 ms for a boot ROM that
		 * didn't answer. */
		if (power_up(try == 1 ? 20 : 500) < 0)
			return 1;
		if (boot(fd) == 0)
			break;
		if (try == BOOT_TRIES)
			return 1;
		say("power-cycling and starting again (try %d of %d)", try + 1, BOOT_TRIES);
	}
	if (start_hci(fd, addr) < 0)
		return 1;
	alarm(0);
	say("attached in %ld ms", now_ms() - start);

	sigemptyset(&stops);
	sigaddset(&stops, SIGTERM);
	sigaddset(&stops, SIGINT);
	sigaddset(&stops, SIGHUP);
	sigprocmask(SIG_BLOCK, &stops, NULL);
	sigwait(&stops, &sig);
	if (ioctl(fd, TIOCSETD, &(int){ N_TTY }) < 0) {
		say("detach: %m");
		return 1;
	}
	say("detached (signal %d)", sig);
	return 0;
}
