;; Simple XMODEM-loaded test program, linked for EXTERNAL_RAM_START_ADDRESS.
	.assume ADL = 1
	.global helloserial
	.section .helloserial,"ax",@progbits

helloserial:
	ld hl, helloserial_message
	ld a, 0x04                     ;; BIOS_OP_PUTS; see ../bios/BIOS_API.md
	rst 0x10
	ld a, 0x09                     ;; BIOS_OP_HALT
	rst 0x10

helloserial_message:
	.asciz "Hello, world!\r\n"
