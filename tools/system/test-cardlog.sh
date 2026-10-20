#!/bin/bash
# Tests cardlog (tools/device/cardlog.c) on the PC: a PC build, with syslog() replaced by lines on
# stderr (so nothing reaches the PC's own system log), fed through a pipe, against a fake card
# state file and card folder. Covers when the card's copy is written (end of input, the interval,
# SIGHUP, SIGTERM, a full buffer), the card not being writable (nothing written, lines dropped and
# counted once the buffer is full), the move to LOG_FILE.0, and lines adding up to the buffer's size. Needs gcc.
# Prints PASS or the first failure.
# Usage: test-cardlog.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
# Stand-ins for openlog() and syslog(), linked into the test build in place of the C library's
# (__syslog_chk is what syslog() becomes in a fortified build).
cat >$T/syslog.c <<'EOF'
#include <stdarg.h>
#include <stdio.h>
void openlog(const char *tag, int o, int f) { (void)o; (void)f; fprintf(stderr, "openlog %s\n", tag); }
static void put(int pri, const char *fmt, va_list ap)
{
	fprintf(stderr, "syslog %d ", pri);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
}
void syslog(int pri, const char *fmt, ...) { va_list ap; va_start(ap, fmt); put(pri, fmt, ap); va_end(ap); }
void __syslog_chk(int pri, int flag, const char *fmt, ...)
{
	va_list ap;

	(void)flag;
	va_start(ap, fmt);
	put(pri, fmt, ap);
	va_end(ap);
}
EOF
# Fortified (level 3 checks writes at a variable offset into a buffer), so an overrun aborts.
gcc -O2 -Wall -Wextra -D_FORTIFY_SOURCE=3 -o $T/cardlog "$ROOT/tools/device/cardlog.c" $T/syslog.c

STATE=$T/state LOG=$T/card/logs/specular.log
fail() { echo "FAIL ($CASE): $*" >&2; ls -l $T/card/logs >&2 2>/dev/null || true; tail -5 $T/stderr >&2; exit 1; }
case_() { CASE=$*; echo "== $CASE"; rm -rf $T/card $T/in; mkdir $T/card; echo mounted >$STATE; }
# start [OPTION...]: runs cardlog in the background reading the pipe $T/in, held open on fd 3.
start() {
	mkfifo $T/in
	$T/cardlog "$@" frontend $STATE $LOG <$T/in 2>$T/stderr & PID=$!
	exec 3>$T/in
}
# send N: N numbered lines into the pipe.
send() { for i in $(seq $1); do echo "line $i of $1"; done >&3; }
lines() { [ -e $LOG ] && wc -l <$LOG || echo 0; }
# within SECONDS COND...: COND (a command) becomes true within SECONDS.
within() { local n=$(($1 * 10)); shift; until "$@"; do n=$((n - 1)); [ $n -gt 0 ] || return 1; sleep 0.1; done; }
has_lines() { [ "$(lines)" = $1 ]; }
some_lines() { [ "$(lines)" -gt 0 ]; }
finish() { exec 3>&-; wait $PID || fail "cardlog exited with $?"; }

case_ "1. end of input: every line to the system log and, with the time, to the card"
start
send 3; finish
has_lines 3 || fail "$(lines) lines on the card"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} line 3 of 3$' $LOG || fail "line format: $(tail -1 $LOG)"
[ "$(grep -c '^syslog 5 line' $T/stderr)" = 3 ] || fail "not every line to the system log"
grep -q '^openlog frontend$' $T/stderr || fail "wrong tag"

case_ "2. a last line without its newline is kept"
start
printf 'no newline' >&3; finish
grep -q ' no newline$' $LOG || fail "last line lost"

case_ "3. batched: written once the interval has passed, not before"
start -i 2
send 2
sleep 0.5; has_lines 0 || fail "written before the interval"
within 4 has_lines 2 || fail "not written after the interval"
finish

case_ "4. SIGHUP writes at once; SIGTERM writes and ends"
start -i 100
send 1; sleep 0.3; kill -HUP $PID
within 2 has_lines 1 || fail "SIGHUP didn't write"
send 2; sleep 0.3; kill -TERM $PID; finish
has_lines 3 || fail "SIGTERM didn't write: $(lines) lines"

case_ "5. a full buffer (64 KiB) is written without waiting"
start -i 100
send 3000	# about 70 KiB with the times
within 3 some_lines || fail "full buffer not written"
finish
has_lines 3000 || fail "$(lines) lines, expected 3000"

case_ "6. the card not writable: nothing written; lines past a full buffer dropped and counted"
echo "read-only damaged" >$STATE
start -i 100
send 3000
kill -HUP $PID; sleep 0.3
[ ! -e $LOG ] || fail "written to a read-only card"
echo mounted >$STATE
finish
grep -q '^\[cardlog: [0-9]* lines missing here' $LOG || fail "no note of the dropped lines"
n=$(sed -n 's/^\[cardlog: \([0-9]*\) .*/\1/p' $LOG)
[ $((n + $(grep -c ' line ' $LOG))) = 3000 ] || fail "$n dropped + $(grep -c ' line ' $LOG) written isn't 3000"

case_ "7. moved to .0 before growing past 512 KiB"
mkdir -p ${LOG%/*}; head -c $((510 * 1024)) /dev/zero | tr '\0' x >$LOG; echo old >$LOG.0
start
send 100; finish
[ "$(wc -c <$LOG.0)" = $((510 * 1024)) ] || fail "the old log wasn't moved to .0"
has_lines 100 || fail "$(lines) lines in the new log"

case_ "8. lines adding up to exactly the buffer's size: no overrun (the fortified build aborts at one)"
start -i 100
for i in $(seq 40); do printf "%02027d\n" $i; done >&3	# 2048 bytes each with the time
finish
has_lines 40 || fail "$(lines) lines, expected 40"

echo PASS
