#!/bin/bash
# Builds BusyBox for the development PC, from the source and configuration Buildroot built the
# device's BusyBox with, so scripts can be tested on the PC with the device's shell and tools.
# Prints the directory holding the `busybox` program, or prints nothing (and says why on stderr)
# when Buildroot hasn't built BusyBox yet; the tests then use the PC's own shell and tools.
# Rebuilds only when Buildroot's BusyBox configuration has changed.
# Usage: pc-busybox.sh OUT_DIR
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?usage: pc-busybox.sh OUT_DIR}
SRC=$(ls -d "$ROOT"/build/buildroot/build/busybox-[0-9]*/ 2>/dev/null | tail -1 || true)	# ls fails when nothing matches
[ -n "$SRC" ] && [ -f "$SRC/.config" ] ||
	{ echo "pc-busybox: Buildroot hasn't built BusyBox yet (make buildroot)" >&2; exit 0; }

if ! cmp -s "$SRC/.config" "$OUT/buildroot.config" || [ ! -x "$OUT/busybox" ]; then
	echo "pc-busybox: building BusyBox for the PC in $OUT" >&2
	rm -rf "$OUT" && mkdir -p "$OUT"
	# A copy, cleaned: Buildroot built in the source directory, which BusyBox's out-of-tree
	# builds refuse.
	cp -a "$SRC" "$OUT/src"
	make -C "$OUT/src" clean >/dev/null
	# The device's configuration, for the PC's compiler, linked dynamically. tc is left out: it
	# doesn't build against newer kernel headers, and no script of ours uses it.
	sed -e 's/^CONFIG_CROSS_COMPILER_PREFIX=.*/CONFIG_CROSS_COMPILER_PREFIX=""/' \
		-e 's/^CONFIG_SYSROOT=.*/CONFIG_SYSROOT=""/' \
		-e 's/^CONFIG_EXTRA_CFLAGS=.*/CONFIG_EXTRA_CFLAGS=""/' \
		-e 's/^CONFIG_EXTRA_LDFLAGS=.*/CONFIG_EXTRA_LDFLAGS=""/' \
		-e 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' \
		-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "$SRC/.config" >"$OUT/src/.config"
	{ yes "" || true; } | make -C "$OUT/src" oldconfig >/dev/null 2>&1	# (yes ends on SIGPIPE)
	make -C "$OUT/src" -j"$(nproc)" busybox >"$OUT/build.log" 2>&1 ||
		{ echo "pc-busybox: build failed, see $OUT/build.log" >&2; exit 1; }
	cp "$OUT/src/busybox" "$OUT/busybox"
	cp "$SRC/.config" "$OUT/buildroot.config"
	rm -rf "$OUT/src"
fi
echo "$OUT"
