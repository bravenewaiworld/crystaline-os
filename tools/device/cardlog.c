// SPDX-License-Identifier: GPL-2.0
/*
 * cardlog: a runit log service that sends each line on stdin to the system log under TAG, and keeps
 * a copy, with the time, in LOG_FILE on the SD card, so a user can hand over the log of a problem
 * without SSH. Specular's log service (etc/sv/frontend/log/run) runs it with LOG_FILE =
 * logs/specular.log on the card.
 *   cardlog [-i SECONDS] TAG STATE_FILE LOG_FILE
 *
 * The system log, on the system partition, gets every line at once. The card's copy is batched to
 * spare the card (each write of a FAT file also rewrites its directory entry and allocation table):
 * lines are buffered and appended at most once every SECONDS (default 60), or sooner: when the
 * 64 KiB buffer is full; on SIGHUP (frontend-run sends one before each start of Specular, so the
 * last lines of a run that crashed reach the card then); and on SIGTERM or the end of input. Each write opens the file, appends, syncs and
 * closes it, so the card is never held open (it can be pulled or unmounted at any time).
 *
 * The card is written only while STATE_FILE (mount-card's /run/card/state) starts with the line
 * "mounted", i.e. mounted read-write. Until then lines stay buffered. When the buffer fills while the
 * card can't be written, everything buffered is thrown away (the system log still has it) and
 * counted; the next write to the card starts with a note giving the count.
 * LOG_FILE is moved to LOG_FILE.0 (replacing it) before it would grow past 512 KiB, so it takes at
 * most 1 MiB of the card.
 */
#define _GNU_SOURCE	/* ppoll */
#include <fcntl.h>
#include <libgen.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define BUF_SIZE	(64 * 1024)
#define MAX_LINE	4000		/* longer lines are split */
#define ROTATE_SIZE	(512 * 1024)

static char buf[BUF_SIZE];		/* lines for the card, not yet written */
static size_t used;
static long dropped;			/* lines dropped since the last write to the card */
static long interval = 60, due;		/* due: when the oldest buffered line must be written */
static const char *state_file, *log_file;
static char old_file[4096];		/* LOG_FILE.0 */
static volatile sig_atomic_t flush_now, stop;

static void on_signal(int sig)
{
	if (sig == SIGHUP)
		flush_now = 1;
	else
		stop = 1;
}

static long now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec;
}

/* Whether STATE_FILE's first line is exactly "mounted". */
static int card_writable(void)
{
	char line[32] = "";
	FILE *f = fopen(state_file, "r");

	if (!f)
		return 0;
	if (!fgets(line, sizeof(line), f))
		line[0] = 0;
	fclose(f);
	return !strcmp(line, "mounted\n");
}

static int write_all(int fd, const char *p, size_t n)
{
	while (n) {
		ssize_t w = write(fd, p, n);

		if (w <= 0)
			return -1;
		p += w;
		n -= w;
	}
	return 0;
}

/* Appends the buffer to LOG_FILE if the card can be written; empties it if written. */
static void flush(void)
{
	char note[96] = "";
	struct stat st;
	int fd, n = 0;

	if (!used || !card_writable())
		return;
	if (dropped)
		n = snprintf(note, sizeof(note), "[cardlog: %ld lines missing here: the card couldn't be written]\n",
			     dropped);
	if (stat(log_file, &st) == 0) {
		if (st.st_size + n + used > ROTATE_SIZE)
			rename(log_file, old_file);
	} else {	/* logs/: a card may not have it yet */
		char dir[sizeof(old_file)];

		snprintf(dir, sizeof(dir), "%s", log_file);
		mkdir(dirname(dir), 0777);
	}
	fd = open(log_file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0666);
	if (fd < 0 || write_all(fd, note, n) || write_all(fd, buf, used) || fsync(fd)) {
		/* Most likely the card was pulled. The lines stay buffered and the next attempt checks
		 * STATE_FILE again; lines appended before a failure mid-write are then written twice. */
		syslog(LOG_WARNING, "cardlog: can't write %s: %m", log_file);
		if (fd >= 0)
			close(fd);
		return;
	}
	close(fd);
	used = 0;
	dropped = 0;
}

/* Adds one line (without its newline) for the card, with the local time. */
static void keep(const char *line)
{
	char stamp[32];
	time_t t = time(NULL);
	size_t n;

	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S ", localtime(&t));
	n = strlen(stamp) + strlen(line) + 2;	/* with the newline and sprintf's closing NUL */
	if (used + n > sizeof(buf))
		flush();
	if (used + n > sizeof(buf)) {	/* the card still can't be written: make room */
		for (char *p = buf; p < buf + used; p++)
			dropped += *p == '\n';
		used = 0;
	}
	if (!used)
		due = now_s() + interval;
	used += sprintf(buf + used, "%s%s\n", stamp, line);
}

/* One line from stdin: to the system log, and kept for the card. */
static void emit(const char *line)
{
	syslog(LOG_NOTICE, "%s", line);
	keep(line);
}

int main(int argc, char **argv)
{
	struct sigaction sa = { .sa_handler = on_signal };
	sigset_t signals, unblocked;
	char line[MAX_LINE + 1];
	size_t len = 0;
	int opt;

	while ((opt = getopt(argc, argv, "i:")) != -1) {
		if (opt != 'i')
			goto usage;
		interval = atol(optarg);
	}
	if (argc - optind != 3)
		goto usage;
	state_file = argv[optind + 1];
	log_file = argv[optind + 2];
	snprintf(old_file, sizeof(old_file), "%s.0", log_file);
	openlog(argv[optind], 0, LOG_USER);
	/* SIGHUP and SIGTERM are blocked except inside ppoll(): one that arrives while a line is being
	 * handled waits, then ends the next ppoll() at once, so none is missed. */
	sigemptyset(&signals);
	sigaddset(&signals, SIGHUP);
	sigaddset(&signals, SIGTERM);
	sigprocmask(SIG_BLOCK, &signals, &unblocked);
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	while (!stop) {
		struct pollfd p = { .fd = 0, .events = POLLIN };
		char in[4096];
		ssize_t n;
		struct timespec wait = { .tv_sec = due - now_s() };

		if (flush_now || (used && wait.tv_sec <= 0)) {
			flush_now = 0;
			flush();
			if (used)	/* not written: try again after another interval */
				due = now_s() + interval;
			continue;
		}
		if (ppoll(&p, 1, used ? &wait : NULL, &unblocked) <= 0)
			continue;
		n = read(0, in, sizeof(in));
		if (n <= 0)
			break;
		for (ssize_t i = 0; i < n; i++) {
			if (in[i] == '\n' || len == MAX_LINE) {
				line[len] = 0;
				emit(line);
				len = 0;
			}
			if (in[i] != '\n')
				line[len++] = in[i];
		}
	}
	if (len) {	/* a last line without its newline */
		line[len] = 0;
		emit(line);
	}
	flush();
	return 0;

usage:
	fprintf(stderr, "usage: cardlog [-i SECONDS] TAG STATE_FILE LOG_FILE\n");
	return 2;
}
