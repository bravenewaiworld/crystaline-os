/*
 * dispctl: control the panel through the Allwinner BSP display driver's /dev/disp ioctls, which
 * TrimUI's userspace uses (this BSP kernel has no /sys/class/backlight).
 * Usage: dispctl bl <0-255>    set backlight brightness (DISP_LCD_SET_BRIGHTNESS; the driver
 *                              caps it at the device tree's lcd_pwm_max_limit)
 *        dispctl off | on      switch the LCD output off or on (DISP_DEVICE_SWITCH); this runs
 *                              the panel driver's power-down / power-up and init sequence
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>

/* ioctl numbers and argument layouts from include/video/sunxi_display2.h */
#define DISP_DEVICE_SWITCH	0x0f	/* args: screen, output type, output mode */
#define DISP_LCD_SET_BRIGHTNESS	0x102	/* args: screen, level */
#define OUTPUT_TYPE_NONE	0
#define OUTPUT_TYPE_LCD		1

int main(int argc, char **argv)
{
	/* The driver always copies 4 arguments. args[0] = screen 0; output mode 0 = default. */
	unsigned long args[4] = { 0 };
	unsigned long cmd;
	int fd;

	if (argc == 3 && !strcmp(argv[1], "bl")) {
		cmd = DISP_LCD_SET_BRIGHTNESS;
		args[1] = strtoul(argv[2], NULL, 0);
	} else if (argc == 2 && (!strcmp(argv[1], "off") || !strcmp(argv[1], "on"))) {
		cmd = DISP_DEVICE_SWITCH;
		args[1] = strcmp(argv[1], "on") ? OUTPUT_TYPE_NONE : OUTPUT_TYPE_LCD;
	} else {
		fprintf(stderr, "usage: %s bl <0-255> | off | on\n", argv[0]);
		return 2;
	}
	fd = open("/dev/disp", O_RDWR);
	if (fd < 0 || ioctl(fd, cmd, args) < 0) {
		perror("dispctl");
		return 1;
	}
	return 0;
}
