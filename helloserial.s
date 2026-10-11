;; Simple XMODEM-loaded test program, linked for EXTERNAL_RAM_START_ADDRESS.
	.assume ADL = 1
	.include "EZ80BIOS_public.inc"

	.global helloserial
	.section .helloserial,"ax",@progbits

helloserial:
	ld hl, helloserial_message
	call io_puts
	jp bios_halt

helloserial_message:
	.asciz "Hello, world!\r\n"
