# Sourced by the development scripts: SSH to the device, as root with the development key.
# ADDR: the device's address (USB link or WiFi). The Makefile sets it from the board's BOARD_USB_NET;
# run directly, it defaults to 192.168.7.2 (the Brick's USB link).
ADDR=${ADDR:-192.168.7.2}
KEY=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/build/ssh-host-keys/dev_key
# IdentitiesOnly: offer only this key. Keys from an SSH agent are otherwise offered first, and the
# Brick drops the connection after a few rejected ones ("Too many authentication failures").
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5"
on_device() { ssh $SSH_OPTS root@$ADDR "$@"; }
to_device() { scp -q $SSH_OPTS "$@"; }	# to_device FILE... root@$ADDR:DEST
