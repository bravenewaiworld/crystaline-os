#!/bin/sh
# Build a mainline board's loader: what its SoC's boot ROM reads from the card, which starts the
# kernel from extlinux.conf. For the RK3566 that is Rockchip's DDR init (closed), U-Boot's SPL, BL31
# (open TF-A unless RK3566_BL31 names another) and U-Boot, packed by U-Boot as u-boot-rockchip.bin
# and written at sector 64 (tools/mainline/build-card.sh).
# Sources come from tools/env.sh and are copied into OUT, so third-party/ stays as fetched and every
# build starts clean. The board adds its U-Boot files from system/board/<board>/u-boot/: *_defconfig
# go to U-Boot's configs/, *.dtsi to arch/arm/dts/; its board.mk names the defconfig (UBOOT_DEFCONFIG).
# One checkout builds the same bytes every time: the build time recorded is its last commit's.
# Built with Buildroot's compiler for the family (make DEVICE=<board> buildroot first);
# MAINLINE_CROSS_COMPILE overrides it.
# Output: OUT/u-boot-rockchip.bin and OUT/versions.txt (what went into it), with the build logs.
# Usage: build-loader.sh <board> <out-dir>
set -eu
BOARD=$1
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tools/env.sh"
CROSS=${MAINLINE_CROSS_COMPILE:-$ROOT/build/mainline/buildroot/host/bin/aarch64-buildroot-linux-gnu-}
[ -x "${CROSS}gcc" ] || { echo "no compiler ${CROSS}gcc: make DEVICE=$BOARD buildroot first" >&2; exit 1; }
BOARD_MK=$ROOT/system/board/$BOARD/board.mk
SOC=$(sed -n 's/^SOC := //p' "$BOARD_MK")
DEFCONFIG=$(sed -n 's/^UBOOT_DEFCONFIG := //p' "$BOARD_MK")
[ -n "$DEFCONFIG" ] || { echo "$BOARD_MK names no UBOOT_DEFCONFIG" >&2; exit 1; }
case $SOC in
# TF-A's rk3568 platform covers the RK3566 (the same chip with fewer interfaces).
rk3566) TFA_PLAT=rk3568 DDR=$RK3566_DDR BL31=$RK3566_BL31 ;;
*) echo "no loader recipe for SoC $SOC ($BOARD_MK)" >&2; exit 1 ;;
esac
for f in "$UBOOT_SRC" "$DDR" ${BL31:-"$TFA_SRC" "$TFA_DTC_SRC"}; do
	[ -e "$f" ] || { echo "missing $f (tools/fetch-third-party.sh, tools/env.sh)" >&2; exit 1; }
done
export SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct)"
rm -f "$OUT/u-boot-rockchip.bin" "$OUT/versions.txt"

# run LOG CMD...: run CMD with its output in OUT/LOG, shown only if it fails.
run() {
	log=$OUT/$1; shift
	"$@" >"$log" 2>&1 || { tail -40 "$log" >&2; echo "failed; the whole log is $log" >&2; exit 1; }
}

if [ -z "$BL31" ]; then
	rm -rf "$OUT/tf-a"
	cp -a "$TFA_SRC" "$OUT/tf-a"
	rm -rf "$OUT/tf-a/contrib/dtc"
	cp -a "$TFA_DTC_SRC" "$OUT/tf-a/contrib/dtc"
	run tf-a.log make -C "$OUT/tf-a" -j"$(nproc)" CROSS_COMPILE="$CROSS" PLAT=$TFA_PLAT \
		BUILD_STRING="$(basename "$TFA_SRC")" \
		BUILD_MESSAGE_TIMESTAMP="\"$(date -u -d "@$SOURCE_DATE_EPOCH" +%FT%TZ)\"" bl31
	BL31=$OUT/tf-a/build/$TFA_PLAT/release/bl31/bl31.elf
fi

rm -rf "$OUT/u-boot"
cp -a "$UBOOT_SRC" "$OUT/u-boot"
for f in "$ROOT/system/board/$BOARD/u-boot/"*; do
	case $f in
	*_defconfig) cp "$f" "$OUT/u-boot/configs/" ;;
	*.dtsi) cp "$f" "$OUT/u-boot/arch/arm/dts/" ;;
	*) echo "$f: not a *_defconfig or *.dtsi" >&2; exit 1 ;;
	esac
done
# OPENSSL_ENGINE_STUBS: U-Boot's signing tool still calls OpenSSL's ENGINE functions, which OpenSSL 4
# (Fedora 45's) removed; the stubs let it link. We sign nothing, so they are never called.
umake() { make -C "$OUT/u-boot" CROSS_COMPILE="$CROSS" HOSTCFLAGS="-O2 -DOPENSSL_ENGINE_STUBS" "$@"; }
run u-boot-config.log umake "$DEFCONFIG"
# U-Boot's packer (binman) is Python and needs pyelftools: the build machine's Python, not
# Buildroot's (which lacks it), so Buildroot's host/bin stays out of PATH.
run u-boot.log umake -j"$(nproc)" BL31="$BL31" ROCKCHIP_TPL="$DDR"

cp "$OUT/u-boot/u-boot-rockchip.bin" "$OUT/"
sum() { sha256sum <"$1" | cut -c1-16; }
cat >"$OUT/versions.txt" <<EOF
board  $BOARD ($DEFCONFIG)
u-boot $(basename "$UBOOT_SRC")
bl31   $(case $BL31 in "$OUT"/*) basename "$TFA_SRC" ;; *) basename "$BL31" ;; esac) $(sum "$BL31")
ddr    $(basename "$DDR") $(sum "$DDR")
loader u-boot-rockchip.bin $(sum "$OUT/u-boot-rockchip.bin")
EOF
cat "$OUT/versions.txt"
