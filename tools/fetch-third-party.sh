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
download trimui-firmware-v1.1.1/trimui_tg3040.awimg "${TRIMUI_FW_URL:-}" \
	d9189936b941c39160cd33f2993c1f3ab0e3648f87b203fb6290ec835f2f8d98

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
