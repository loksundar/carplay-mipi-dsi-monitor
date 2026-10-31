/*
 * i2cscan BUS            - list addresses that ACK a 1-byte read
 * i2cscan BUS ADDR REG16 N - read N bytes from a 16-bit register (Goodix style)
 */
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s BUS [ADDR REG16 N]\n", argv[0]);
		return 1;
	}
	char dev[32];
	snprintf(dev, sizeof dev, "/dev/i2c-%s", argv[1]);
	int fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}
	if (argc == 5) {
		int addr = strtol(argv[2], NULL, 0), reg = strtol(argv[3], NULL, 0), n = atoi(argv[4]);
		unsigned char w[2] = { reg >> 8, reg & 0xff }, r[256];
		struct i2c_msg msgs[2] = {
			{ .addr = addr, .flags = 0, .len = 2, .buf = w },
			{ .addr = addr, .flags = I2C_M_RD, .len = n, .buf = r },
		};
		struct i2c_rdwr_ioctl_data x = { msgs, 2 };
		if (ioctl(fd, I2C_RDWR, &x) < 0) {
			perror("I2C_RDWR");
			return 1;
		}
		for (int i = 0; i < n; i++)
			printf("%02x%c", r[i], i % 16 == 15 ? '\n' : ' ');
		printf("\n");
		return 0;
	}
	int found = 0;
	for (int a = 0x03; a <= 0x77; a++) {
		unsigned char b;
		if (ioctl(fd, I2C_SLAVE_FORCE, a) < 0)
			continue;
		if (read(fd, &b, 1) == 1) {
			printf("found 0x%02x\n", a);
			found++;
		}
	}
	printf("%d device(s) on bus %s\n", found, argv[1]);
	return 0;
}
