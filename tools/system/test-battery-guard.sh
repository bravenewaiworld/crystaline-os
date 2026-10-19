#!/bin/bash
# Tests the low-battery guard (system/board/brick/rootfs-overlay/usr/libexec/brick/battery-guard)
# on the development PC: its decisions over sequences of samples (through `battery-guard replay`,
# which takes samples as the service logs them), that its log of them replays to the same
# decisions, its reading of a fake battery (`state`), and the service loop against a fake empty
# battery in a dry run. With BusyBox on the PATH (make test-battery-guard builds the device's,
# tools/system/pc-busybox.sh), the guard runs under BusyBox's shell and tools, as on the device;
# without it, under the PC's. Prints PASS or the first failure.
# Usage: test-battery-guard.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GUARD=$ROOT/system/board/brick/rootfs-overlay/usr/libexec/brick/battery-guard
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

if command -v busybox >/dev/null; then
	SH="busybox sh"
	mkdir $T/bb
	for a in cat sleep; do ln -s "$(command -v busybox)" $T/bb/$a; done
	PATH=$T/bb:$PATH
else
	echo "no BusyBox on the PATH: testing with the PC's shell and tools" >&2
	SH=sh
fi

# replay NAME POWERS_OFF(yes|no) SAMPLE...: the guard must decide to power off (or not) for the
# samples, given as "capacity µV µA status".
replay() {
	local name=$1 want=$2 out got again; shift 2
	out=$(printf 'sample %s\n' "$@" | $SH "$GUARD" replay)
	if grep -q '^battery empty: powering off' <<<"$out"; then got=yes; else got=no; fi
	[ $got = "$want" ] || fail "$name: powers off: $got, expected $want; output:"$'\n'"$out"
	# The service's log of these samples (its "sample" lines) must replay to the same decision.
	again=$(printf '%s\n' "$out" | $SH "$GUARD" replay)
	if grep -q '^battery empty: powering off' <<<"$again"; then got=yes; else got=no; fi
	[ $got = "$want" ] || fail "$name: the log replays to powers off: $got, expected $want; log:"$'\n'"$out"
	echo "$out"
}
# expect NAME TEXT OUTPUT: OUTPUT must contain the line TEXT (a grep pattern) exactly once.
expect() { [ "$(grep -c -- "$2" <<<"$3")" = 1 ] || fail "$1: expected one line \"$2\" in:"$'\n'"$3"; }

replay "discharge" yes "3 3720000 0 Discharging" "2 3700000 0 Discharging" \
	"1 3660000 0 Discharging" "1 3640000 0 Discharging" >/dev/null
out=$(replay "power-off logs the last samples" yes "1 3660000 0 Discharging" "1 3640000 0 Discharging")
expect "power-off log" 'last samples: .*1 3660000 0 Discharging | 1 3640000 0 Discharging$' "$out"
replay "one empty sample" no "1 3660000 0 Discharging" "2 3700000 0 Discharging" \
	"1 3650000 0 Discharging" >/dev/null
out=$(replay "confused gauge (0-1 % at a high voltage)" no "1 3950000 0 Discharging" \
	"0 3950000 0 Discharging" "1 3940000 0 Discharging")
expect "confused gauge logged once" 'not acting' "$out"
replay "voltage dip under load" no "40 3280000 0 Discharging" "40 3500000 0 Discharging" \
	"40 3290000 0 Discharging" >/dev/null
replay "gauge reading too high: the voltage floor" yes "40 3290000 0 Discharging" \
	"39 3280000 0 Discharging" >/dev/null
replay "at the voltage floor exactly" yes "40 3300000 0 Discharging" "40 3300000 0 Discharging" >/dev/null
replay "charging cancels" no "1 3600000 0 Discharging" "1 3650000 300000 Charging" \
	"1 3600000 0 Discharging" >/dev/null
replay "charging, under the floor" no "1 3200000 300000 Charging" "1 3250000 300000 Charging" >/dev/null
replay "unplugged after charging" yes "1 3650000 300000 Charging" "1 3600000 0 Discharging" \
	"1 3590000 0 Discharging" >/dev/null
replay "a cable that can't keep up (status Charging, no charge current)" yes \
	"1 3600000 0 Charging" "1 3590000 0 Charging" >/dev/null
out=$(replay "no battery" no absent absent absent)
expect "no battery logged once" '^absent$' "$out"
out=$(replay "read errors" no "error cat: x: Input/output error" "error cat: x: Input/output error" \
	"error cat: x: Input/output error" "error cat: x: Input/output error" \
	"error cat: x: Input/output error" "error cat: x: Input/output error" "50 3900000 0 Discharging")
expect "first read error" "^can't read the battery: cat: x" "$out"
expect "fifth read error" "^error: can't read the battery 5 times in a row" "$out"
expect "readable again" '^battery readable again$' "$out"
replay "a read error between empty samples" no "1 3600000 0 Discharging" \
	"error cat: x: Input/output error" "1 3600000 0 Discharging" >/dev/null
out=$(replay "low samples are logged, and the first after them" no "50 3900000 0 Discharging" \
	"9 3750000 0 Discharging" "10 3750000 0 Discharging" "11 3760000 0 Discharging")
[ "$(grep -c '^sample ' <<<"$out")" = 2 ] || fail "logged samples:"$'\n'"$out"
# Log lines as logread prints them replay too.
out=$(printf '%s\n' "Oct 18 21:00:00 brick user.notice battery-guard: sample 1 3600000 0 Discharging" \
	"Oct 18 21:00:30 brick user.notice battery-guard: sample 1 3600000 0 Discharging" \
	"Oct 18 21:00:31 brick user.notice frontend: unrelated" | $SH "$GUARD" replay)
expect "replay of logread lines" '^battery empty: powering off' "$out"

# A fake battery directory; battery FILE VALUE writes one of its files.
B=$T/psu/axp2202-battery
mkdir -p "$B"
battery() { echo "$2" >"$B/$1"; }
state() { PSU=$T/psu $SH "$GUARD" state; }
battery present 1; battery capacity 54; battery voltage_now 3920000; battery current_now 0
battery status Discharging
[ "$(state)" = "ok 54 % 3.92 V, charge 0 mA, Discharging" ] || fail "state: $(state)"
battery status "Not charging"
[ "$(state)" = "ok 54 % 3.92 V, charge 0 mA, Not charging" ] || fail "state with a two-word status: $(state)"
battery capacity 1; battery voltage_now 3600000; battery current_now 450000; battery status Charging
[ "$(state)" = "charging 1 % 3.60 V, charge 450 mA, Charging" ] || fail "state charging: $(state)"
battery current_now 0
[ "$(state)" = "empty 1 % 3.60 V, charge 0 mA, Charging" ] || fail "state empty: $(state)"
battery voltage_now ""
[[ "$(state)" == "error voltage_now reads \"\""* ]] || fail "state with an empty reading: $(state)"
rm "$B/voltage_now"
[[ "$(state)" == "error "* ]] || fail "state with a missing file: $(state)"
battery present 0
[ "$(state)" = absent ] || fail "state without a battery: $(state)"

# The service loop, dry run, against the empty battery: it must decide to power off.
battery present 1; battery voltage_now 3600000
out=$(PSU=$T/psu DRY_RUN=1 INTERVAL=0 timeout 5 $SH "$GUARD" | grep -m1 '^dry run' || true)
expect "service loop" '^dry run: not powering off$' "$out"

echo PASS
