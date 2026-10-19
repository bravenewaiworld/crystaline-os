#!/bin/sh
# Make the development keys in build/ssh-host-keys (all of them, not only SSH host keys), if
# they don't exist yet (kept across rebuilds, and across `make clean`):
# - the SSH host keys every development system uses (so the PC doesn't warn about a changed host
#   key) and the login key root accepts (ssh -o IdentitiesOnly=yes -i build/ssh-host-keys/dev_key
#   root@<address>);
# - the update key (update_key.pem), which signs update files for development systems; they
#   trust its public half (update_key.pub, installed as /etc/brick/update-keys/dev.pub).
# Used by build-system.sh, update-device.sh and `make update-file`.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
KEYS=$ROOT/build/ssh-host-keys
mkdir -p "$KEYS"
for t in rsa ecdsa ed25519; do
	[ -f "$KEYS/ssh_host_${t}_key" ] || ssh-keygen -q -N '' -t $t -f "$KEYS/ssh_host_${t}_key"
done
[ -f "$KEYS/dev_key" ] || ssh-keygen -q -N '' -t ed25519 -C brick-dev -f "$KEYS/dev_key"
[ -f "$KEYS/update_key.pem" ] || (umask 077 && openssl genpkey -algorithm ed25519 -out "$KEYS/update_key.pem")
[ -f "$KEYS/update_key.pub" ] ||
	"$ROOT/tools/system/sign-update.sh" --public-key "$KEYS/update_key.pem" >"$KEYS/update_key.pub"
