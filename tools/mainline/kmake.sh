#!/bin/sh
# Run make for the mainline family's kernel (linux-mainline/) in the build folder OUT.
# One kernel serves every board of the family, so its configuration is merged, every time, from
# system/family/mainline/kernel.config, then each mainline board's SoC part
# (system/soc/<soc>/kernel.config, once per SoC) and its own part (system/board/<board>/
# kernel.config). Those files are the only place to change it; an unchanged result rebuilds nothing.
# merge_config.sh prints a warning for each value a later part overrides, and kconfig.log lists the
# values asked for that the result doesn't have (an unmet dependency, or a name Kconfig doesn't know).
# Usage: kmake.sh OUT [make targets]   (default: Image dtbs modules)
# CROSS_COMPILE: default Buildroot's compiler for the family (make DEVICE=<board> buildroot first).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$1
shift
SRC=$ROOT/linux-mainline
: "${CROSS_COMPILE:=$ROOT/build/mainline/buildroot/host/bin/aarch64-buildroot-linux-gnu-}"
export ARCH=arm64 CROSS_COMPILE

# The parts, in merge order.
parts=$ROOT/system/family/mainline/kernel.config
socs=
for mk in "$ROOT"/system/board/*/board.mk; do
	grep -qx 'FAMILY := mainline' "$mk" || continue
	soc=$(sed -n 's/^SOC := //p' "$mk")
	case " $socs " in *" $soc "*) ;; *) socs="$socs $soc" parts="$parts $ROOT/system/soc/$soc/kernel.config" ;; esac
done
for mk in "$ROOT"/system/board/*/board.mk; do
	grep -qx 'FAMILY := mainline' "$mk" || continue
	parts="$parts ${mk%/board.mk}/kernel.config"
done

mkdir -p "$OUT"
# merge_config.sh runs make alldefconfig from the source folder, with the output in OUT.
(cd "$SRC" && scripts/kconfig/merge_config.sh -O "$OUT" $parts) >"$OUT/kconfig.log" 2>&1 ||
	{ cat "$OUT/kconfig.log" >&2; exit 1; }
grep -A2 -e '^Value requested for' -e 'Value of .* is redefined' "$OUT/kconfig.log" >&2 || true
[ $# -gt 0 ] || set -- Image dtbs modules
make -C "$SRC" O="$OUT" -j"$(nproc)" "$@"
