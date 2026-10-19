#!/bin/sh
# Make an update file (userspace/brick-install/src/update.rs says what checks it) from one version
# of the system (build-system.sh's output): a ustar tar of manifest.json, manifest.sig (an Ed25519
# signature over manifest.json, 64 bytes), boot.img and rootfs.squashfs, in that order, with fixed
# owners, modes and dates, so the same version and key always give the same file.
# A -dirty version (built with uncommitted changes) is signed only with this checkout's
# development key (build/ssh-host-keys/update_key.pem, made by dev-keys.sh).
# Usage: sign-update.sh <version dir> <key.pem> <out file>
#        sign-update.sh --public-key <key.pem>   prints the key's public half as brick-install
#                                                reads it (64 hex characters)
set -eu
# The raw public key is the last 32 bytes of its DER form.
public() { openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n'; echo; }
[ "$1" = --public-key ] && { public "$2"; exit; }
V=$(readlink -f "$1") KEY=$2 OUT=$3
DEV_KEY=$(cd "$(dirname "$0")/../.." && pwd)/build/ssh-host-keys/update_key.pem
VERSION=$(basename "$V")
case $VERSION in *-dirty)
	[ -f "$DEV_KEY" ] && [ "$(public "$KEY")" = "$(public "$DEV_KEY")" ] ||
		{ echo "refusing to sign $VERSION (uncommitted changes) with a key other than the development key" >&2; exit 1; } ;;
esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$V/manifest.json" -out "$T/manifest.sig"
mkdir -p "$(dirname "$OUT")"
tar --format=ustar --owner=0 --group=0 --numeric-owner --mode=644 --mtime=@0 -cf "$OUT.tmp" \
	-C "$V" manifest.json -C "$T" manifest.sig -C "$V" boot.img rootfs.squashfs
mv "$OUT.tmp" "$OUT"
echo "$OUT"
