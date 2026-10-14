#!/bin/sh
# Build the libretro cores Specular runs (sources: see env.sh): mGBA, for GB, GBC and GBA.
# Usage: build-cores.sh [host]
#   Without arguments, for the Brick (aarch64, the cross compiler in env.sh), into build/cores/aarch64.
#   With "host", for this PC (to try games in the desktop build), into build/cores/host.
# Each core's sources are copied to build/cores/<target>/src (without .git), our fixes in
# tools/core-patches/<core> are applied to the copy, and it is built in build/cores/<target>/build,
# so the sources stay clean.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
if [ "${1:-}" = host ]; then
	TARGET=host CC=cc CXX=c++ CMAKE_CROSS= CFLAGS=
else
	TARGET=aarch64 CC=${CROSS_COMPILE}gcc CXX=${CROSS_COMPILE}g++
	CMAKE_CROSS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64"
	CFLAGS=-mcpu=cortex-a53
fi
OUT=$ROOT/build/cores/$TARGET
mkdir -p "$OUT/build"

# Copies core $1's sources from $2 to $OUT/src/$1 and applies its patches. rsync first puts back
# the original of every file an earlier run patched, so each patch applies cleanly every time;
# files it leaves alone keep their times, so rebuilds stay incremental.
patched_src() {
	mkdir -p "$OUT/src/$1"
	rsync -a --delete --exclude=.git "$2/" "$OUT/src/$1/"
	for p in "$ROOT/tools/core-patches/$1"/*.patch; do
		[ -e "$p" ] || continue	# no patches: the pattern stays unexpanded
		# The ceiling stops git from taking the copy for part of this repository (it is under
		# build/), where git apply skips every file of the patch without an error.
		(cd "$OUT/src/$1" && GIT_CEILING_DIRECTORIES="$OUT/src" git apply "$p")
	done
}

# mGBA: CMake, with everything but the libretro core switched off (no GUI, no optional libraries).
patched_src mgba "$MGBA_SRC"
mkdir -p "$OUT/build/mgba"
(cd "$OUT/build/mgba" && cmake "$OUT/src/mgba" -DCMAKE_BUILD_TYPE=Release $CMAKE_CROSS \
	-DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_C_FLAGS="$CFLAGS" \
	-DBUILD_LIBRETRO=ON -DSKIP_LIBRARY=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF \
	-DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DENABLE_SCRIPTING=OFF -DUSE_DEBUGGERS=OFF -DUSE_GDB_STUB=OFF \
	-DUSE_FFMPEG=OFF -DUSE_ZLIB=OFF -DUSE_PNG=OFF -DUSE_LIBZIP=OFF -DUSE_MINIZIP=OFF -DUSE_SQLITE3=OFF -DUSE_ELF=OFF \
	-DUSE_LZMA=OFF -DUSE_EPOXY=OFF -DUSE_DISCORD_RPC=OFF -DUSE_EDITLINE=OFF -DUSE_LUA=OFF -DUSE_JSON_C=OFF >/dev/null \
	&& make -j"$(nproc)" mgba_libretro >/dev/null)
cp "$OUT/build/mgba/mgba_libretro.so" "$OUT/"

ls -l "$OUT"/*.so
