/* pantest - time FBIOPAN_DISPLAY with dirty rects of various sizes */
#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

int main(void)
{
	int fb = open("/dev/fb0", O_RDWR);
	struct fb_var_screeninfo v;
	ioctl(fb, FBIOGET_VSCREENINFO, &v);
	int sizes[][4] = { { 0, 0, 1600, 600 }, { 16, 73, 1552, 393 }, { 0, 0, 800, 300 }, { 100, 100, 200, 100 }, { 100, 100, 16, 16 } };
	for (int s = 0; s < 5; s++) {
		for (int pass = 0; pass < 2; pass++) {
			double t0 = now();
			for (int i = 0; i < 5; i++) {
				v.reserved[0] = sizes[s][0]; v.reserved[1] = sizes[s][1];
				v.reserved[2] = sizes[s][2]; v.reserved[3] = sizes[s][3];
				ioctl(fb, FBIOPAN_DISPLAY, &v);
				if (pass) usleep(100000);
			}
			printf("%4dx%-4d %s: %.1f ms/pan\n", sizes[s][2], sizes[s][3], pass ? "spaced 100ms" : "back-to-back",
			       (now() - t0 - (pass ? 500 : 0)) / 5);
		}
	}
	return 0;
}
