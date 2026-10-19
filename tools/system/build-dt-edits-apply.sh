#!/bin/sh
# Build dt-edits-apply, the kernel's device-tree edits as a PC program: dt-edits-apply.c, the
# kernel's own fdt_edits.c and libfdt, and a table freshly made from this checkout's dt-tweaks.sh.
# Usage: build-dt-edits-apply.sh <dir>       writes <dir>/table.c and <dir>/dt-edits-apply.
#   KERNEL_SRC overrides the kernel source tree (default linux/). Needs build/stock-fw (make stock-fw).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
KSRC=${KERNEL_SRC:-$ROOT/linux}
L=$KSRC/scripts/dtc/libfdt
mkdir -p "$1"
"$ROOT/tools/system/dt-edits.sh" "$ROOT/build/stock-fw/boot_package.fex" "$1/table.c"
cc -O2 -Wall -I"$KSRC/drivers/of" -I"$L" -o "$1/dt-edits-apply" "$ROOT/tools/system/dt-edits-apply.c" \
	"$KSRC/drivers/of/fdt_edits.c" "$1/table.c" "$L/fdt.c" "$L/fdt_ro.c" "$L/fdt_rw.c" "$L/fdt_wip.c" \
	"$L/fdt_strerror.c"
