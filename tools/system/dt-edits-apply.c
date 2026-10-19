/*
 * The kernel's built-in device-tree edits (linux/drivers/of/fdt_edits.c), on the PC: applies them to
 * a tree as the kernel does at boot and writes what the kernel would use, which is what
 * /sys/firmware/fdt shows on the device. Prints the kernel's dt-edits log lines (without the
 * kernel's "booting the bootloader's device tree unchanged" on a failure).
 * Built by tools/system/build-dt-edits-apply.sh, with fdt_edits.c, a generated table and the kernel's libfdt.
 * Usage: dt-edits-apply <in.dtb> <out.dtb>
 * Exit: 0 edited; 1 the edits failed (out is the input plus the failure in /chosen); 2 nothing written.
 */
#include <stdio.h>
#include "fdt_edits.h"

static void note(const struct fdt_edit *e, const char *what)
{
	printf("dt-edits: %s %s %s (set before the kernel started)\n", what, e->path, e->name);
}

int main(int argc, char **argv)
{
	static char in[2 << 20], out[sizeof(in) + FDT_EDITS_ROOM];	/* 2 MiB: arm64's limit too */
	struct fdt_edits_result res;
	size_t n;
	FILE *f;
	int err;

	if (argc != 3) {
		fprintf(stderr, "usage: %s <in.dtb> <out.dtb>\n", argv[0]);
		return 2;
	}
	f = fopen(argv[1], "rb");
	n = f ? fread(in, 1, sizeof(in), f) : 0;
	if (!n || n == sizeof(in) || fdt_check_header(in) || fdt_totalsize(in) > n) {
		fprintf(stderr, "%s: not a device tree of under 2 MiB\n", argv[1]);
		return 2;
	}
	fclose(f);

	err = fdt_edits_copy_and_apply(in, out, &res, note);
	if (err) {
		printf("dt-edits %s: FAILED to copy the device tree or record the outcome: %s\n",
		       fdt_edits_id, fdt_strerror(err));
		return 2;
	}
	printf("dt-edits: %s\n", res.status);
	f = fopen(argv[2], "wb");
	if (!f || fwrite(out, 1, fdt_totalsize(out), f) != fdt_totalsize(out) || fclose(f)) {
		perror(argv[2]);
		return 2;
	}
	return res.error ? 1 : 0;
}
