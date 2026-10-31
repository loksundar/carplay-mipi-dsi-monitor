/*
 * httpc - minimal HTTP/1.0 client for the remote command channel.
 *
 * usage: httpc get HOST PORT PATH    (body to stdout; exit 0 on 200)
 *        httpc post HOST PORT PATH   (stdin as POST body; exit 0 on 200)
 */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int dial(const char *host, const char *port)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *ai;
	if (getaddrinfo(host, port, &hints, &ai))
		return -1;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		freeaddrinfo(ai);
		return -1;
	}
	fcntl(fd, F_SETFL, O_NONBLOCK);
	int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
	freeaddrinfo(ai);
	if (rc < 0 && errno == EINPROGRESS) {
		fd_set w;
		struct timeval tv = { 5, 0 };
		int err = 0;
		socklen_t len = sizeof err;
		FD_ZERO(&w);
		FD_SET(fd, &w);
		if (select(fd + 1, NULL, &w, NULL, &tv) == 1 &&
		    !getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) && !err)
			rc = 0;
	}
	if (rc < 0) {
		close(fd);
		return -1;
	}
	fcntl(fd, F_SETFL, 0);
	struct timeval tv = { 15, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
	return fd;
}

static int read_headers(int fd)
{
	char hdr[2048];
	size_t h = 0;
	while (h < sizeof hdr - 1) {
		if (read(fd, hdr + h, 1) != 1)
			break;
		h++;
		if (h >= 4 && !memcmp(hdr + h - 4, "\r\n\r\n", 4))
			break;
	}
	hdr[h] = 0;
	return strncmp(hdr, "HTTP/1.", 7) || strncmp(hdr + 9, "200", 3) ? -1 : 0;
}

static int http_get(const char *host, const char *port, const char *path)
{
	int fd = dial(host, port);
	if (fd < 0)
		return 1;
	dprintf(fd, "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", path, host);
	if (read_headers(fd)) {
		close(fd);
		return 2;
	}
	char buf[4096];
	ssize_t r;
	while ((r = read(fd, buf, sizeof buf)) > 0)
		fwrite(buf, 1, r, stdout);
	close(fd);
	return 0;
}

static int http_post(const char *host, const char *port, const char *path)
{
	size_t cap = 65536, len = 0;
	char *body = malloc(cap);
	ssize_t r;
	while (body && (r = read(0, body + len, cap - len)) > 0) {
		len += r;
		if (len == cap)
			body = realloc(body, cap *= 2);
	}
	if (!body)
		return 1;
	int fd = dial(host, port);
	if (fd < 0)
		return 1;
	dprintf(fd, "POST %s HTTP/1.0\r\nHost: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
		path, host, len);
	for (size_t off = 0; off < len; off += r)
		if ((r = write(fd, body + off, len - off)) <= 0)
			break;
	int rc = read_headers(fd) ? 2 : 0;
	close(fd);
	return rc;
}

int main(int argc, char **argv)
{
	if (argc == 5 && !strcmp(argv[1], "get"))
		return http_get(argv[2], argv[3], argv[4]);
	if (argc == 5 && !strcmp(argv[1], "post"))
		return http_post(argv[2], argv[3], argv[4]);
	fprintf(stderr, "usage: %s get|post HOST PORT PATH\n", argv[0]);
	return 1;
}
