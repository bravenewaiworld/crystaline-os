#!/bin/sh
# Run make for the mainline family's kernel (linux-mainline/) in the build folder OUT.
# One kernel serves every board of the family, so its configuration is merged, every time, from
# system/family/mainline/kernel.config, then the part of each SoC the family's boards use
# (system/soc/<soc>/kernel.config) and each board's own (system/board/<board>/kernel.config).
# Those files are the only place to change it; an unchanged result rebuilds nothing.
# merge_config.sh prints a warning for each value a later part overrides, and kconfig.log lists the
# values asked for that the result doesn't have (an unmet dependency, or a name Kconfig doesn't know).
# Usage: kmake.sh OUT [make targets]   (default: Image dtbs modules)
# Builds with Buildroot's compiler for the family (make DEVICE=<a mainline board, e.g. rgb20pro>
# buildroot first); MAINLINE_CROSS_COMPILE overrides it. (CROSS_COMPILE from the environment is
# ignored: tools/env.sh sets it to the Brick's compiler.)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$1
shift
SRC=$ROOT/linux-mainline
export ARCH=arm64 \
	CROSS_COMPILE=${MAINLINE_CROSS_COMPILE:-$ROOT/build/mainline/buildroot/host/bin/aarch64-buildroot-linux-gnu-}

boards=$("$ROOT/tools/system/family-boards.sh" mainline)
socs=$(for b in $boards; do sed -n 's/^SOC := //p' "$ROOT/system/board/$b/board.mk"; done | sort -u)
parts=$ROOT/system/family/mainline/kernel.config
for s in $socs; do parts="$parts $ROOT/system/soc/$s/kernel.config"; done
for b in $boards; do parts="$parts $ROOT/system/board/$b/kernel.config"; done

mkdir -p "$OUT"
# merge_config.sh runs make alldefconfig from the source folder, with the output in OUT.
(cd "$SRC" && scripts/kconfig/merge_config.sh -O "$OUT" $parts) >"$OUT/kconfig.log" 2>&1 ||
	{ cat "$OUT/kconfig.log" >&2; exit 1; }
grep -A2 -e '^Value requested for' -e 'Value of .* is redefined' "$OUT/kconfig.log" >&2 || true
[ $# -gt 0 ] || set -- Image dtbs modules
make -C "$SRC" O="$OUT" -j"$(nproc)" "$@"
