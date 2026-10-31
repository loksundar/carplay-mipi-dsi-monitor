/*
 * vdclient - extended-display client: receives dirty-rect tiles from the Mac
 * (vdisplay daemon), draws them into /dev/fb0, and streams touch contacts back.
 *
 * usage: vdclient [-1] HOST[,HOST...] PORT [TOUCH_EVDEV]
 *   dials the Mac, trying hosts in order (e.g. the USB-NCM address, then WiFi),
 *   and keeps redialing; the screen is black while no Mac answers.
 *   -1: one session only; exit 2 if no host answers, 0 when the session ends.
 *
 * Protocol (all integers little-endian), once connected:
 *   device -> mac  hello:  "VD01" u16 width u16 height
 *   mac -> device  frame:  'F' u16 nrects, then per rect:
 *                          u16 x u16 y u16 w u16 h u8 enc u32 len, len bytes
 *                          enc 0 = raw BGRA rows (w*h*4), enc 1 = JPEG,
 *                          enc 2 = raw DEFLATE (RFC 1951) of the BGRA rows,
 *                          enc 3 = copy: payload u16 src_x u16 src_y; moves the
 *                          w*h block at (src_x,src_y) to (x,y) (scrolling)
 *   device -> mac  ack:    'A' u16 total_ms u16 decode_ms u16 copy_ms u16 pan_ms
 *                          (after each frame is shown)
 *   device -> mac  touch:  'T' u8 n, n * (u16 x u16 y)   (n = 0 means all fingers up)
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <turbojpeg.h>
#include <zlib.h>
#include <unistd.h>

#define MAX_CONTACTS 2

static int fb;
static struct fb_var_screeninfo var;
static struct fb_fix_screeninfo fix;
static uint8_t *fbmem;
static uint8_t *shadow;   /* cached copy of the screen: fb0 memory is too slow to read */
static tjhandle tj;

static long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/*
 * sunxi software rotation (fb0 1600x600 -> panel 600x1600) only copies the
 * dirty rect passed in reserved[0..3]; with it empty, pan is a silent no-op.
 */
static void present(int x, int y, int w, int h)
{
	var.reserved[0] = x;
	var.reserved[1] = y;
	var.reserved[2] = w;
	var.reserved[3] = h;
	if (ioctl(fb, FBIOPAN_DISPLAY, &var))
		perror("FBIOPAN_DISPLAY");
}

static int read_full(int fd, void *buf, size_t len)
{
	uint8_t *p = buf;
	while (len) {
		ssize_t r = read(fd, p, len);
		if (r <= 0)
			return -1;
		p += r;
		len -= r;
	}
	return 0;
}

static int write_full(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;
	while (len) {
		ssize_t r = write(fd, p, len);
		if (r <= 0)
			return -1;
		p += r;
		len -= r;
	}
	return 0;
}

static uint16_t u16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static int dial(const char *host, const char *port)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *ai;
	if (getaddrinfo(host, port, &hints, &ai))
		return -1;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd >= 0) {
		/* short timeout so an absent USB link falls through to WiFi quickly */
		fcntl(fd, F_SETFL, O_NONBLOCK);
		int rc = connect(fd, ai->ai_addr, ai->ai_addrlen), err = 0;
		socklen_t len = sizeof err;
		struct pollfd p = { fd, POLLOUT, 0 };
		if (rc < 0 && (errno != EINPROGRESS || poll(&p, 1, 1500) != 1 ||
			       getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) || err)) {
			close(fd);
			fd = -1;
		} else
			fcntl(fd, F_SETFL, 0);
	}
	freeaddrinfo(ai);
	if (fd < 0)
		return -1;
	int one = 1, idle = 4, intvl = 2, cnt = 3;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	/* a static screen sends nothing, so detect a dead link (cable pulled) with keepalives */
	setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
	struct timeval tv = { 10, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	return fd;
}

static long t_decode, t_copy, t_pan;

/* copy a rect of the shadow screen to fb0 */
static void flush_rect(int x, int y, int w, int h)
{
	long t = now_ms();
	for (int row = y; row < y + h; row++)
		memcpy(fbmem + (size_t)(row + var.yoffset) * fix.line_length + (size_t)x * 4,
		       shadow + (size_t)row * fix.line_length + (size_t)x * 4, (size_t)w * 4);
	t_copy += now_ms() - t;
}

/* black screen while no Mac is connected (also clears the boot logo) */
static void blackout(void)
{
	for (unsigned y = 0; y < var.yres; y++)
		for (unsigned x = 0; x < var.xres; x++)
			((uint32_t *)(shadow + (size_t)y * fix.line_length))[x] = 0xff000000;   /* opaque */
	flush_rect(0, 0, var.xres, var.yres);
	present(0, 0, var.xres, var.yres);
}

/*
 * draw one rect into the shadow screen and fb0; returns 0 on success. fb0
 * memory is uncached, so everything is decoded/copied in cached memory first
 * and written to fb0 in whole rows.
 */
static int draw_rect(int x, int y, int w, int h, int enc, const uint8_t *data, uint32_t len)
{
	static uint8_t *scratch;
	static size_t scratch_cap;

	if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > (int)var.xres || y + h > (int)var.yres)
		return -1;
	if (enc == 3) {
		if (len != 4)
			return -1;
		int sx = u16(data), sy = u16(data + 2);
		if (sx + w > (int)var.xres || sy + h > (int)var.yres)
			return -1;
		/* row order matters when source and destination overlap */
		for (int i = 0; i < h; i++) {
			int row = sy < y ? h - 1 - i : i;
			memmove(shadow + (size_t)(y + row) * fix.line_length + (size_t)x * 4,
				shadow + (size_t)(sy + row) * fix.line_length + (size_t)sx * 4, (size_t)w * 4);
		}
		flush_rect(x, y, w, h);
		return 0;
	}
	uint8_t *dst = shadow + (size_t)y * fix.line_length + (size_t)x * 4;
	const uint8_t *src = data;
	size_t need = (size_t)w * h * 4;
	if (enc == 1 || enc == 2) {
		if (need > scratch_cap) {
			free(scratch);
			scratch = malloc(need);
			scratch_cap = scratch ? need : 0;
			if (!scratch)
				return -1;
		}
		long t = now_ms();
		if (enc == 1 && tjDecompress2(tj, data, len, scratch, w, w * 4, h, TJPF_BGRA, TJFLAG_FASTDCT))
			return -1;
		if (enc == 2) {
			z_stream z = { .next_in = (Bytef *)data, .avail_in = len, .next_out = scratch, .avail_out = need };
			if (inflateInit2(&z, -15) != Z_OK)
				return -1;
			int rc = inflate(&z, Z_FINISH);
			inflateEnd(&z);
			if (rc != Z_STREAM_END || z.total_out != need)
				return -1;
		}
		t_decode += now_ms() - t;
		src = scratch;
	} else if (enc != 0 || len != need)
		return -1;
	for (int row = 0; row < h; row++)
		memcpy(dst + (size_t)row * fix.line_length, src + (size_t)row * w * 4, (size_t)w * 4);
	flush_rect(x, y, w, h);
	return 0;
}

/* read and draw one frame message (the 'F' byte is already consumed) */
static int handle_frame(int s)
{
	static uint8_t *buf;
	static size_t cap;
	uint8_t hdr[13];
	long t0 = now_ms();

	t_decode = t_copy = t_pan = 0;
	/* union of everything drawn; panned once per frame since every pan waits a vsync */
	int ux0 = var.xres, uy0 = var.yres, ux1 = 0, uy1 = 0;
	if (read_full(s, hdr, 2))
		return -1;
	int n = u16(hdr);
	for (int i = 0; i < n; i++) {
		if (read_full(s, hdr, 13))
			return -1;
		int x = u16(hdr), y = u16(hdr + 2), w = u16(hdr + 4), h = u16(hdr + 6), enc = hdr[8];
		uint32_t len = u32(hdr + 9);
		if (len > 16 * 1024 * 1024)
			return -1;
		if (len > cap) {
			free(buf);
			cap = len;
			buf = malloc(cap);
			if (!buf)
				return -1;
		}
		if (read_full(s, buf, len))
			return -1;
		if (draw_rect(x, y, w, h, enc, buf, len))
			fprintf(stderr, "bad rect %d,%d %dx%d enc %d len %u: %s\n", x, y, w, h, enc, len,
				enc == 1 ? tjGetErrorStr2(tj) : "");
		else {
			ux0 = x < ux0 ? x : ux0;
			uy0 = y < uy0 ? y : uy0;
			ux1 = x + w > ux1 ? x + w : ux1;
			uy1 = y + h > uy1 ? y + h : uy1;
		}
	}
	if (ux1 > ux0 && uy1 > uy0) {
		long t = now_ms();
		present(ux0, uy0, ux1 - ux0, uy1 - uy0);
		t_pan += now_ms() - t;
	}
	long v[4] = { now_ms() - t0, t_decode, t_copy, t_pan };
	uint8_t ack[9] = { 'A' };
	for (int i = 0; i < 4; i++) {
		ack[1 + i * 2] = v[i] & 0xff;
		ack[2 + i * 2] = (v[i] >> 8) & 0xff;
	}
	return write_full(s, ack, sizeof ack);
}

/* GT911 reports multitouch protocol A: contacts separated by SYN_MT_REPORT */
struct touch {
	int fd;
	int n, cx, cy;
	int x[MAX_CONTACTS], y[MAX_CONTACTS];
	int down;
};

static int touch_read(struct touch *t, int s)
{
	struct input_event ev[32];
	ssize_t r = read(t->fd, ev, sizeof ev);
	if (r <= 0)
		return 0;
	for (int i = 0; i < r / (ssize_t)sizeof ev[0]; i++) {
		struct input_event *e = &ev[i];
		if (e->type == EV_ABS && e->code == ABS_MT_POSITION_X)
			t->cx = e->value;
		else if (e->type == EV_ABS && e->code == ABS_MT_POSITION_Y)
			t->cy = e->value;
		else if (e->type == EV_KEY && e->code == BTN_TOUCH)
			t->down = e->value;
		else if (e->type == EV_SYN && e->code == SYN_MT_REPORT) {
			if (t->n < MAX_CONTACTS) {
				t->x[t->n] = t->cx;
				t->y[t->n] = t->cy;
			}
			t->n++;
		} else if (e->type == EV_SYN && e->code == SYN_REPORT) {
			int n = t->down ? (t->n < MAX_CONTACTS ? t->n : MAX_CONTACTS) : 0;
			uint8_t msg[2 + MAX_CONTACTS * 4] = { 'T', n };
			for (int k = 0; k < n; k++) {
				msg[2 + k * 4] = t->x[k] & 0xff;
				msg[3 + k * 4] = t->x[k] >> 8;
				msg[4 + k * 4] = t->y[k] & 0xff;
				msg[5 + k * 4] = t->y[k] >> 8;
			}
			if (s >= 0 && write_full(s, msg, 2 + n * 4))
				return -1;
			t->n = 0;
		}
	}
	return 0;
}

/* discard queued touch events so taps made while disconnected aren't replayed */
static void touch_flush(struct touch *t)
{
	struct input_event ev[32];
	while (t->fd >= 0 && read(t->fd, ev, sizeof ev) > 0)
		;
	t->n = 0;
	t->down = 0;
}

static int find_touch(char *path, size_t len)
{
	for (int i = 0; i < 16; i++) {
		char name[64] = "", p[96];
		snprintf(p, sizeof p, "/sys/class/input/event%d/device/name", i);
		FILE *f = fopen(p, "r");
		if (!f)
			continue;
		if (fgets(name, sizeof name, f) && !strncmp(name, "gt9xx", 5)) {
			fclose(f);
			snprintf(path, len, "/dev/input/event%d", i);
			return 0;
		}
		fclose(f);
	}
	return -1;
}

int main(int argc, char **argv)
{
	int once = argc > 1 && !strcmp(argv[1], "-1");
	if (once) {
		argv++;
		argc--;
	}
	if (argc < 3) {
		fprintf(stderr, "usage: %s [-1] HOST[,HOST...] PORT [TOUCH_EVDEV]\n", argv[0]);
		return 1;
	}
	fb = open("/dev/fb0", O_RDWR);
	if (fb < 0 || ioctl(fb, FBIOGET_VSCREENINFO, &var) || ioctl(fb, FBIOGET_FSCREENINFO, &fix)) {
		perror("fb0");
		return 1;
	}
	fbmem = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb, 0);
	if (fbmem == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	tj = tjInitDecompress();
	shadow = calloc(var.yres, fix.line_length);
	if (!shadow)
		return 1;

	struct touch t = { .fd = -1 };
	char tpath[64];
	if (argc > 3)
		snprintf(tpath, sizeof tpath, "%s", argv[3]);
	if (argc > 3 || !find_touch(tpath, sizeof tpath))
		t.fd = open(tpath, O_RDONLY | O_NONBLOCK);
	fprintf(stderr, "vdclient: fb %ux%u line %u, touch %s\n", var.xres, var.yres, fix.line_length,
		t.fd >= 0 ? tpath : "none");

	int black = 0;
	for (;;) {
		int s = -1, via = 0;
		char hosts[256], *save = NULL, first[64] = "";
		snprintf(hosts, sizeof hosts, "%s", argv[1]);
		for (char *h = strtok_r(hosts, ",", &save); h && s < 0; h = strtok_r(NULL, ",", &save), via++) {
			if (!via)
				snprintf(first, sizeof first, "%s", h);
			if ((s = dial(h, argv[2])) >= 0)
				fprintf(stderr, "vdclient: connected via %s\n", h);
		}
		via--;
		long next_probe = now_ms() + 10000;
		if (s < 0) {
			if (once)
				return 2;
			if (!black) {
				blackout();
				black = 1;
			}
			sleep(2);
			continue;
		}
		touch_flush(&t);
		black = 0;
		uint8_t hello[8] = { 'V', 'D', '0', '1', var.xres & 0xff, var.xres >> 8, var.yres & 0xff, var.yres >> 8 };
		write_full(s, hello, sizeof hello);

		for (;;) {
			struct pollfd pfd[2] = { { s, POLLIN, 0 }, { t.fd, POLLIN, 0 } };
			if (poll(pfd, t.fd >= 0 ? 2 : 1, 5000) < 0 && errno != EINTR)
				break;
			if (pfd[0].revents & (POLLERR | POLLHUP))
				break;
			if (pfd[0].revents & POLLIN) {
				uint8_t type;
				if (read_full(s, &type, 1) || type != 'F' || handle_frame(s))
					break;
			}
			if (t.fd >= 0 && (pfd[1].revents & POLLIN) && touch_read(&t, s))
				break;
			/* on a fallback link (WiFi), switch as soon as the preferred one (USB) answers */
			if (via > 0 && now_ms() > next_probe) {
				int p = dial(first, argv[2]);
				next_probe = now_ms() + 10000;
				if (p >= 0) {
					close(p);
					fprintf(stderr, "vdclient: %s reachable, switching\n", first);
					break;
				}
			}
		}
		fprintf(stderr, "vdclient: disconnected\n");
		close(s);
		if (once)
			return 0;
		sleep(1);
	}
}
