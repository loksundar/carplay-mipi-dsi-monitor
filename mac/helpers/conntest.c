#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
int main(int c, char **v) {
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(9100) };
	inet_pton(AF_INET, v[1], &a.sin_addr);
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	int r = connect(fd, (struct sockaddr *)&a, sizeof a);
	printf("%s: connect=%d errno=%d (%s)\n", v[1], r, r ? errno : 0, r ? strerror(errno) : "ok");
	return 0;
}
