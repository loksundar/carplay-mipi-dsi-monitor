/*
 * evinject - inject synthetic GT911-style touches into an evdev device, for
 * testing the touch path without a finger on the glass.
 *
 * usage: evinject DEV tap X Y
 *        evinject DEV drag X1 Y1 X2 Y2
 *        evinject DEV scroll X Y DY          (two fingers moving vertically by DY)
 *        evinject DEV hold X Y MS            (press and hold, e.g. long-press)
 */
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fd;

static void ev(int type, int code, int value)
{
	struct input_event e = { .type = type, .code = code, .value = value };
	if (write(fd, &e, sizeof e) != sizeof e)
		perror("write");
}

/* one report with n contacts (protocol A, like the gt9xx driver) */
static void report(int n, const int *x, const int *y)
{
	for (int i = 0; i < n; i++) {
		ev(EV_ABS, ABS_MT_TOUCH_MAJOR, 40);
		ev(EV_ABS, ABS_MT_POSITION_X, x[i]);
		ev(EV_ABS, ABS_MT_POSITION_Y, y[i]);
		ev(EV_ABS, ABS_MT_TRACKING_ID, i);
		ev(EV_SYN, SYN_MT_REPORT, 0);
	}
	if (!n)
		ev(EV_SYN, SYN_MT_REPORT, 0);
	ev(EV_KEY, BTN_TOUCH, n > 0);
	ev(EV_SYN, SYN_REPORT, 0);
	usleep(16000);
}

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "usage: %s DEV tap X Y | drag X1 Y1 X2 Y2 | scroll X Y DY\n", argv[0]);
		return 1;
	}
	fd = open(argv[1], O_WRONLY);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	int a = atoi(argv[3]), b = atoi(argv[4]);
	if (!strcmp(argv[2], "tap")) {
		report(1, &a, &b);
		report(1, &a, &b);
		report(0, NULL, NULL);
	} else if (!strcmp(argv[2], "drag") && argc >= 7) {
		int c = atoi(argv[5]), d = atoi(argv[6]);
		for (int i = 0; i <= 20; i++) {
			int x = a + (c - a) * i / 20, y = b + (d - b) * i / 20;
			report(1, &x, &y);
		}
		report(0, NULL, NULL);
	} else if (!strcmp(argv[2], "hold") && argc >= 6) {
		for (int t = 0; t < atoi(argv[5]); t += 16)
			report(1, &a, &b);
		report(0, NULL, NULL);
	} else if (!strcmp(argv[2], "scroll") && argc >= 6) {
		int dy = atoi(argv[5]);
		for (int i = 0; i <= 20; i++) {
			int x[2] = { a - 60, a + 60 }, y[2] = { b + dy * i / 20, b + dy * i / 20 };
			report(2, x, y);
		}
		report(0, NULL, NULL);
	}
	return 0;
}
