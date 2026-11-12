#!/bin/sh
# Fetch the third-party inputs (tools/env.sh says what each is for) into third-party/, each pinned
# and checked: downloads by SHA-256, parts of git repositories by their tree ID (git's hash of a
# directory's files, which can be worked out from the files alone, without git's history). An input
# that is already there is checked and kept. One that differs from its pin is reported and left
# alone; remove it and run again. Only the paths env.sh uses by default are fetched and checked, not
# paths set from the environment.
# Usage: fetch-third-party.sh [--check]     --check: check the inputs that are there, fetch nothing
# TRIMUI_FW_URL (from the environment): where to download TrimUI's firmware from. It has no stable
# download address, so without it the file must be put in place by hand (it is checked either way).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/third-party
CHECK=0
case ${1:-} in --check) CHECK=1 ;; '') ;; *) echo "usage: $0 [--check]" >&2; exit 2 ;; esac
FAILED=0

sha256() { sha256sum <"$1" | cut -d' ' -f1; }

# verdict NAME GOT WANT [WHAT-NOW]: report whether input NAME matches its pin.
verdict() {
	if [ "$2" = "$3" ]; then echo "ok       $1"
	else echo "DIFFERS  $1: is ${2:-unknown (error above)}, pinned $3; ${4:-remove it and run again}" >&2; FAILED=1; fi
}

# missing NAME: report a missing input in --check mode. Returns 0 if it should be fetched.
missing() {
	[ $CHECK = 1 ] || return 0
	echo "missing  $1"
	return 1
}

# tree_id DIR: git's tree ID of the files under DIR (leaving out .git), without needing a git
# repository of them: the files are hashed into a throw-away index, not stored. Line-ending
# conversion is off, so the user's git settings can't change the result.
tree_id() {
	g=$T/.tree-id
	rm -rf "$g"
	git init -q --bare "$g"
	(cd "$1" && export GIT_DIR="$g" GIT_WORK_TREE=. GIT_INDEX_FILE="$g/index" &&
		git ls-files -z -o | git -c core.autocrlf=false update-index -z --add --info-only --stdin &&
		git write-tree --missing-ok)
	rm -rf "$g"
}

# download NAME URL SHA256: the file at URL, as third-party/NAME. With an empty URL, a missing file
# is reported, not fetched.
download() {
	f=$T/$1
	if [ -e "$f" ]; then verdict "$1" "$(sha256 "$f")" "$3"; return; fi
	missing "$1" || return 0
	[ -n "$2" ] || { echo "MISSING  $1: no address to download it from (see $0)" >&2; FAILED=1; return; }
	echo "fetch    $1"
	mkdir -p "$(dirname "$f")"
	curl -sSfL -o "$f.part" "$2"
	sum=$(sha256 "$f.part")
	if [ "$sum" = "$3" ]; then mv "$f.part" "$f"
	else rm "$f.part"; verdict "$1" "$sum" "$3" "not kept"; fi
}

# git_source NAME URL COMMIT PATH TREE: directory PATH (. for all) of the git repository at URL, at
# COMMIT, as third-party/NAME; TREE is PATH's tree ID at COMMIT. Only PATH's files (and those
# directly in the directories above it) are downloaded.
git_source() {
	d=$T/$1
	if [ -e "$d" ]; then verdict "$1" "$(tree_id "$d")" "$5"; return; fi
	missing "$1" || return 0
	echo "fetch    $1"
	tmp=$T/.fetch-$1	# in third-party/, so the result moves into place without a copy
	rm -rf "$tmp"
	git init -q "$tmp"
	git -C "$tmp" remote add origin "$2"
	git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$3"
	src=$tmp
	[ "$4" = . ] || { git -C "$tmp" sparse-checkout set "$4"; src=$tmp/$4; }
	git -C "$tmp" checkout -q FETCH_HEAD
	got=$(tree_id "$src")
	if [ "$got" = "$5" ]; then mv "$src" "$d"; else verdict "$1" "$got" "$5" "not kept"; fi
	rm -rf "$tmp"
}

git_source sonic-pad-toolchain https://github.com/CrealityTech/sonic_pad_os.git \
	7f37a7fbf4ad59907034715e3d967b9177de1cd4 prebuilt/gcc/linux-x86/aarch64/toolchain-sunxi-glibc \
	47693a0161e02b402250084ec61096131870c762
git_source gpu-km-tsp https://github.com/pocketforge-os/gpu-km-tsp.git \
	fbb38f3f712a9b151f7482450bafd939b8269ae8 . 07036e416a7556bde03b16432f8d841ffa8ab0d3
git_source mali-kbase https://github.com/rocknix/mali_kbase.git \
	39da994bb6fc8819e5e8c1873907dd21d17e53c1 product/kernel 69cd175a8405fa06545af962eb5c3e6654f160e2
download trimui-firmware-v1.1.1/trimui_tg3040.awimg "${TRIMUI_FW_URL:-}" \
	d9189936b941c39160cd33f2993c1f3ab0e3648f87b203fb6290ec835f2f8d98
# The mainline boards' loader sources (tools/env.sh, UBOOT_SRC, TFA_SRC, TFA_DTC_SRC). TF-A's tree ID
# leaves out its submodules (empty folders here); the one it builds with, contrib/dtc, is fetched on
# its own as dtc-8f48565e, at the commit TF-A names.
git_source u-boot-v2026.10 https://github.com/u-boot/u-boot.git \
	5508406582f6f7120dce0c4b3059819a41788db2 . c54aa18f1c43c1b8b292434cc74cdc11e002f851
git_source tf-a-d70b52de https://github.com/ARM-software/arm-trusted-firmware.git \
	d70b52dedc4eba74386098a9033eec1e9cb522fa . 339024a923a49b4a1a87c7e7b41e52c4c084569d
git_source dtc-8f48565e https://github.com/dgibson/dtc.git \
	8f48565e5cfedc74d3f7512f1e0188e9d85dc1de . bf074fb822c6c54a969f93dfdcd2abc4c8910ebc
# Rockchip's RK3566 binaries (tools/env.sh, RK3566_DDR, RK3566_BL31), each at the rkbin commit that
# added it.
RKBIN=https://raw.githubusercontent.com/rockchip-linux/rkbin
download rkbin/rk3566_ddr_1056MHz_v1.23.bin \
	$RKBIN/fd73dcf27702e1efc2065055215320adeaadee84/bin/rk35/rk3566_ddr_1056MHz_v1.23.bin \
	20e4bb076847bd019fcdeb7bdc15bd249890f07ecc76e9937101f22e50950982
download rkbin/rk3568_bl31_v1.45.elf \
	$RKBIN/ef49d0c2852b16ce0d72d7ee4849638cb5de27b7/bin/rk35/rk3568_bl31_v1.45.elf \
	76634f10e535bbe981fb9132fd6815a71586cc1b96aae1159bec6797579e5b9f
# The RTL8723DS's Bluetooth firmware (the RGB20 Pro's), which linux-firmware doesn't carry: Armbian's
# firmware collection (tools/env.sh, RTL8723DS_BT).
RTL_BT=https://raw.githubusercontent.com/armbian/firmware/bf5f7a802b8e1998e6bf95daed5ea965441af83d/rtl_bt
download rtl8723ds-bt/rtl8723ds_fw.bin $RTL_BT/rtl8723ds_fw.bin \
	19c1bed7a9359b1a021c20f81b525bdebf5067f9021716991d94be9101f76e63
download rtl8723ds-bt/rtl8723ds_config.bin $RTL_BT/rtl8723ds_config.bin \
	7d1e18df7654da8f6382520841bb535f2d1246fc8495e3ae652f7b23e820168d

DUFS_TAR=dufs-v0.46.0/dufs-v0.46.0-aarch64-unknown-linux-musl.tar.gz
download $DUFS_TAR https://github.com/sigoden/dufs/releases/download/v0.46.0/${DUFS_TAR#*/} \
	1472123ae3aa07e49404d16b20305c2dec90c59883ebda9308717f7205e6511b
# The build uses the binary, unpacked from the archive (which holds only it). The binary has its own
# pin, so one unpacked from an archive that differs is reported too.
DUFS=dufs-v0.46.0/dufs
if [ ! -e "$T/$DUFS" ] && [ -e "$T/$DUFS_TAR" ] && missing $DUFS; then
	tar -xzf "$T/$DUFS_TAR" -C "$T/dufs-v0.46.0" dufs
fi
[ ! -e "$T/$DUFS" ] || verdict $DUFS "$(sha256 "$T/$DUFS")" \
	5753d125dedb51bc4194e491de7d9081d7a1914a62c1fb4390d68ae55620334b "remove it and $DUFS_TAR, and run again"
exit $FAILED
