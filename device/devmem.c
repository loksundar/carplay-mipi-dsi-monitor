/* devmem ADDR [VALUE] - read or write one 32-bit word of physical memory */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s ADDR [VALUE]\n", argv[0]);
		return 1;
	}
	unsigned long addr = strtoul(argv[1], NULL, 0), page = addr & ~0xfffUL;
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	volatile uint8_t *map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	volatile uint32_t *reg = (volatile uint32_t *)(map + (addr - page));
	if (argc > 2)
		*reg = strtoul(argv[2], NULL, 0);
	printf("0x%08lx = 0x%08x\n", addr, *reg);
	return 0;
}
