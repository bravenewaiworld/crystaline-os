#!/bin/sh
# Make the development SSH keys in build/ssh-host-keys, if they don't exist yet: the host keys
# every development system uses (kept across rebuilds, and across `make clean`, so the PC doesn't
# warn about a changed host key) and the login key root accepts (ssh -i build/ssh-host-keys/dev_key
# root@<address>). Used by build-system.sh and the test card's build.
set -eu
KEYS=$(cd "$(dirname "$0")/../.." && pwd)/build/ssh-host-keys
mkdir -p "$KEYS"
for t in rsa ecdsa ed25519; do
	[ -f "$KEYS/ssh_host_${t}_key" ] || ssh-keygen -q -N '' -t $t -f "$KEYS/ssh_host_${t}_key"
done
[ -f "$KEYS/dev_key" ] || ssh-keygen -q -N '' -t ed25519 -C brick-dev -f "$KEYS/dev_key"
