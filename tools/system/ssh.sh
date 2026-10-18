# Sourced by the development scripts: SSH to the Brick, as root with the development key.
# BRICK: its address (default 192.168.7.2, the USB network link; or its WiFi address).
BRICK=${BRICK:-192.168.7.2}
KEY=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/build/ssh-host-keys/dev_key
# IdentitiesOnly: offer only this key. Keys from an SSH agent are otherwise offered first, and the
# Brick drops the connection after a few rejected ones ("Too many authentication failures").
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5"
on_brick() { ssh $SSH_OPTS root@$BRICK "$@"; }
to_brick() { scp -q $SSH_OPTS "$@"; }	# to_brick FILE... root@$BRICK:DEST
