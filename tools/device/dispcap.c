// SPDX-License-Identifier: GPL-2.0
/*
 * dispcap: save what the display engine sends to the panel, for consecutive frames, as PPM files.
 * It uses the engine's write-back unit (the DISP_CAPTURE_* ioctls of Allwinner's display driver,
 * disp2, on /dev/disp), so a capture shows exactly the scanned-out picture: the layers after
 * scaling, and any tearing, which a copy of a framebuffer would not show.
 * Usage: dispcap [-n COUNT] [-s WIDTHxHEIGHT] OUT
 *   COUNT consecutive frames (default 1), scaled by the engine to WIDTHxHEIGHT (default the
 *   screen's size), written to OUT.ppm, or OUT-0.ppm, OUT-1.ppm, ... when COUNT > 1.
 * The engine writes the frames into fb0's memory past the buffers in use (fb0's virtual height),
 * so they must fit there. fb0's memory holds its buffers at the screen's size, so nothing fits
 * while fb0 is laid out at that size (the frontend's layout); while it is 640x480, as during a
 * game, one full-size frame fits.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* ioctl numbers and argument layouts from the kernel's include/video/sunxi_display2.h; the driver always
 * copies 4 arguments, args[0] = screen 0. */
#define DISP_GET_SCN_WIDTH	0x07
#define DISP_GET_SCN_HEIGHT	0x08
#define DISP_CAPTURE_START	0x140
#define DISP_CAPTURE_STOP	0x141
#define DISP_CAPTURE_COMMIT	0x142	/* args: screen, struct disp_capture_info * */
#define DISP_FORMAT_ARGB_8888	0x00

struct disp_rect { int x, y; unsigned int width, height; };
struct disp_rectsz { unsigned int width, height; };
struct disp_s_frame {
	int format;
	struct disp_rectsz size[3];
	struct disp_rect crop;
	unsigned long long addr[3];
};
struct disp_capture_info {
	struct disp_rect window;	/* all zero: the whole screen */
	struct disp_s_frame out_frame;
};

/* Each frame's memory is filled with this first; a frame still holding it wasn't captured. */
#define UNWRITTEN 0x55

static void usage(const char *name)
{
	fprintf(stderr, "usage: %s [-n COUNT] [-s WIDTHxHEIGHT] OUT\n", name);
	exit(2);
}

static int save_ppm(const char *path, const uint8_t *argb, unsigned int w, unsigned int h)
{
	FILE *f = fopen(path, "wb");
	uint8_t *row = malloc(w * 3);
	unsigned int x, y;

	if (!f || !row) {
		perror(path);
		return -1;
	}
	fprintf(f, "P6\n%u %u\n255\n", w, h);
	for (y = 0; y < h; y++) {
		/* little-endian ARGB words: bytes B, G, R, A */
		for (x = 0; x < w; x++) {
			row[x * 3] = argb[(y * w + x) * 4 + 2];
			row[x * 3 + 1] = argb[(y * w + x) * 4 + 1];
			row[x * 3 + 2] = argb[(y * w + x) * 4];
		}
		fwrite(row, 1, w * 3, f);
	}
	free(row);
	if (fclose(f)) {
		perror(path);
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	unsigned long args[4] = { 0 };
	unsigned int count = 1, w = 0, h = 0, i;
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	unsigned long first, size;
	const char *out;
	uint8_t *mem;
	int disp, fb, opt, failed = 0;

	while ((opt = getopt(argc, argv, "n:s:")) != -1) {
		if (opt == 'n')
			count = strtoul(optarg, NULL, 0);
		else if (opt == 's' && sscanf(optarg, "%ux%u", &w, &h) == 2)
			;
		else
			usage(argv[0]);
	}
	if (optind != argc - 1 || count < 1)
		usage(argv[0]);
	out = argv[optind];

	disp = open("/dev/disp", O_RDWR);
	fb = open("/dev/fb0", O_RDWR);
	if (disp < 0 || fb < 0) {
		perror(disp < 0 ? "/dev/disp" : "/dev/fb0");
		return 1;
	}
	if (!w) {
		int sw = ioctl(disp, DISP_GET_SCN_WIDTH, args), sh = ioctl(disp, DISP_GET_SCN_HEIGHT, args);

		if (sw <= 0 || sh <= 0) {
			fprintf(stderr, "dispcap: the display driver gives no screen size (%d x %d); pass -s\n", sw, sh);
			return 1;
		}
		w = sw;
		h = sh;
	}
	if (ioctl(fb, FBIOGET_VSCREENINFO, &var) || ioctl(fb, FBIOGET_FSCREENINFO, &fix)) {
		perror("fb0 screen info");
		return 1;
	}
	size = (unsigned long)w * h * 4;
	first = ((unsigned long)var.yres_virtual * fix.line_length + 4095) & ~4095ul;
	if (first + count * size > fix.smem_len) {
		fprintf(stderr, "dispcap: fb0 has %lu KiB free past its buffers (%ux%u, virtual height %u); "
			"%u frame(s) of %ux%u need %lu KiB. Use fewer frames, a smaller -s, or lay fb0 out smaller "
			"while no GPU program runs (fbset -g W H W VIRTUAL_H 32).\n", fix.smem_len > first ? (fix.smem_len - first) / 1024 : 0,
			var.xres, var.yres, var.yres_virtual, count, w, h, count * size / 1024);
		return 1;
	}
	mem = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb, 0);
	if (mem == MAP_FAILED) {
		perror("mmap fb0");
		return 1;
	}
	memset(mem + first, UNWRITTEN, count * size);

	if (ioctl(disp, DISP_CAPTURE_START, args) < 0) {
		perror("DISP_CAPTURE_START");
		return 1;
	}
	/* One request per frame: the driver starts one at each vblank, in order. */
	for (i = 0; i < count; i++) {
		struct disp_capture_info info;
		int p;

		memset(&info, 0, sizeof(info));
		info.out_frame.format = DISP_FORMAT_ARGB_8888;
		for (p = 0; p < 3; p++)
			info.out_frame.size[p] = (struct disp_rectsz){ w, h };
		info.out_frame.crop = (struct disp_rect){ 0, 0, w, h };
		info.out_frame.addr[0] = fix.smem_start + first + i * size;
		args[1] = (unsigned long)&info;
		if (ioctl(disp, DISP_CAPTURE_COMMIT, args) < 0) {
			perror("DISP_CAPTURE_COMMIT");
			count = i;
			failed = 1;
			break;
		}
	}
	/* A request is set up at one vblank, captured in the next frame and done at the vblank
	 * after: count frames and a margin. */
	for (i = 0; i < count + 3; i++) {
		uint32_t zero = 0;

		if (ioctl(fb, FBIO_WAITFORVSYNC, &zero) < 0 && errno != ETIMEDOUT)
			usleep(17000);	/* no vsync wait available: about a refresh instead */
	}
	args[1] = 0;
	ioctl(disp, DISP_CAPTURE_STOP, args);

	for (i = 0; i < count; i++) {
		const uint8_t *frame = mem + first + i * size;
		char path[4096];
		int k, untouched = 1;

		/* The engine writes top to bottom: an unwritten end means not captured or cut short. */
		for (k = 0; k < 64 && untouched; k++)
			untouched = frame[size - 1 - k] == UNWRITTEN;
		if (untouched) {
			fprintf(stderr, "dispcap: frame %u was not captured, or not completely (is the display on?)\n", i);
			failed = 1;
			continue;
		}
		if (count == 1)
			snprintf(path, sizeof(path), "%s.ppm", out);
		else
			snprintf(path, sizeof(path), "%s-%u.ppm", out, i);
		if (save_ppm(path, frame, w, h))
			failed = 1;
	}
	return failed;
}
